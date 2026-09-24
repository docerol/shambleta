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
# Server 1377, WorldCommands 1363, SQL 1217 (facade+mods),
# Client 870, Network 1026 (RESTAURAÇÃO P4: os @rpc do motor DEVEM viver no nó
# autoload Network — fragmentar quebrou o dispatch; ver teste SuiteNetworkDispatch),
# companion/server.py (monolito do gateway).
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
while IFS= read -r f; do
  skip=false
  for a in "${ALLOWLIST[@]}"; do
    if [ "$f" = "$a" ]; then skip=true; break; fi
  done
  if [ "$skip" = true ]; then continue; fi
  lines=$(wc -l < "$f")
  if [ "$lines" -gt "$MAX_LINES" ]; then
    echo "::error::god-node: $f tem $lines linhas (teto $MAX_LINES). Fatie em módulos."
    fail=1
  fi
done < <(git ls-files --cached --others --exclude-standard "sources/*.gd" "companion/*.py" 2>/dev/null || find sources companion -name "*.gd")
if [ "$fail" -ne 0 ]; then
  echo "Gate anti-god-node FALHOU. Ver ROADMAP_COMERCIAL S3 (Fatia 2)."
  exit 1
fi
echo "Gate anti-god-node OK (teto ${MAX_LINES} linhas; legado em allowlist)."
