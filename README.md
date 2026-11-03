# mcp-hub: cada servidor MCP rodando uma vez só

Cada sessão do Claude Code sobe a própria cópia de cada servidor MCP stdio. Com uma ou duas sessões ninguém percebe. Eu rodo até 16 ao mesmo tempo no mesmo Mac e ele começou a travar: só os servidores MCP ocupavam de 12 a 14 GB de RAM, e o swap encostou no limite.

O hub sobe cada servidor uma vez, como serviço do macOS (launchd), atrás de um [`mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) que só escuta em `127.0.0.1`. O Claude Code passa a falar com ele por HTTP e todas as sessões dividem o mesmo processo.

## Números do meu Mac

| | antes | com o hub |
|---|---|---|
| 9 servidores MCP | 12 a 14 GB (23/10/2026, duas medições, com 16 e 27 sessões abertas) | ~1 GB (03/11/2026, 13 sessões) |

Medido com `top`, contando a memória comprimida. Antes, por servidor, com 16 sessões:

| servidor | processos | memória |
|---|---|---|
| gmail (duas contas) | 64 | 3,8 GB |
| supabase (dois projetos) | 64 | 2,9 GB |
| google-workspace | 16 | 1,9 GB |
| discord | 30 | 1,5 GB |
| asana | 30 | 1,5 GB |
| dataforseo | 32 | 1,3 GB |
| idea-reality | 16 | 1,2 GB |

Em 11 dias ligado, o vigia não precisou reiniciar nenhum servidor. De quebra, a sessão nova não precisa rodar `npx` para cada servidor ao abrir, e o bot do Discord fica com uma conexão só, em vez de uma por sessão.

## Como funciona

- Um `mcp-proxy` por servidor, cada um numa porta fixa em `127.0.0.1`.
- Os segredos (token do Supabase, do Asana etc.) são lidos do cofre na subida e não ficam gravados em arquivo. O cofre é o comando [`secret`](https://github.com/olucasdomkt/ferramentas-claude-code), que guarda no Keychain do macOS. Serve qualquer comando que entenda `get NOME`, `has NOME` e `set NOME VALOR` (aponte com `MCP_HUB_SECRET`).
- Toda chamada precisa do token do hub (`Authorization: Bearer`, guardado no cofre como `MCP_HUB_TOKEN`). Assim, outro programa da máquina não usa o seu Gmail pelo hub. Sem o token a resposta é 401. Com `Origin` de um site externo, 403. Com um `Host` que não seja `127.0.0.1` ou `localhost`, 400, o que impede que um site use DNS rebinding para chegar ao servidor pelo navegador.
- Se o servidor filho morrer, o proxy sai e o launchd sobe de novo.
- Os servidores node ficam com versão fixa (`node/package.json`), em vez de um `npx ...@latest` que puxa qualquer versão nova publicada em toda sessão.

## Instalar (macOS)

Precisa de [uv](https://docs.astral.sh/uv/), node, a CLI `claude` e o `secret`.

```bash
git clone https://github.com/olucasdomkt/claude-code-mcp-hub.git
cd claude-code-mcp-hub
uv tool install mcp-proxy==0.13.0

cp servers.exemplo.json servers.json      # deixe só os seus servidores
secret set SUPABASE_PAT                   # um por segredo citado no servers.json

mkdir -p ~/.claude/mcp-hub/node && cp node/package.json ~/.claude/mcp-hub/node/
npm install --prefix ~/.claude/mcp-hub/node

./instalar.sh             # simulação: só mostra o que faria
./instalar.sh --aplicar   # liga
./status.sh               # serviços, teste real, memória e cópias antigas
```

O nome de cada servidor no `servers.json` tem que ser igual ao do `~/.claude.json`. O que o `--aplicar` faz:

1. Copia `bin/` e `servers.json` para `~/.claude/mcp-hub/`.
2. Guarda em `~/.claude/mcp-hub/backups/` a configuração original de cada servidor (permissão 600).
3. Cria o `MCP_HUB_TOKEN` no cofre, se ainda não existir.
4. Cria um LaunchAgent por servidor (`local.mcp-hub.<nome>`), que sobe no login e volta se cair.
5. Testa cada um como o Claude Code faz (`initialize` e `tools/list`) e, se o servidor tiver `teste` no `servers.json`, faz uma chamada real só de leitura para provar a credencial.
6. Só troca no Claude Code o que passou no teste. O que reprovar continua como estava e perde o serviço.

As sessões já abertas seguem com as cópias antigas até reiniciar. As novas já nascem leves. Rodar o `--aplicar` de novo é seguro: o que já usa o hub não é trocado outra vez.

Para voltar ao que era: `./desfazer.sh`. Ele depende do backup do passo 2, que tem os tokens originais em texto. Se você apagar esse backup para não deixar token em arquivo, a volta passa a ser à mão.

Variáveis: `MCP_HUB_DIR` (padrão `~/.claude/mcp-hub`), `MCP_HUB_PY` (o python do mcp-proxy), `MCP_HUB_SECRET` (o comando do cofre) e `MCP_HUB_LABEL` (prefixo dos LaunchAgents, padrão `local.mcp-hub`).

## Antes de pôr um servidor no hub

- **Servidor que bloqueia trava todo mundo.** No hub, um processo atende todas as sessões. Se o servidor faz chamada de rede síncrona dentro de `async def`, uma consulta longa de uma sessão segura as outras, inclusive a abertura. Foi o caso do servidor do Search Console que eu uso (`mcp-gsc`), que ficou fora. Antes de incluir um servidor, confira no código se as chamadas de rede usam `await` ou `asyncio.to_thread`.
- **Cópia local vence o hub.** Uma entrada de escopo local (ou o `.mcp.json` de uma pasta) tem prioridade sobre a de escopo user, e nessa pasta o servidor continua uma cópia por sessão. O `instalar.sh` e o `status.sh` listam essas pastas, sem mexer nelas.

## Limites conhecidos

- Se o hub ficar fora do ar por mais de uns 4 minutos, a sessão aberta desiste de reconectar e as ferramentas daquele servidor somem até você rodar `/mcp`. Queda curta reconecta sozinha.
- Os serviços usam o node do terminal que rodou o instalador. Trocou a versão no nvm? Rode `./instalar.sh --aplicar` de novo.
- O token do hub fica no header da entrada do `~/.claude.json`, que o instalador deixa com permissão 600. Na troca do passo 6 ele passa como argumento do `claude mcp add-json` e aparece no `ps` por cerca de um segundo.
- Feito para Mac de um usuário só. Porta acima de 1024 qualquer conta da máquina consegue abrir: se o hub estiver parado e outra conta ocupar a porta, as sessões do Claude Code mandam a ela o token e as chamadas. O `hub-teste.py` confere o dono da porta antes de mandar o token, mas o Claude Code não faz essa conferência.
- O filtro de Host e o token entram trocando uma classe interna do `mcp-proxy`. Foi testado com a versão 0.13.0; uma versão nova pode mudar esse ponto, por isso a instalação fixa a versão.

## Licença

MIT ([LICENSE](LICENSE)). Feito por Lucas Lacerda.
