#!/usr/bin/env python3
"""Sobe UM servidor MCP stdio atrás de um mcp-proxy HTTP em 127.0.0.1.

Uso: <python do mcp-proxy> hub-proxy.py <nome>   (nome = chave em servers.json)

- Segredos vêm do cofre na subida (comando `secret get NOME`, ou o que estiver em MCP_HUB_SECRET);
  nada é gravado em disco.
- Porteiro: toda chamada precisa do token do hub (Authorization: Bearer, cofre MCP_HUB_TOKEN). Assim, outro
  usuário ou processo da máquina não usa o seu Gmail ou Supabase sem ele. Origin de site externo é recusado.
- Filtro de Host (só 127.0.0.1/localhost): o mcp-proxy não liga a proteção contra DNS rebinding,
  então um site malicioso apontando para 127.0.0.1 não consegue falar com o servidor.
- Vigia: se o servidor filho morrer, o proxy sai com erro e o launchd (KeepAlive) sobe de novo.
"""
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

AQUI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HUB = os.environ.get("MCP_HUB_DIR", os.path.expanduser("~/.claude/mcp-hub"))
SECRET = os.environ.get("MCP_HUB_SECRET") or shutil.which("secret") or "secret"
LOG_MAX = 5 * 1024 * 1024


def log(msg):
    print(f"[mcp-hub {time.strftime('%d/%m %H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def troca(s):
    return s.replace("{HUB}", HUB).replace("{HOME}", os.path.expanduser("~"))


def do_cofre(nome):
    r = subprocess.run([SECRET, "get", nome], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def token_do_hub():
    return os.environ.get("MCP_HUB_TOKEN") or do_cofre("MCP_HUB_TOKEN")


ORIGEM_LOCAL = re.compile(r"^https?://(127\.0\.0\.1|localhost)(:\d+)?$")


class Porteiro:
    """ASGI: exige o token do hub e recusa Origin que não seja local (/status fica livre)."""

    def __init__(self, app, token):
        self.app = app
        self.esperado = f"Bearer {token}".encode("latin-1")

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            h = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
            origem = h.get("origin")
            if origem is not None and not ORIGEM_LOCAL.match(origem):
                return await self.nega(send, 403)
            # compara bytes: str com caractere não-ASCII faria o compare_digest levantar TypeError (500)
            recebido = h.get("authorization", "").encode("latin-1")
            if scope.get("path") != "/status" and not hmac.compare_digest(recebido, self.esperado):
                return await self.nega(send, 401)
        await self.app(scope, receive, send)

    @staticmethod
    async def nega(send, status):
        await send({"type": "http.response.start", "status": status, "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"negado"})


def vigia(nome):
    time.sleep(45)  # tempo para o filho subir
    while True:
        r = subprocess.run(["pgrep", "-P", str(os.getpid())], capture_output=True, text=True)
        if not r.stdout.strip():
            log(f"{nome}: o servidor filho morreu; saindo para o launchd subir de novo")
            os._exit(75)
        time.sleep(15)


def main():
    nome = sys.argv[1]
    servidores = json.load(open(os.path.join(AQUI, "servers.json")))
    cfg = servidores[nome]

    log_path = os.environ.get("MCP_HUB_LOG")
    if log_path and os.path.exists(log_path) and os.path.getsize(log_path) > LOG_MAX:
        os.truncate(log_path, 0)

    for var, valor in cfg.get("env", {}).items():
        os.environ[var] = troca(valor)
    for var, cofre in cfg.get("segredos", {}).items():
        valor = do_cofre(cofre)
        if not valor:
            log(f"{nome}: segredo {cofre} não está no cofre; abortando")
            sys.exit(78)
        os.environ[var] = valor
    token = token_do_hub()
    if len(token) < 32:
        log(f"{nome}: token do hub (MCP_HUB_TOKEN) ausente no cofre; abortando")
        sys.exit(78)
    os.environ.pop("MCP_HUB_TOKEN", None)  # o servidor filho não precisa dele

    # O mcp-proxy não aceita middleware pela linha de comando: o filtro de Host e o porteiro entram
    # trocando a Starlette que ele usa. Testado com mcp-proxy 0.13.0; versão nova pode mudar esse ponto.
    from starlette.middleware import Middleware
    from starlette.middleware.trustedhost import TrustedHostMiddleware
    import mcp_proxy.mcp_server as ms

    starlette_original = ms.Starlette

    def starlette_com_filtro(*a, **k):
        k["middleware"] = list(k.get("middleware") or []) + [
            Middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"]),
            Middleware(Porteiro, token=token),
        ]
        return starlette_original(*a, **k)

    ms.Starlette = starlette_com_filtro

    threading.Thread(target=vigia, args=(nome,), daemon=True).start()
    cmd = [troca(c) for c in cfg["cmd"]]
    sys.argv = ["mcp-proxy", "--host", "127.0.0.1", "--port", str(cfg["porta"]),
                "--pass-environment", "--log-level", "WARNING", "--", *cmd]
    log(f"{nome}: subindo em 127.0.0.1:{cfg['porta']}")
    from mcp_proxy.__main__ import main as proxy_main
    proxy_main()


if __name__ == "__main__":
    main()
