#!/usr/bin/env bash
# Gate de rastreio — o que impede, de fato, um clone limpo não buildar.
#
# Por que este script existe: em 2026-09-28 o portão tinha 64 arquivos de PRODUTO e
# de GATE vivendo só no disco de uma máquina — módulos em `sources/`, harnesses em
# `tests/`, migrations em `data/conf/migrations/`, matérias-primas em
# `presets/cells/items/material/`, `companion/ad_ssv.py`, `data/conf/teardown_baseline.txt`.
# Todo gate verde, `git status` "limpo" para quem olha só os modificados, e um
# `git clone` que não builda: o harness chamado por `scripts/test.sh` não existe no
# clone, a migration que o boot aplica não existe, e o `MapsDB`/ItemsDB que as
# réguas de conteúdo varrem nasce sem as células que só existiam aqui. Um portão
# que só a máquina de quem escreve consegue rodar não é portão — é memória.
#
# O `.gitignore` não cobre isto: ele diz o que NÃO deve ser rastreado. Arquivo de
# produto que nunca foi `git add` não bate em nenhuma regra de ignore — ele é
# simplesmente invisível até `git status --porcelain`, que ninguém lia. É o mesmo
# formato de falha que `repo_layout_test.gd` caça para sonda na raiz e gate órfão:
# a peça existe, funciona, e não está no produto.
#
# Uso:   bash scripts/check_untracked.sh
# Saída: uma linha por regra ([PASS]/[FAIL]) e, no fim,
#        `== UNTRACKED GATE: N checks, M failures ==` — o formato é o que
#        scripts/ci_gate_log.sh lê. Exit code = nº de falhas.
#
# Ocultação: este gate imprime CAMINHOS, nunca conteúdo. Caminho já está no
# `git status` de quem escreve; conteúdo de arquivo não rastreado pode ser chave, e
# um gate que o catava para a log de CI aberta seria o vazador (mesma regra de
# scripts/check_secrets.sh).
#
# Lista de permissão: VAZIA de propósito. "Arquivo novo e ainda não decidido" é
# exatamente o estado que este gate recusa — a decisão é `git add` ou deletar, e
# adicionar uma linha aqui é um ato do dono, não um ajuste de run. O que é
# descartável já está no `.gitignore` (`.test-home*/`, `data/db/testing.db*`,
# `__pycache__/`, `.env*`), então `--exclude-standard` não devolve nada disso.
set -uo pipefail

ROOT="${SHAMBLETA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 1

CHECKS=0
FAILURES=0

pass() { CHECKS=$((CHECKS + 1)); printf '[PASS] %s\n' "$1"; }
fail() {
	CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1))
	printf '[FAIL] %s\n' "$1"
	[ $# -gt 1 ] && printf '       ESPERADO: %s\n       ENCONTRADO: %s\n' "$2" "$3"
	return 0
}

if git rev-parse --git-dir >/dev/null 2>&1; then
	idxcount=$(git ls-files | wc -l)
	if [ "$idxcount" -lt 1000 ]; then
		fail "o índice do git tem $idxcount arquivos — isto é um repo quebrado, não um repo limpo" \
			">= 1000 arquivos rastreados (medido hoje: 3643)" "$(git rev-parse --git-dir)"
		echo "== UNTRACKED GATE: $CHECKS checks, $FAILURES failures =="
		exit 1
	fi
	pass "índice do git legível e inteiro para o portão ($idxcount arquivos rastreados)"
else
	fail "índice do git ilegível em $ROOT" "um repositório git" "rev-parse falhou"
	echo "== UNTRACKED GATE: $CHECKS checks, $FAILURES failures =="
	exit 1
fi

# ------------------------------------------------- (1) nada de produto solto
# `--others` = não rastreado; `--exclude-standard` = respeitando .gitignore e
# excludes globais, i.e. sobra exatamente o que um `git add -A` acrescentaria.
UNTRACKED="$(git ls-files --others --exclude-standard)"
if [ -z "$UNTRACKED" ]; then
	pass "zero arquivo fora do índice (git ls-files --others --exclude-standard vazio)"
else
	n=$(printf '%s\n' "$UNTRACKED" | wc -l)
	fail "$n arquivo(s) de produto/gate existem só no disco — o clone limpo não os terá" \
		"lista vazia (git add <path> ou delete)" "$(printf '%s\n' "$UNTRACKED" | head -20 | tr '\n' ' ')"
fi

# ------------------------------------- (2) migration do boot está no índice
# O runner aplica `data/conf/migrations/*.sql` em ordem; uma migration que só
# existe numa máquina muda o schema do banco de quem roda o gate e não de quem
# clona — e as réguas que conferem EXPLAIN/columns (`scale_test`, `doc_facts_test`)
# passam verde contra um schema que o produto lançado não tem.
MIG_UNTRACKED="$(git ls-files --others --exclude-standard -- data/conf/migrations)"
if [ -z "$MIG_UNTRACKED" ]; then
	mcount=$(git ls-files -- data/conf/migrations | wc -l)
	pass "$mcount migrations do boot rastreadas (nenhuma solta em data/conf/migrations/)"
else
	fail "migration aplicada pelo boot fora do índice" \
		"toda .sql em data/conf/migrations/ rastreada" "$(printf '%s\n' "$MIG_UNTRACKED" | tr '\n' ' ')"
fi

# --------------------------- (3) todo insumo do portão está no clone
# `scripts/test.sh` nomeia harnesses (`gate <log> <marker> <script>`) e gates de
# shell (`gate_sh <log> <marker> <script>`); a CI roda o mesmo arquivo. Um nome que
# não está no índice é job que falha no clone — ou, pior, `test.sh` que roda
# `godot -s tests/<algo>.gd` sobre um arquivo inexistente e morre sem marcador.
# `scripts/test.sh` nomeia o insumo de três formas: `gate <log> "<marcador>" <nome>
# <timeout>` (harness Godot → `tests/<nome>.gd`), `gate_sh <log> "<marcador>"
# <caminho>` (gate de shell, caminho como digitado) e `gate_py <log> "<marcador>"
# <nome>` (suíte do companion → `companion/<nome>.py`; o `test_` já vem no nome que
# test.sh escreve, e presumir o prefixo inventou `test_test_webhook.py` — régua que
# reprova o repo por um erro de leitura dela mesma é pior que régua ausente).
# Extrair por número de campo NÃO funciona e foi a primeira versão disto: o marcador
# tem espaço e aspas, então `awk '{print $4}'` devolvia `RESULT:"` e `"$script")"`
# — uma régua que acusava 18 insumos inexistentes e nenhum deles real. O padrão
# abaixo casa a FORMA de cada chamada (nome da função, log, um argumento entre aspas
# sem aspas dentro, o insumo, e no caso do `gate` um timeout final em dígitos) e só
# extrai quando a linha é aquilo.
# A chamada genérica do laço (`gate "/tmp/shambleta-${script}.log" "$(harness_marker
# …)" …`, nome calculated em runtime) não casa, de propósito: ela não nomeia arquivo
# algum, e quem cobre os harnesses descobertos do disco é a regra (1) acima — que
# exige TODO arquivo do disco no índice, inclusive os `tests/*_test.gd`.
MISSING=""
REFS="$(sed -nE \
	-e 's/^[[:space:]]*gate[[:space:]]+[^[:space:]]+[[:space:]]+"[^"]*"[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+[0-9]+[[:space:]]*$/tests\/\1.gd/p' \
	-e 's/^[[:space:]]*gate_sh[[:space:]]+[^[:space:]]+[[:space:]]+"[^"]*"[[:space:]]+([[:graph:]]+)[[:space:]]*$/\1/p' \
	-e 's/^[[:space:]]*gate_py[[:space:]]+[^[:space:]]+[[:space:]]+"[^"]*"[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*$/companion\/\1.py/p' \
	scripts/test.sh | sort -u)"
for ref in $REFS; do
	[ -f "$ref" ] || { MISSING="$MISSING $ref(ausente do disco)"; continue; }
	git ls-files --error-unmatch "$ref" >/dev/null 2>&1 || MISSING="$MISSING $ref(for fora do índice)"
done
refcount=$(printf '%s\n' $REFS | wc -l)
if [ -n "$MISSING" ]; then
	fail "insumo do portão indisponível para um clone" \
		"cada path nomeado em test.sh rastreado" "$MISSING"
elif [ "$refcount" -lt 15 ]; then
	# A régua que resolveu 3 insumos é a régua que quebrou, não o repo que ficou
	# limpo: 5 `gate` + 6 `gate_sh` + 7 `gate_py` hoje, e um extrator mudo aprovado
	# seria o sucesso mais barato de fingir.
	fail "a extração de insumos de scripts/test.sh regrediu" \
		">= 15 insumos nomeados (gate + gate_sh + gate_py)" "$refcount nomes: $(printf '%s ' $REFS)"
else
	pass "todo harness/gate chamado por scripts/test.sh existe E está no índice ($refcount insumos nomeados)"
fi

# ------------------------------- (4) recurso referenciado por caminho literal
# `preload("res://…")`/`load("res://…")`/`ext_resource path="res://…"` de arquivo
# RASTREADO apontando para um recurso fora do índice é o caso silencioso do item
# (1): o produto referencia o arquivo, o clone não o tem, e o erro aparece em
# runtime de quem instala — não no portão de quem escreveu. Só caminho LITERAL com
# extensão; nada com `%`/formato, que é resolvido em tempo de execução.
REFS="$(grep -rhoaE '(path=")?res://[A-Za-z0-9_./-]+\.(gd|tscn|tres|csv|json|png|svg|ttf|ogg|wav|ttb)' \
	sources presets data tests .github 2>/dev/null | sed 's/^path="//; s|^res://||' | sort -u)"
BROKEN=""
for rel in $REFS; do
	[ -e "$rel" ] || continue	# caminho que nem no disco existe é outro defeito (boot reclama)
	git ls-files --error-unmatch "$rel" >/dev/null 2>&1 || BROKEN="$BROKEN $rel"
done
refcount=$(printf '%s\n' $REFS | wc -l)
if [ -n "$BROKEN" ]; then
	fail "recurso referenciado por código rastreado está fora do índice" \
		"referência resolúvel no clone" "$BROKEN"
elif [ "$refcount" -lt 500 ]; then
	# Mesma defesa da regra (3): um grep que volta vazio aprava esta régua sem
	# olhar nada. Medido hoje: 1717 caminhos `res://` literais distintos.
	fail "a extração de res:// literais regrediu" \
		">= 500 caminhos literais com extensão de recurso" "$refcount caminhos"
else
	pass "todo res:// literal de arquivo rastreado aponta para arquivo no índice ($refcount caminhos verificados)"
fi

printf 'escopo: índice + árvore de trabalho; `--exclude-standard` mantém descartável (.test-home*/, testing.db, __pycache__, .env*) fora da contagem\n'
echo "== UNTRACKED GATE: $CHECKS checks, $FAILURES failures =="
exit "$FAILURES"
