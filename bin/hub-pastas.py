#!/usr/bin/env python3
"""Lista as pastas onde uma cópia local de um servidor do hub vence o escopo user e segue em stdio.

O Claude Code usa a entrada de escopo local (~/.claude.json → projects → <pasta> → mcpServers) ou de projeto
(<pasta>/.mcp.json) antes da de escopo user. Nessas pastas o servidor continua uma cópia por sessão, mesmo com o
hub ligado. Só lista; não troca nada. Uso: <python> hub-pastas.py
"""
import json
import os

AQUI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASA = os.path.expanduser("~")
hub = {k: v for k, v in json.load(open(os.path.join(AQUI, "servers.json"))).items() if not k.startswith("_")}
d = json.load(open(os.path.join(CASA, ".claude.json")))


def do_hub(c):
    return c.get("type") == "http" and str(c.get("url", "")).startswith("http://127.0.0.1:")


achou = 0
for pasta, p in sorted(d.get("projects", {}).items()):
    fontes = [("local", p.get("mcpServers") or {})]
    mcp_json = os.path.join(pasta, ".mcp.json")
    if os.path.isfile(mcp_json):
        try:
            fontes.append((".mcp.json", json.load(open(mcp_json)).get("mcpServers") or {}))
        except (OSError, ValueError):
            print(f"   (não deu para ler {mcp_json})")
    for origem, ms in fontes:
        # na home, os servidores de escopo local são justamente as entradas que o instalar.sh troca
        nomes = [n for n, c in ms.items()
                 if n in hub and not do_hub(c) and not (pasta == CASA and hub[n]["escopo"] == "local")]
        if nomes:
            achou += 1
            print(f"   {pasta.replace(CASA, '~', 1)} ({origem}): {', '.join(sorted(nomes))} continua stdio nesta pasta")
if not achou:
    print("   nenhuma")
