#!/usr/bin/env bash
# Gate do próprio gate — `scripts/ci_gate_log.sh` é a régua que lê o veredito de todos
# os outros portões, e até aqui ela só era exercitada pelos runs reais dela própria.
#
# Por que isto existe: o bloco de ruído externo (a terceira conta do §24-8, que diz
# "este run verde NÃO leu as réguas de wall-clock porque a máquina estava tomada") foi
# escrito agora, e uma mudança de quatro linhas no leitor de log pode apagar a
# contabilidade inteira sem que NENHUM veredito mude — porque o que ele faz é imprimir
# uma nota, não falhar. Régua sem controles não é régua (a casa já foi enganada três
# vezes por esse formato: o `check_doc_drift.sh` lendo prosa, o gate de teardown sem
# chamador, e o `exit 1` que o gate idle achava no comentário). Aqui o controle é
# sintético e mutante: o fixture é escrito pelo próprio script, então cada ramo do
# leitor — passa, falha por marcador, falha por contagem, falha por leak, nota de
# ruído, e o caso "sem linha de ruído nenhuma" — é forçado a acontecer num run de
# dois segundos, sem depender de um host carregado para existir.
#
# Uso:   bash scripts/check_gate_log.sh
# Saída: uma linha por regra ([PASS]/[FAIL]) e, no fim,
#        `== GATE-LOG: N checks, M failures ==` — o formato que o próprio
#        scripts/ci_gate_log.sh lê. Exit code = nº de falhas.
#
# Segunda coisa que este script não é: um teste de Godot. Nada aqui abre o projeto,
# então o gate roda em qualquer máquina, carregada ou não — inclusive para um juiz.
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

# afere — $1 rótulo, $2 exit esperado, $3 exit obtido, $4 saída, $5 string que TEM de
# estar na saída (vazio = não interessa), $6 string que NÃO pode estar (vazio = idem).
afere() {
	local label="$1" wantCode="$2" gotCode="$3" out="$4" want="$5" forbid="$6"
	if [ "$wantCode" != "$gotCode" ]; then
		fail "$label" "exit $wantCode" "exit $gotCode"
		return 0
	fi
	if [ -n "$want" ] && ! printf '%s' "$out" | grep -qF -- "$want"; then
		fail "$label" "saída contém: $want" "saída sem a string"
		return 0
	fi
	if [ -n "$forbid" ] && printf '%s' "$out" | grep -qF -- "$forbid"; then
		fail "$label" "saída NÃO contém: $forbid" "a string apareceu"
		return 0
	fi
	pass "$label"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Log-base de um run verde: marcador presente, zero falhas, nenhum leak. O `godot
# exit=0` no fim é o que o chamador real (`gate()` em scripts/test.sh) anexa.
verde() {
	{
		echo "Godot Engine v-fixture (headless)"
		echo "  [ok] check qualquer"
		[ -n "${1:-}" ] && printf '%s\n' "$1"
		echo "== RESULT: 12 checks, 0 failures =="
		echo "godot exit=0"
	} > "$WORK/$2"
}

run_gate() {
	bash scripts/ci_gate_log.sh "$1" "== RESULT:" "${2:-0}" "${3:-fixture}" 2>&1
}

verde "" "plain.log"
out="$(run_gate "$WORK/plain.log")"; code=$?
afere "verde simples: gate aceita um run com marcador, zero falhas e nenhum leak" 0 "$code" "$out" "Gate §24-8 OK" ""

# O ramo que o §24-8 combate: ausência da linha de ruído NÃO é zero. Um harness sem a
# régua (todos os outros 30) tem de sair do leitor sem nota nenhuma — se o leitor
# resolvesse ausência como "0 janelas, tudo lido", ele estaria a afirmar que réguas
# foram medidas onde ninguém as mediu.
afere "ruído ausente é silêncio, não zero: log sem a linha de gancho não recebe nota" 0 "$code" "$out" "" "ruído"

verde "== NOISE-DECLARED: 0 ==" "clean.log"
out="$(run_gate "$WORK/clean.log")"; code=$?
afere "ruído zero declarado: leitor diz que todas as janelas foram lidas" 0 "$code" "$out" "todas as janelas" "::notice::"

verde "== RUÍDO EXTERNO: 3 janelas sem CPU livre (pico 61% da máquina comido por outro processo) => 18 réguas de tempo NÃO lidas; 5 re-medições esperando janela limpa (43s de espera) ==
== NOISE-DECLARED: 3 ==" "noisy.log"
out="$(run_gate "$WORK/noisy.log")"; code=$?
afere "ruído declarado: o run continua verde e a nota diz que as réguas de tempo não foram lidas" 0 "$code" "$out" "::notice::fixture declarou 3 janela(s)" ""
afere "ruído declarado: a linha humana do harness vai para o log do job junto" 0 "$code" "$out" "18 réguas de tempo NÃO lidas" ""

# Os quatro ramos de falha, um por assinatura (§24-8): sem eles a nota de ruído pode
# ser a única linha nova num arquivo que parou de barrar qualquer coisa.
{ echo "== RESULT: 12 checks, 1 failures =="; echo "  [FAIL] algo"; echo "godot exit=1"; } > "$WORK/fail.log"
out="$(run_gate "$WORK/fail.log" 1)"; code=$?
afere "contagem lida do log barra um run com check falho (mesmo com exit 0 passado à mão)" 1 "$code" "$out" "1 checks falhos" "Gate §24-8 OK"

{ echo "SCRIPT ERROR: Parse Error: algo"; echo "== RESULT: 12 checks, 0 failures =="; } > "$WORK/parse.log"
out="$(run_gate "$WORK/parse.log")"; code=$?
# O RÓTULO não pode citar o marcador literal: quem lê o log deste gate é a mesma
# régua que ele testa, e `ci_gate_log.sh` varre `SCRIPT ERROR|Parse Error` em qualquer
# linha. Medido em 2026-09-28: `all` vermelhou este gate com 16 checks e 0 falhas,
# acusando a própria linha `[PASS] SCRIPT ERROR barra…`. O que barra é o texto do
# produto, não o nome do case — o needle abaixo continua sendo o marcador cru.
afere "erro de parse do motor barra antes do marcador" 1 "$code" "$out" "SCRIPT ERROR" "Gate §24-8 OK"

{ echo "ERROR: 500 ObjectDB instances were leaked at exit"; echo "== RESULT: 12 checks, 0 failures =="; } > "$WORK/leak.log"
out="$(run_gate "$WORK/leak.log")"; code=$?
afere "teardown acima do teto medido barra (500 > 64 do harness sem baseline)" 1 "$code" "$out" "acima do teto medido" "Gate §24-8 OK"

# Um gate que cita o marcador na própria prosa SE ACUSA: o stdout dos scripts
# registrados em `structure_gates()` É o log que `ci_gate_log.sh` varre atrás de
# `SCRIPT ERROR|Parse Error`, e a colisão foi medida em 2026-09-28 — o `all` vermelhou
# este próprio arquivo com a linha `[PASS] SCRIPT ERROR barra antes do marcador`, com
# 16 checks e 0 falhas. A régua é estática e julga só o RÓTULO impresso (o `needle` de
# um `afere` é dado, não saída, e continua permitindo o marcador cru).
fatal_labels() {
	awk '!/^[[:space:]]*#/ {
		if (match($0, /^[[:space:]]*(afere|check|pass|fail|echo|printf)[[:space:]]+"[^"]*"/)) {
			s = substr($0, RSTART, RLENGTH); gsub(/^[^"]*"/, "", s); gsub(/"$/, "", s)
			if (s ~ /SCRIPT ERROR|Parse Error/) print s
		}
	}' "$1"
}
gate_scripts="$(sed -nE 's/^[[:space:]]*gate_sh[[:space:]]+[^[:space:]]+[[:space:]]+"[^"]*"[[:space:]]+(scripts\/[a-z_0-9]+\.sh).*/\1/p' scripts/test.sh)"
if [ -n "$gate_scripts" ]; then
	pass "os gates de estrutura foram lidos do registro em scripts/test.sh"
else
	fail "nenhum gate de estrutura foi lido de scripts/test.sh — a régua de prosa está cega" "lista não vazia" "vazia"
fi
for gate_script in $gate_scripts; do
	hits="$(fatal_labels "$gate_script")"
	if [ -z "$hits" ]; then
		pass "$gate_script não cita marcador fatal no que imprime"
	else
		fail "$gate_script imprime um marcador que o próprio leitor barra" "prosa sem literal" "$hits"
	fi
done
# Controle plantado, porque régua sem dente é enfeite: um gate fictício cujo RÓTULO
# acusa. A linha de baixo é o mesmo literal na posição de `needle` e NÃO pode ser pega.
{ echo 'afere "SCRIPT ERROR barra antes" 1 a b c d'; } > "$WORK/prosa-ruim.sh"
{ echo 'afere "rota, não marcador" 1 a b "SCRIPT ERROR" "OK"'; } > "$WORK/prosa-agulha.sh"
if [ -n "$(fatal_labels "$WORK/prosa-ruim.sh")" ]; then
	pass "o rótulo plantado com marcador é pego pela régua de prosa"
else
	fail "a régua de prosa não morde o rótulo plantado" "uma acusação" "silêncio"
fi
if [ -z "$(fatal_labels "$WORK/prosa-agulha.sh")" ]; then
	pass "o needle na segunda posição não é confundido com prosa"
else
	fail "a régua de prosa acusou um needle, que é dado e não saída" "silêncio" "acusação"
fi

# Deriva de leitor: o gancho é lido em DOIS lugares — aqui, para a nota do job, e em
# `_noise_declared()` de scripts/test.sh, para a linha `== GATES COM RUÍDO: ==` da
# passada inteira. Dois leitores independentes do mesmo formato é a família de defeito
# que esta casa já enterrou (workflow e script local divergindo). A régua é a string
# literal do sed: se um dos dois mudar o padrão, o outro para de casar e o gate acusa.
HOOK='== NOISE-DECLARED: ([0-9]+) ==$/\1/p'
for reader in scripts/ci_gate_log.sh scripts/test.sh; do
	if grep -qF -- "$HOOK" "$reader"; then
		pass "$reader lê o gancho com o padrão canônico"
	else
		fail "$reader desviou do padrão do gancho de ruído" "$HOOK" "ausente no arquivo"
	fi
done

# E o produtor do gancho: um harness que imprima a linha com outro texto faz os dois
# leitores acima calarem em silêncio — verde sem nota, que é pior que vermelho.
if grep -qF -- 'print("== NOISE-DECLARED: %d ==" % noiseWindows)' tests/multi_instance_tick_test.gd; then
	pass "tests/multi_instance_tick_test.gd imprime o gancho no formato canônico"
else
	fail "o harness não imprime mais o gancho de ruído" 'print("== NOISE-DECLARED: %d ==" % noiseWindows)' "ausente"
fi

# Sumário da passada: as duas linhas têm de existir (inclusive a de zero), porque
# "GATES COM RUÍDO" sumido do output é a mesma afirmação falsa de um portão que não
# conta flake.
if grep -qF -- 'echo "== GATES COM RUÍDO: none =="' scripts/test.sh \
	&& grep -qF -- 'echo "== GATES COM RUÍDO:$NOISY =="' scripts/test.sh; then
	pass "scripts/test.sh imprime a conta de ruído sempre, com e sem casos"
else
	fail "scripts/test.sh não imprime as duas formas da linha de resumo" 'GATES COM RUÍDO: none e GATES COM RUÍDO:$NOISY' "faltando"
fi

# Prova de ponta a ponta do extrator de `test.sh`: a função é extraída do arquivo e
# executada AQUI, contra os mesmos fixtures do leitor. Se alguém quebrar o extrator
# (aspas, âncora, `tail -n 1`), a linha de resumo passa a dizer "none" num run que
# declarou 3 janelas — e nada mais no repo conta essa mentira.
extract="$(sed -nE '/^_noise_declared\(\) \{/,/^\}/p' scripts/test.sh)"
if [ -z "$extract" ]; then
	fail "não encontrei _noise_declared() em scripts/test.sh para executar" "função presente" "extração vazia"
else
	# shellcheck disable=SC2091
	eval "$extract"
	got3="$(_noise_declared "$WORK/noisy.log")"
	got0="$(_noise_declared "$WORK/clean.log")"
	gotNone="$(_noise_declared "$WORK/plain.log")"
	gotMissing="$(_noise_declared "$WORK/nao-existe.log")"
	[ "$got3" = "3" ] && pass "extrator de test.sh lê 3 do log ruidoso" || fail "extrator de test.sh não lê o número" "3" "'$got3'"
	[ "$got0" = "0" ] && pass "extrator de test.sh lê 0 do log limpo (e 0 não entra na lista)" || fail "extrator de test.sh não lê o zero" "0" "'$got0'"
	[ -z "$gotNone" ] && pass "extrator de test.sh devolve vazio para harness sem régua (não é zero)" || fail "extrator confundiu ausência com número" "vazio" "'$gotNone'"
	[ -z "$gotMissing" ] && pass "extrator de test.sh não explode com log inexistente" "vazio" "'$gotMissing'"
fi

echo "== GATE-LOG: $CHECKS checks, $FAILURES failures =="
exit "$FAILURES"
