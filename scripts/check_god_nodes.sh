#!/usr/bin/env bash
# Gate anti-god-node: falha se algum .gd próprio passar de 800 linhas.
# Escopo: sources/ + companion/ (código próprio). Fora: addons/ (vendor),
# tests/ (suíte consolidada por desenho).
# Allowlist = legado em fatiação ativa (não aumentar; fatiar):
# EconomyService SAIU da allowlist na Fatia 12 (3839→763 linhas; 12
# fatias, 14 módulos: catálogo 620, guild 348, checkout/grants 305, seasons 181,
# passe 438, AH 301, loja 273, forja 406, boss 372, ads+cosméticos 237,
# competição 320, comunidade 372, troca+baús 208, kernel 196). O que sobrou é
# kernel de composição (mutex único, catálogo de serviços, _process) + fachada
# de wrappers — callers externos e os serviços nunca mudaram de assinatura.
# Server 1468, WorldCommands 1512, SQL 1267 (facade+mods),
# Client 876, Network 1062 (RESTAURAÇÃO P4: os @rpc do motor DEVEM viver no nó
# autoload Network — fragmentar quebrou o dispatch; ver teste SuiteNetworkDispatch),
# companion/server.py 1248 (monolito do gateway).
# Os dois primeiros cresceram nesta rodada e é preciso dizer por quê: WorldCommands
# recebeu os comandos de moderação (/report /mute /unmute /reports /resolve) e
# Server.gd recebeu o portão de mute no TriggerChat. São os próximos a fatiar — a
# allowlist registra legado, não autoriza crescimento.
# Ver ROADMAP_COMERCIAL S3 (Fatiar EconomyService).
set -euo pipefail
MAX_LINES=800
ALLOWLIST=(
  "sources/network/server/Server.gd"
  "sources/world/WorldCommands.gd"
  "sources/sql/SQL.gd"
  "sources/network/client/Client.gd"
  "sources/network/Network.gd"
  "companion/server.py"
)
fail=0
measured=0
while IFS= read -r f; do
  skip=false
  for a in "${ALLOWLIST[@]}"; do
    if [ "$f" = "$a" ]; then skip=true; break; fi
  done
  if [ "$skip" = true ]; then continue; fi
  # O listador é `git ls-files --cached`: um arquivo apagado na árvore mas ainda no
  # índice (deleção não preparada) aparece aqui, e `wc -l <` num caminho inexistente
  # mata o script no `set -e` com um erro que não é o do gate.
  [ -f "$f" ] || continue
  measured=$((measured + 1))
  lines=$(wc -l < "$f")
  if [ "$lines" -gt "$MAX_LINES" ]; then
    echo "::error::god-node: $f tem $lines linhas (teto $MAX_LINES). Fatie em módulos."
    fail=$((fail + 1))
  fi
done < <(git ls-files --cached --others --exclude-standard "sources/*.gd" "companion/*.py" 2>/dev/null || find sources companion -name "*.gd")
# A contagem de falhas vai na linha de resultado de propósito: `scripts/test.sh all`
# espelha este gate pelo quádruplo de §24-8, que LÊ o número de falhas da linha (um
# exit code passado à mão não aprova nada). O marcador é o mesmo no verde e no vermelho.
if [ "$fail" -ne 0 ]; then
  echo "Gate anti-god-node: $fail failures em $measured arquivos medidos (teto $MAX_LINES linhas). Ver ROADMAP_COMERCIAL S3 (Fatia 2)."
  exit 1
fi
echo "Gate anti-god-node: 0 failures em $measured arquivos medidos (teto ${MAX_LINES} linhas; ${#ALLOWLIST[@]} em allowlist)."
