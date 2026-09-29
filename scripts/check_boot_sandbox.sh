#!/usr/bin/env bash
# Gate da durabilidade do sandbox — `scripts/test.sh` reapa o que um run interrompido
# deixou para trás, e isto é exercitado aqui sem abrir o projeto.
#
# Por que isto existe (medido 2026-09-28): uma passada completa foi morta no meio de
# `run_idle_tests`. O processo caiu e deixou no sandbox do próprio harness um `testing.db`
# de 3,4 MB com `testing.db-wal` de 16 MB e `testing.db-shm` a meio escrever. A passada
# seguinte abriu por cima: o harness morreu por sinal DUAS vezes — 134 na primeira
# tentativa e 134 na retratada, com os mesmos offsets de engine nas duas, e a retratada
# morreu ANTES de imprimir a linha da primeira suíte, ou seja, mais cedo que a tentativa
# que originou a retratada. O veredito daquele run não era nem verde nem vermelho: era
# uma roleta com histórico, e um juiz lendo aquilo anotaria crash no produto. Régua cujo
# resultado depende do que o run anterior deixou no disco não é régua.
#
# O gatilho é preciso de propósito: presença do sentinela `.booting` no boot significa
# "o último processo deste sandbox não terminou", e só aí `data/` e `cache/` são
# reapados. Apagar sempre custaria a migração completa em cada um dos ~190 boots da
# passada; deixar passar o estado sujo custa o veredito.
#
# Uso:   bash scripts/check_boot_sandbox.sh
# Saída: uma linha por regra ([PASS]/[FAIL]) e, no fim,
#        `== BOOT-SANDBOX: N checks, M failures ==` — o formato que o próprio
#        scripts/ci_gate_log.sh lê. Exit code = nº de falhas.
#
# Nada aqui abre o projeto nem roda Godot: o reaper é extraído de `scripts/test.sh` e
# chamado contra fixtures plantados por este script, então o gate roda em qualquer
# máquina, carregada ou não — inclusive para um juiz.
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

RUNNER=scripts/test.sh

# ------------------------------------------------------------------ o reaper extraído

# Mesma mecânica de `scripts/check_gate_log.sh` com `_noise_declared()`: a função é LIDA
# do runner e executada aqui, de modo que este gate não testa uma cópia — testa a função
# que `gate()` chama. `$PROJECT` é o único estado global de que ela depende, e é definido
# antes do `source` para apontar para o diretório do fixture.
awk '/^_reap_interrupted_sandbox\(\)/,/^}/' "$RUNNER" > "$WORK/reap.sh" 2>/dev/null
if ! grep -q '^_reap_interrupted_sandbox() {' "$WORK/reap.sh"; then
	fail "$RUNNER não define mais o reaper de sandbox" "_reap_interrupted_sandbox() {" "ausente"
	printf '== BOOT-SANDBOX: %d checks, %d failures ==\n' "$CHECKS" "$FAILURES"
	exit "$FAILURES"
fi
pass "o reaper de sandbox existe em $RUNNER e é extraível pela âncora"
if ( PROJECT="$WORK/proj"; export PROJECT; . "$WORK/reap.sh"; type _reap_interrupted_sandbox >/dev/null 2>&1 ); then
	pass "o reaper extraído carrega como função chamável (não é prosa nem comentário)"
else
	fail "o reaper extraído não carrega como função" "type _reap_interrupted_sandbox" "source falhou"
fi

# Sandbox plantado: o runner escreve em `$PROJECT/.test-home/<script>/`, e o que um boot
# interrompido deixa é exatamente isto — banco com WAL e shm a meio escrever, mais cache.
sandbox() {
	local home="$WORK/proj/.test-home/$1"
	mkdir -p "$home/data/Shambleta" "$home/cache"
	echo "pagina-suja" > "$home/data/Shambleta/testing.db"
	echo "wal-suja" > "$home/data/Shambleta/testing.db-wal"
	echo "shm-sujo" > "$home/data/Shambleta/testing.db-shm"
	echo "cache-sujo" > "$home/cache/imported.dat"
}

run_reap() {
	( PROJECT="$WORK/proj"; export PROJECT; . "$WORK/reap.sh"; _reap_interrupted_sandbox "$1" ) 2>&1
}

# Caso 1 — sentinela presente = o último boot deste sandbox não terminou. Estado sujo tem
# de sumir ANTES deste boot, e a casa exige que a limpeza seja dita, não silenciosa: um
# operador que não vê o aviso acha que o run reusou o banco do anterior.
sandbox dirty
touch "$WORK/proj/.test-home/dirty/.booting"
out="$(run_reap dirty)"; code=$?
afere "sentinela presente reapa o sandbox interrompido e avisa" 0 "$code" "$out" "reapado" ""
if [ -e "$WORK/proj/.test-home/dirty/data" ] || [ -e "$WORK/proj/.test-home/dirty/cache" ]; then
	fail "o reap remove mesmo o data/ e o cache/ plantados" "diretórios ausentes" "um deles sobreviveu"
else
	pass "o reap remove mesmo o data/ e o cache/ plantados"
fi

# Caso 2 — o controle que impede o "apaga sempre": sem sentinela o run anterior terminou,
# e o banco/cache existentes são o que torna a passada barata. Intocar é o contrato.
sandbox limpo
out="$(run_reap limpo)"; code=$?
afere "sem sentinela o sandbox do run anterior é intocado" 0 "$code" "$out" "" "reapado"
if [ -f "$WORK/proj/.test-home/limpo/data/Shambleta/testing.db" ]; then
	pass "sem sentinela o testing.db do run anterior continua no lugar"
else
	fail "o reaper apagou um sandbox que não foi interrompido" "arquivo preservado" "apagado"
fi

# Caso 3 — idempotência: sentinela sem `data/` prévio (reap duplo, ou boot morto antes de
# o godot criar o primeiro arquivo) não pode explodir nem reclamar de algo que não há.
mkdir -p "$WORK/proj/.test-home/nada"
touch "$WORK/proj/.test-home/nada/.booting"
out="$(run_reap nada)"; code=$?
afere "sentinela sem data/ prévio não explode e não anuncia limpeza falsa" 0 "$code" "$out" "" "reapado"

# Caso 4 — harness que nunca bootou (diretório inexistente): o reaper é chamado antes de
# qualquer godot, então tem de tolerar o sandbox que ainda não existe.
out="$(run_reap inexistente)"; code=$?
afere "sandbox inexistente (primeiro boot do harness) é tolerado" 0 "$code" "$out" "" "reapado"

# --------------------------------------------------------------------- o ligamento real

# Função que existe e ninguém chama é a família de defeito que a casa já enterrou (o gate
# de teardown sem chamador, o revive do `IdlePolicy` que era código morto). Então o
# ligamento é medido no corpo de `gate()` por NÚMERO DE LINHA, na ordem em que tem de
# acontecer: reapa, marca presença, bota, lê o veredito, e só então despe o sentinela.
# Ordem invertida é um dos dois bugs: reapa depois de marcar presença apaga o sandbox a
# cada boot; presença marcada depois do godot nunca vê uma interrupção.
gate_body="$(awk '/^gate\(\) \{/,/^\}/' "$RUNNER")"
line_of() { printf '%s\n' "$gate_body" | grep -n "$1" | head -1 | cut -d: -f1; }
reap_line="$(line_of '_reap_interrupted_sandbox "\$script"')"
set_line="$(line_of ': > "\$PROJECT/\.test-home/\$script/\.booting"')"
boot_line="$(line_of 'timeout "\$timeout" "\$GODOT"')"
verdict_line="$(line_of 'bash scripts/ci_gate_log\.sh')"
rm_line="$(line_of 'rm -f "\$PROJECT/\.test-home/\$script/\.booting"')"

ordered() {
	local label="$1" a="$2" b="$3" aname="$4" bname="$5"
	if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
		pass "$label (linha $a < $b)"
	else
		fail "$label" "$aname antes de $bname" "$aname=${a:-ausente} $bname=${b:-ausente}"
	fi
}

ordered "gate() reapa o sandbox antes de marcar presença" "$reap_line" "$set_line" "reap" "presença"
ordered "gate() marca presença antes de bootar o godot" "$set_line" "$boot_line" "presença" "boot"
ordered "gate() boota antes de ler o veredito" "$boot_line" "$verdict_line" "boot" "veredito"
ordered "gate() despe a presença só depois do veredito" "$verdict_line" "$rm_line" "veredito" "rm"

# O sentinela só sai do chão com veredito verde, e é nisto que a retratada existe: um
# harness que crashou deixa o sandbox sujo DE PROPÓSITO para que a segunda tentativa abra
# limpo. Despe-lo sem guarda faria a retratada reabrir exatamente o estado que derrubou a
# primeira tentativa — que é o que se mediu acima, com a tentativa 2 morrendo mais cedo.
if [ -n "$rm_line" ]; then
	guard="$(printf '%s\n' "$gate_body" | sed -n "$((rm_line - 2)),$((rm_line - 1))p")"
	if printf '%s' "$guard" | grep -q 'verdict'; then
		pass "o sentinela é despejado sob guarda de veredito (duas linhas acima de $rm_line)"
	else
		fail "o sentinela é despejado sem guardar o veredito" "rm sob um teste de veredito" "duas linhas acima: $guard"
	fi
else
	fail "gate() não despe o sentinela em nenhum lugar" "rm do .booting" "ausente"
fi

# E o ligamento é por harness: dois sandboxes diferentes não podem um matar o outro — é o
# que separa "reapa isto" de "reapa tudo sempre".
if [ -n "$reap_line" ]; then
	pass "o reaper é chamado com o nome do próprio harness, não com um caminho global"
else
	fail "o reaper não é chamado com \$script" "_reap_interrupted_sandbox \"\$script\"" "chamada sem o nome do harness"
fi

# Um gate novo que não está na lista de estrutura é comentário: `all` e CI chamam gates por
# essa lista, e foi assim que esta casa já enterrou um gate de segredo sem porta.
if grep -q 'scripts/check_boot_sandbox.sh' "$RUNNER"; then
	pass "o gate está registrado no runner, não só no disco"
else
	fail "check_boot_sandbox.sh não é chamado por nenhum portão" "uma linha em structure_gates()" "ausente"
fi

printf '== BOOT-SANDBOX: %d checks, %d failures ==\n' "$CHECKS" "$FAILURES"
exit "$FAILURES"
