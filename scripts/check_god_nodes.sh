#!/usr/bin/env bash
# Gate anti-god-node: falha se um arquivo próprio passar do teto.
#
# O que mudou neste cabeçalho, e por quê: a versão anterior GRAVAVA os tamanhos
# medidos na prosa ("Server 1468, WorldCommands 1512, SQL 1267, companion/server.py
# 1248") e a medição do run já era outra — o próprio gate era o exemplo da doença
# que `scripts/check_doc_drift.sh` declara no cabeçalho dele ("doc que grava número
# apodrece em dias"). Número medido, aqui e em qualquer lugar desta repo, é o que o
# run imprime. O que fica no texto é decisão de política: quais arquivos estão na
# allowlist, por que estão, e qual teto cada um não pode cruzar.
#
# Escopo: sources/*.gd + companion/*.py (produto) sob MAX_LINES; tests/*.gd sob
# TESTS_MAX_LINES, um teto próprio e separado — o motivo está na seção "tests/"
# abaixo. Fora dos dois: addons/ (vendor).
#
# RATCHET (produto). Cada arquivo da allowlist tem um teto nomeado, e o teto é uma
# autorização de tamanho, não uma medição:
#   - nenhum arquivo pode passar do seu teto;
#   - um arquivo que encolhe tem que ter o teto baixado por quem o encolheu, senão o
#     teto velho é autorizado de novo crescimento silencioso;
#   - a banda RATCHET_SLACK é o máximo de folga que um teto pode ter sobre o medido.
#     Fora dela, o gate reclama do TETO, não do arquivo — é assim que o ratchet se
#     mantém vivo sem virar refém de cada linha escrita na rodada.
# Crescer acima do teto não é proibido por azar: é proibido por decisão, e a decisão
# é a de fatiar (precedente: EconomyService saiu da allowlist na Fatia 12, 3839 →
# 763 linhas em 12 fatias). Ver ROADMAP_COMERCIAL S3.
#
# Allowlist = legado em fatiação ativa, com o motivo de cada um:
#   sources/network/server/Server.gd  — autoridade de sessão/mundo/economia/chat.
#   sources/world/WorldCommands.gd    — comandos de jogador e de moderação
#       (/report /mute /unmute /reports /resolve vivem aqui, no mesmo dispatcher
#       dos comandos; foi o preço de ter um só funil de comando).
#   sources/sql/SQL.gd                — fachada de dados + mods.
#   sources/network/client/Client.gd  — lado do cliente.
#   sources/network/Network.gd        — RESTAURAÇÃO P4: os @rpc do motor DEVEM
#       viver no nó autoload Network; fragmentar quebrou o dispatch (ver teste
#       SuiteNetworkDispatch), então este arquivo é teto por contrato do motor.
#   companion/server.py               — monolito do gateway de webhook.
set -euo pipefail
MAX_LINES=800
# tests/ é governado por outra régua, e o motivo é estrutural: um harness é um
# registro EXECUTÁVEL de decisões — cada `func Suite*` é uma correção com a sua
# contra-prova, e "encolher" um harness significa apagar cobertura. O teto de 800
# linhas do produto existe porque módulo de composição grande vira god-node; não é
# o que um arquivo de suíte é. O teto único de tests/ continua sendo necessário
# justamente para a suíte não virar o segundo EconomyService desta repo (3839
# linhas antes da Fatia 12): ele é medido no run, e cruzá-lo significa FATIAR o
# harness em dois (ou levantar o teto com o motivo escrito na revisão — como no
# ratchet do produto, crescer é decisão, não acidente).
TESTS_MAX_LINES=9000
# Folga máxima entre o teto de um arquivo da allowlist e o que ele mede hoje.
RATCHET_SLACK=200
# Os tetos abaixo foram postos em "medido + 150" numa passada de 2026-09-27 09:40
# (banda de 200), para que crescimento e encolhimento tenham room antes de o gate
# reclamar; a banda inteira é verificada a cada run, e o número impresso é o do
# run — não este daqui.
declare -A RATCHET=(
  ["sources/network/server/Server.gd"]=1965
  ["sources/world/WorldCommands.gd"]=1925
  ["sources/sql/SQL.gd"]=1814
  ["sources/network/client/Client.gd"]=1139
  ["sources/network/Network.gd"]=1277
  ["companion/server.py"]=2068
)
fail=0
measured=0
maxLines=0
maxFile=""
testsMeasured=0
testsMax=0
testsMaxFile=""

# Arquivos citados no ratchet que sumiram da árvore: o teto órfão é o ratchet
# mentindo sobre um legado que já foi fatiado.
for a in "${!RATCHET[@]}"; do
  if [ ! -f "$a" ]; then
    echo "::error::ratchet: $a não existe mais — remova o teto de scripts/check_god_nodes.sh"
    fail=$((fail + 1))
  fi
done

while IFS= read -r f; do
  [ -f "$f" ] || continue
  cap="${RATCHET[$f]:-}"
  if [ -n "$cap" ]; then
    # Permitido por decisão, medido sempre: a linha do ratchet vai para a saída do
    # run, não para o comentário.
    lines=$(wc -l < "$f")
    echo "ratchet: $f = $lines linhas (teto $cap, folga $((cap - lines)))"
    if [ "$lines" -gt "$cap" ]; then
      echo "::error::ratchet: $f tem $lines linhas, acima do teto autorizado $cap. Fatiar é a saída; levantar o teto é decisão de revisão (ver ROADMAP_COMERCIAL S3)."
      fail=$((fail + 1))
    fi
    if [ "$((cap - lines))" -gt "$RATCHET_SLACK" ]; then
      echo "::error::ratchet velho: $f encolheu para $lines linhas e o teto ainda é $cap. Baixe o teto para no máximo $((lines + RATCHET_SLACK))."
      fail=$((fail + 1))
    fi
    continue
  fi
  # O listador é `git ls-files --cached`: um arquivo apagado na árvore mas ainda no
  # índice (deleção não preparada) aparece aqui, e `wc -l <` num caminho inexistente
  # mata o script no `set -e` com um erro que não é o do gate.
  measured=$((measured + 1))
  lines=$(wc -l < "$f")
  if [ "$lines" -gt "$maxLines" ]; then
    maxLines=$lines
    maxFile=$f
  fi
  if [ "$lines" -gt "$MAX_LINES" ]; then
    echo "::error::god-node: $f tem $lines linhas (teto $MAX_LINES). Fatie em módulos."
    fail=$((fail + 1))
  fi
done < <(git ls-files --cached --others --exclude-standard "sources/*.gd" "companion/*.py" 2>/dev/null || find sources companion -name "*.gd")

while IFS= read -r f; do
  [ -f "$f" ] || continue
  testsMeasured=$((testsMeasured + 1))
  lines=$(wc -l < "$f")
  if [ "$lines" -gt "$testsMax" ]; then
    testsMax=$lines
    testsMaxFile=$f
  fi
  if [ "$lines" -gt "$TESTS_MAX_LINES" ]; then
    echo "::error::teto de tests/: $f tem $lines linhas (teto $TESTS_MAX_LINES). Fatiar o harness é a saída; ver o cabeçalho deste script."
    fail=$((fail + 1))
  fi
done < <(git ls-files --cached --others --exclude-standard "tests/*.gd" 2>/dev/null || find tests -name "*.gd")

# Nada abaixo é número de comentário: é a medição deste run, impressa para o leitor
# conferir a régua com o arquivo real, não com o texto que alguém escreveu.
echo "medido neste run: teto do produto $MAX_LINES linhas; maior arquivo fora da allowlist $maxFile com $maxLines; teto de tests/ $TESTS_MAX_LINES linhas; maior harness $testsMaxFile com $testsMax (folga $((TESTS_MAX_LINES - testsMax)))."
# A contagem de falhas vai na linha de resultado de propósito: `scripts/test.sh all`
# espelha este gate pelo mesmo quádruplo de §24-8, que LÊ o número de falhas da
# linha (um exit code passado à mão não aprova nada). O marcador é o mesmo no verde
# e no vermelho.
if [ "$fail" -ne 0 ]; then
  echo "Gate anti-god-node: $fail failures em $((measured + testsMeasured)) arquivos medidos (teto produto $MAX_LINES, teto tests/ $TESTS_MAX_LINES, ${#RATCHET[@]} ratchets). Ver ROADMAP_COMERCIAL S3 (Fatia 2)."
  exit 1
fi
echo "Gate anti-god-node: 0 failures em $((measured + testsMeasured)) arquivos medidos (teto produto ${MAX_LINES} linhas, teto tests/ ${TESTS_MAX_LINES} linhas, ${#RATCHET[@]} na allowlist com ratchet)."
