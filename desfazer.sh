#!/bin/bash
# desfazer.sh — volta os servidores MCP ao modo antigo (uma cópia por sessão) e desliga o hub.
# Usa o backup mais recente gravado pelo instalar.sh em ~/.claude/mcp-hub/backups/.
set -euo pipefail

HUB="${MCP_HUB_DIR:-$HOME/.claude/mcp-hub}"
PY="${MCP_HUB_PY:-$(uv tool dir 2>/dev/null || echo "$HOME/.local/share/uv/tools")/mcp-proxy/bin/python}"
PREFIXO="${MCP_HUB_LABEL:-local.mcp-hub}"
UIDN="$(id -u)"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
desliga_hub() {  # roda SEMPRE na saída (trap), mesmo se a restauração falhar no meio
  for P in "$HOME"/Library/LaunchAgents/"$PREFIXO".*.plist; do
    [ -e "$P" ] || continue
    L="$(basename "$P" .plist)"
    launchctl bootout "gui/$UIDN/$L" 2>/dev/null || true
    rm -f "$P"
  done
  echo "== hub desligado. Sessões novas voltam a subir as próprias cópias."
}
ORIG="$(ls -t "$HUB"/backups/original-mcp.*.json 2>/dev/null | head -1 || true)"
[ -n "$ORIG" ] || { echo "sem backup em $HUB/backups (o hub foi instalado?)"; exit 1; }
trap desliga_hub EXIT
echo "== restaurando a partir de $ORIG"

cd "$HOME"
# </dev/null nas chamadas do claude: sem isso ele pode ler o resto da lista que alimenta o while
"$PY" - "$ORIG" <<'PYEOF' | while IFS=$'\t' read -r nome escopo cfg; do
import json, sys
for nome, v in json.load(open(sys.argv[1])).items():
    print(f"{nome}\t{v['escopo']}\t{json.dumps(v['config'])}")
PYEOF
  if [ "$cfg" = "null" ]; then
    echo "   FALHOU: $nome sem config original neste backup; não mexi (cópias inteiras do ~/.claude.json em $HUB/backups/claude.json.*)"
    continue
  fi
  "$CLAUDE" mcp remove -s "$escopo" "$nome" >/dev/null 2>&1 </dev/null || true
  "$CLAUDE" mcp add-json -s "$escopo" "$nome" "$cfg" >/dev/null </dev/null \
    || { echo "   FALHOU: $nome não voltou (claude mcp add-json); a config original está em $ORIG"; continue; }
  echo "   $nome: voltou para stdio"
done || echo "   FALHOU: a restauração parou no meio; o que não aparece acima como 'voltou' ficou como estava"
