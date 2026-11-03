#!/usr/bin/env python3
"""Testa servidores do hub como o Claude Code faz: initialize + tools/list via HTTP,
mais UMA chamada real só-leitura e grátis ('teste' em servers.json), que prova a credencial do cofre.

Uso: <python do mcp-proxy> hub-teste.py [nome ...]   (sem nome = todos de servers.json)
Saída: uma linha por servidor (ok/FALHOU, nº de ferramentas, chamada real, tempo). Código 1 se algum falhar.
Servidor sem 'teste' passa só com initialize + tools/list e a linha diz "sem chamada real".
"""
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import time

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

AQUI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET = os.environ.get("MCP_HUB_SECRET") or shutil.which("secret") or "secret"
TOKEN = os.environ.get("MCP_HUB_TOKEN") or subprocess.run(
    [SECRET, "get", "MCP_HUB_TOKEN"], capture_output=True, text=True
).stdout.strip()


def limpa(texto):
    """Corta e mascara sequências longas (cara de token), caso um erro da API ecoe a credencial."""
    return re.sub(r"[A-Za-z0-9_\-.+/=]{24,}", "[…]", texto)[:200]


async def testa(nome, cfg):
    t = time.time()
    teste = cfg.get("teste")
    try:
        cab = {"Authorization": f"Bearer {TOKEN}"}
        async with streamablehttp_client(f"http://127.0.0.1:{cfg['porta']}/mcp", headers=cab) as (r, w, _):
            async with ClientSession(r, w) as s:
                await asyncio.wait_for(s.initialize(), 60)
                tools = await asyncio.wait_for(s.list_tools(), 60)
                info = f"{len(tools.tools)} ferramentas"
                if not teste:
                    return True, f"{info}, sem chamada real", time.time() - t
                res = await asyncio.wait_for(s.call_tool(teste["ferramenta"], teste.get("args", {})), 90)
        texto = " ".join(getattr(c, "text", "") for c in res.content)
        if res.isError or not re.search(teste["espera"], texto):
            return False, f"{info}, chamada real {teste['ferramenta']} falhou: {limpa(texto)!r}", time.time() - t
        return True, f"{info}, chamada real {teste['ferramenta']} ok", time.time() - t
    except BaseException as e:  # noqa: BLE001 - relatar qualquer falha
        msg = repr(e)
        if hasattr(e, "exceptions"):
            msg = "; ".join(repr(x) for x in e.exceptions)
        return False, limpa(msg), time.time() - t


async def main():
    servidores = {k: v for k, v in json.load(open(os.path.join(AQUI, "servers.json"))).items() if not k.startswith("_")}
    nomes = sys.argv[1:] or list(servidores)
    falhou = False
    for n in nomes:
        ok, info, dt = await testa(n, servidores[n])
        falhou |= not ok
        print(f"{'ok     ' if ok else 'FALHOU '} {n:30} {info}  ({dt:.1f}s)", flush=True)
    sys.exit(1 if falhou else 0)


asyncio.run(main())
