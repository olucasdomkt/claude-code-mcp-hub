#!/bin/bash
# instalar.sh — liga o mcp-hub: cada servidor MCP stdio roda UMA vez (launchd) e o Claude Code passa a usar HTTP local.
# Padrão = SIMULAÇÃO (só mostra o que faria). Para aplicar: ./instalar.sh --aplicar
# Volta atrás a qualquer momento: ./desfazer.sh (usa o backup gravado aqui).
# Pode rodar de novo (ex.: depois de trocar a versão do node no nvm): o que já usa o hub não é trocado outra vez.
set -euo pipefail

APLICAR=0; [ "${1:-}" = "--aplicar" ] && APLICAR=1
AQUI="$(cd "$(dirname "$0")" && pwd)"
HUB="${MCP_HUB_DIR:-$HOME/.claude/mcp-hub}"
PY="${MCP_HUB_PY:-$(uv tool dir 2>/dev/null || echo "$HOME/.local/share/uv/tools")/mcp-proxy/bin/python}"
SECRET="${MCP_HUB_SECRET:-$(command -v secret || true)}"   # cofre: precisa de `get`, `has` e `set NOME VALOR`
PREFIXO="${MCP_HUB_LABEL:-local.mcp-hub}"                   # nome dos LaunchAgents: <PREFIXO>.<servidor>
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
UIDN="$(id -u)"
TS="$(date +%Y%m%d-%H%M%S)"
NODE="$(command -v node || true)"   # o node do terminal que roda o instalador vai para o PATH dos serviços
NODEBIN="${NODE%/*}"
LPATH="$NODEBIN:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

faz() { if [ "$APLICAR" = 1 ]; then "$@"; else printf '   [simulação] %s\n' "$*"; fi; }
tem() { case " $1 " in *" $2 "*) return 0;; esac; return 1; }   # tem "<lista>" <nome>
# bootout é assíncrono: bootstrap logo em seguida dá "Bootstrap failed: 5: Input/output error". Espera sair (até 5 s).
desliga() {
  launchctl bootout "gui/$UIDN/$1" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$UIDN/$1" >/dev/null 2>&1 || return 0; sleep 0.5; done
}
liga() { launchctl bootstrap "gui/$UIDN" "$1" 2>/dev/null || { sleep 1; launchctl bootstrap "gui/$UIDN" "$1"; }; }

echo "== 0. pré-requisitos"
[ -f "$AQUI/servers.json" ] || { echo "falta servers.json: copie servers.exemplo.json para servers.json e deixe só os seus servidores"; exit 1; }
[ -x "$PY" ] || { echo "falta o mcp-proxy (uv tool install mcp-proxy==0.13.0) ou aponte MCP_HUB_PY para o python dele"; exit 1; }
[ -n "$SECRET" ] && [ -x "$SECRET" ] || { echo "falta o comando do cofre (secret no PATH ou MCP_HUB_SECRET=/caminho)"; exit 1; }
if grep -q '{HUB}/node' "$AQUI/servers.json" && [ ! -d "$HUB/node/node_modules" ]; then
  echo "falta $HUB/node/node_modules: mkdir -p $HUB/node && cp $AQUI/node/package.json $HUB/node/ && npm install --prefix $HUB/node"; exit 1
fi
[ -n "$NODE" ] || { echo "node não encontrado no PATH: abra o terminal com o node que os servidores devem usar (ex.: nvm use 20) e rode de novo"; exit 1; }
echo "   node dos serviços: $NODE ($("$NODE" --version))"
[ -x "$CLAUDE" ] || { echo "CLI claude não encontrada"; exit 1; }
NOMES=$("$PY" -c "import json;print(' '.join(k for k in json.load(open('$AQUI/servers.json')) if not k.startswith('_')))")
echo "   servidores: $NOMES"

echo "== 1. copiar código para $HUB (bin/ e servers.json)"
faz mkdir -p "$HUB/bin" "$HUB/logs" "$HUB/backups"
faz cp "$AQUI/bin/hub-proxy.py" "$AQUI/bin/hub-teste.py" "$AQUI/bin/hub-pastas.py" "$HUB/bin/"
faz cp "$AQUI/servers.json" "$HUB/servers.json"

echo "== 2. backup do ~/.claude.json e das entradas originais"
ORIG="$HUB/backups/original-mcp.$TS.json"
# o arquivo leva a config original (com tokens): nome imprevisível, só o dono lê, apagado em qualquer saída
TMPF="$(umask 077; mktemp "${TMPDIR:-/tmp}/mcp-hub-orig.XXXXXXXX")"
trap 'rm -f "$TMPF"' EXIT
"$PY" - "$AQUI/servers.json" "$HUB/backups" <<'PYEOF' > "$TMPF"
import glob, json, os, sys
hub = {k: v for k, v in json.load(open(sys.argv[1])).items() if not k.startswith("_")}
d = json.load(open(os.path.expanduser("~/.claude.json")))
home = d.get("projects", {}).get(os.path.expanduser("~"), {}).get("mcpServers", {})
def do_hub(c):
    return c.get("type") == "http" and str(c.get("url", "")).startswith("http://127.0.0.1:")
antigos = []  # backups anteriores, do mais novo para o mais velho
for f in sorted(glob.glob(os.path.join(sys.argv[2], "original-mcp.*.json")), reverse=True):
    try:
        antigos.append(json.load(open(f)))
    except (OSError, ValueError):
        pass
out = {}
for nome, v in hub.items():
    fonte = d.get("mcpServers", {}) if v["escopo"] == "user" else home
    if nome not in fonte:
        print(f"   AVISO: {nome} não está no escopo {v['escopo']} do ~/.claude.json", file=sys.stderr)
    elif not do_hub(fonte[nome]):
        out[nome] = {"escopo": v["escopo"], "config": fonte[nome]}
    else:
        # já usa o hub (reexecução): leva a config original do backup anterior, para o desfazer.sh continuar voltando
        orig = next((b[nome]["config"] for b in antigos if nome in b and not do_hub(b[nome].get("config") or {})), None)
        out[nome] = {"escopo": v["escopo"], "config": orig, "ja_no_hub": True}
        if orig is None:
            print(f"   AVISO: {nome} já usa o hub e nenhum backup tem a config original; o desfazer.sh não volta este", file=sys.stderr)
print(json.dumps(out, indent=2, ensure_ascii=False))
PYEOF
NO_BACKUP=$("$PY" -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))))" "$TMPF")
JA_HUB=$("$PY" -c "import json,sys;print(' '.join(k for k,v in json.load(open(sys.argv[1])).items() if v.get('ja_no_hub')))" "$TMPF")
[ -z "$JA_HUB" ] || echo "   já usam o hub (não troco de novo; o serviço é refeito no passo 4): $JA_HUB"
if [ "$APLICAR" = 1 ]; then
  ( umask 077; cp "$TMPF" "$ORIG"; cp -p "$HOME/.claude.json" "$HUB/backups/claude.json.$TS" )
  chmod 600 "$ORIG" "$HUB/backups/claude.json.$TS"
  echo "   $ORIG"
else
  echo "   [simulação] gravaria $ORIG com $("$PY" -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$TMPF") entradas"
fi
rm -f "$TMPF"; trap - EXIT

echo "== 3. token do hub no cofre (MCP_HUB_TOKEN)"
if "$SECRET" has MCP_HUB_TOKEN 2>/dev/null; then echo "   já existe"
elif [ "$APLICAR" = 1 ]; then "$SECRET" set MCP_HUB_TOKEN "$(openssl rand -hex 32)" >/dev/null && echo "   criado"
else echo "   [simulação] criaria com openssl rand -hex 32"; fi

echo "== 4. um LaunchAgent por servidor ($PREFIXO.<nome>)"
for N in $NOMES; do
  L="$PREFIXO.$N"; P="$HOME/Library/LaunchAgents/$L.plist"
  if [ "$APLICAR" = 1 ]; then
    cat > "$P" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$L</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$HUB/bin/hub-proxy.py</string><string>$N</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$LPATH</string>
    <key>HOME</key><string>$HOME</string>
    <key>MCP_HUB_LOG</key><string>$HUB/logs/$N.log</string>
    <key>MCP_HUB_DIR</key><string>$HUB</string>
    <key>MCP_HUB_SECRET</key><string>$SECRET</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$HUB/logs/$N.log</string>
  <key>StandardErrorPath</key><string>$HUB/logs/$N.log</string>
</dict></plist>
PLIST
    desliga "$L"
    if liga "$P"; then echo "   $N: ligado"; else echo "   $N: FALHOU ao ligar no launchd (reprova no passo 5 e fica stdio)"; fi
  else
    echo "   [simulação] $P → $PY $HUB/bin/hub-proxy.py $N"
  fi
done

echo "== 5. esperar subir e testar como o Claude Code (initialize + tools/list + 1 chamada real só-leitura)"
OK=""
if [ "$APLICAR" = 1 ]; then
  for N in $NOMES; do
    PORTA=$("$PY" -c "import json;print(json.load(open('$HUB/servers.json'))['$N']['porta'])")
    for _ in $(seq 1 60); do curl -fsS -o /dev/null "http://127.0.0.1:$PORTA/status" 2>/dev/null && break; sleep 1; done
  done
  for N in $NOMES; do
    if MCP_HUB_TOKEN="$("$SECRET" get MCP_HUB_TOKEN)" MCP_HUB_SECRET="$SECRET" "$PY" "$HUB/bin/hub-teste.py" "$N"; then OK="$OK $N"; fi
  done
else
  echo "   [simulação] testaria: $NOMES"; OK="$NOMES"
fi

echo "== 6. trocar no Claude Code SÓ o que passou no teste (quem não passou fica stdio e perde o serviço)"
cd "$HOME"
FICOU=""
fica_stdio() {  # $1 nome, $2 motivo: sem serviço no launchd (não fica relançando nem gastando RAM)
  faz desliga "$PREFIXO.$1"
  faz rm -f "$HOME/Library/LaunchAgents/$PREFIXO.$1.plist"
  FICOU="$FICOU   $1: $2\n"
}
original() { "$PY" -c "import json,sys;c=json.load(open(sys.argv[1])).get(sys.argv[2],{}).get('config');print(json.dumps(c) if c else '')" "$ORIG" "$1"; }
volta_stdio() {  # $1 nome, $2 escopo: entrada que já usava o hub volta para a config original do backup
  local CFGO; CFGO="$(original "$1")"
  [ -n "$CFGO" ] || return 1
  "$CLAUDE" mcp remove -s "$2" "$1" >/dev/null 2>&1 </dev/null || true
  "$CLAUDE" mcp add-json -s "$2" "$1" "$CFGO" >/dev/null </dev/null
}
for N in $NOMES; do
  ESC=$("$PY" -c "import json;print(json.load(open('$AQUI/servers.json'))['$N']['escopo'])")
  PORTA=$("$PY" -c "import json;print(json.load(open('$AQUI/servers.json'))['$N']['porta'])")
  if ! tem "$OK" "$N"; then
    if ! tem "$JA_HUB" "$N"; then fica_stdio "$N" "reprovou no teste (linha FALHOU acima; log em $HUB/logs/$N.log)"
    elif volta_stdio "$N" "$ESC"; then fica_stdio "$N" "reprovou no teste; a entrada que usava o hub voltou para a config original"
    else fica_stdio "$N" "reprovou no teste e NÃO voltou para stdio (sem config original no backup ou falha do claude mcp): rode ./desfazer.sh"; fi
    continue
  fi
  if tem "$JA_HUB" "$N"; then echo "   $N ($ESC): já usa o hub"; continue; fi
  if ! tem "$NO_BACKUP" "$N"; then fica_stdio "$N" "não está no escopo $ESC do ~/.claude.json; nada a trocar"; continue; fi
  if [ "$APLICAR" != 1 ]; then
    echo "   [simulação] claude mcp remove -s $ESC $N; claude mcp add-json -s $ESC $N {type:http, url:http://127.0.0.1:$PORTA/mcp, headers:Authorization}"
    continue
  fi
  CFG=$(MCP_HUB_TOKEN="$("$SECRET" get MCP_HUB_TOKEN)" "$PY" -c "import json,os,sys;print(json.dumps({'type':'http','url':f'http://127.0.0.1:{sys.argv[1]}/mcp','headers':{'Authorization':'Bearer '+os.environ['MCP_HUB_TOKEN']}}))" "$PORTA")
  if ! "$CLAUDE" mcp remove -s "$ESC" "$N" >/dev/null </dev/null; then
    fica_stdio "$N" "FALHOU o claude mcp remove; a entrada antiga continua"; continue
  fi
  if "$CLAUDE" mcp add-json -s "$ESC" "$N" "$CFG" >/dev/null 2>&1 </dev/null; then
    echo "   $N ($ESC): agora usa http://127.0.0.1:$PORTA/mcp"
  elif "$CLAUDE" mcp add-json -s "$ESC" "$N" "$(original "$N")" >/dev/null </dev/null; then
    fica_stdio "$N" "FALHOU o add-json do hub; voltou a config original"
  else
    fica_stdio "$N" "FALHOU o add-json do hub E a volta da original: a entrada SUMIU (config em $ORIG; ./desfazer.sh volta tudo)"
  fi
done
[ "$APLICAR" = 1 ] && chmod 600 "$HOME/.claude.json"

echo "== pronto. Sessões novas já nascem leves; as abertas seguem com as cópias antigas até reiniciar (/resume mantém a conversa)."
if [ -n "$FICOU" ]; then echo "== ficou stdio (fora do hub):"; printf '%b' "$FICOU"; fi
echo "== pastas onde uma cópia local vence o hub (continua stdio nesta pasta; não mexi):"
"$PY" "$AQUI/bin/hub-pastas.py" || echo "   (não deu para listar)"
echo "   Conferir: ./status.sh · Voltar ao que era: ./desfazer.sh"
[ "$APLICAR" = 1 ] || echo "   (isto foi uma SIMULAÇÃO; para aplicar: ./instalar.sh --aplicar)"
