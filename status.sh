#!/bin/bash
# status.sh — saúde do mcp-hub: serviço, teste MCP real, memória e quantas cópias antigas ainda rodam.
HUB="${MCP_HUB_DIR:-$HOME/.claude/mcp-hub}"
PY="${MCP_HUB_PY:-$(uv tool dir 2>/dev/null || echo "$HOME/.local/share/uv/tools")/mcp-proxy/bin/python}"
PREFIXO="${MCP_HUB_LABEL:-local.mcp-hub}"
UIDN="$(id -u)"
[ -f "$HUB/servers.json" ] || { echo "hub não instalado (rode instalar.sh)"; exit 1; }

echo "== serviços (launchd)"
"$PY" - "$UIDN" "$HUB" "$PREFIXO" <<'PYEOF'
import json, os, subprocess, sys
uid, pasta, prefixo = sys.argv[1:4]
hub = json.load(open(os.path.join(pasta, "servers.json")))
d = json.load(open(os.path.expanduser("~/.claude.json")))
home = d.get("projects", {}).get(os.path.expanduser("~"), {}).get("mcpServers", {})
ps = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout.split("\n")
filhos = {}
for l in ps:
    p = l.split()
    if len(p) == 3:
        filhos.setdefault(p[1], []).append((p[0], int(p[2])))
for nome, v in hub.items():
    if nome.startswith("_"):
        continue
    r = subprocess.run(["launchctl", "print", f"gui/{uid}/{prefixo}.{nome}"], capture_output=True, text=True)
    pid = next((l.split("=")[1].strip() for l in r.stdout.splitlines() if l.strip().startswith("pid =")), None)
    mem = 0
    if pid:
        mem = next((int(l.split()[2]) for l in ps if l.split()[:1] == [pid]), 0) + sum(k for _, k in filhos.get(pid, []))
    cfg = (d.get("mcpServers", {}) if v["escopo"] == "user" else home).get(nome, {})
    modo = "hub" if cfg.get("url", "").startswith("http://127.0.0.1:") else ("stdio (antigo)" if cfg else "ausente")
    est = f"pid {pid}" if pid else ("parado" if r.returncode == 0 else "não instalado")
    print(f"  {nome:30} {est:12} {mem/1024:5.0f} MB   Claude Code usa: {modo}")
PYEOF

echo "== teste MCP real (initialize + tools/list + 1 chamada real só-leitura)"
MCP_HUB_SECRET="${MCP_HUB_SECRET:-$(command -v secret || echo secret)}" "$PY" "$HUB/bin/hub-teste.py"

echo "== pastas onde uma cópia local vence o hub"
"$PY" "$HUB/bin/hub-pastas.py"

echo "== cópias antigas ainda vivas (sessões abertas antes do hub)"
"$PY" - "$HUB" <<'PYEOF'
import json, os, subprocess, sys
servidores = json.load(open(os.path.join(sys.argv[1], "servers.json")))
proc = {}  # pid -> (ppid, comando)
for l in subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines():
    p = l.split(None, 2)
    if len(p) == 3:
        proc[p[0]] = (p[1], p[2])
hub = {pid for pid, (_, cmd) in proc.items() if "hub-proxy.py" in cmd}
def do_hub(pid):  # o servidor que o próprio hub sobe (filho, ou neto via npx) não é cópia antiga
    vistos = set()
    while pid in proc and pid not in vistos:
        if pid in hub:
            return True
        vistos.add(pid)
        pid = proc[pid][0]
    return False
# "processo" em servers.json; sem ele, o nome do comando
marcas = sorted({v.get("processo") or os.path.basename(v["cmd"][0]) for k, v in servidores.items() if not k.startswith("_")})
for p in marcas:
    n = sum(1 for pid, (_, cmd) in proc.items() if p in cmd and "mcp-hub" not in cmd and not do_hub(pid))
    print(f"  {p:26} {n} processos")
PYEOF
echo "   (somem quando as sessões antigas forem reiniciadas)"
