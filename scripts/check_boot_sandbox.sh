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

# ------------------------------------------------------- o carimbo de dono do log (M4)

# O `flock` acima responde QUEM TEM DIREITO de escrever; ele não responde quem ESTÁ
# escrevendo, e foi isto que derrubou a passada de 2026-09-30: um `test.sh idle` aberto
# às 23:54 recebeu SIGTERM no shell — o `godot` filho ficou vivo, desanexado, com o fd
# de `/tmp/shambleta-idle.log` e do sandbox `.test-home/run_idle_tests/` abertos por
# mais de 20 minutos. O run das 00:05 acquisition um lock livre, truncou o mesmo
# arquivo e leu como veredito a mistura dos dois: dois blocos de crash com o handler
# incapaz de decodificar a própria pilha e nove `SCRIPT ERROR` nomeando arquivos que
# não existem em lugar nenhum da árvore. `gate()` agora recusa o boot e recusa o
# veredito enquanto houver escritor de fora, e o trap de TERM/INT mata o filho JUNTO.
#
# As três funções abaixo são LIDAS do runner e executadas aqui contra fd reais — não
# contra uma descrição deles. Fixture de papel não prova que um `/proc/<pid>/fd` é
# lido: só um processo vivo com o arquivo aberto prova.
for fn in _log_holders _guard_log_owner _stop_boot; do
	awk "/^$fn\\(\\)/,/^\\}/" "$RUNNER" > "$WORK/$fn.sh" 2>/dev/null
	if ! grep -q "^$fn() {" "$WORK/$fn.sh"; then
		fail "$RUNNER não define mais $fn" "$fn() {" "ausente"
		continue
	fi
	if ( . "$WORK/$fn.sh"; type "$fn" >/dev/null 2>&1 ); then
		pass "$fn existe em $RUNNER e carrega como função chamável"
	else
		fail "$fn extraída não carrega como função" "type $fn" "source falhou"
	fi
done

# O leitor, contra escritores de verdade. `SHAMBLETA_ORPHAN_WAIT=0` é o estado global
# que `_guard_log_owner` lê — o mesmo que o runner define no topo; aqui ele encurta a
# espera para o fixture, e a régua abaixo continua conferindo que o padrão real é
# maior que zero.
call_holders() { ( . "$WORK/_log_holders.sh"; _log_holders "$1" 2>/dev/null ); }
call_guard() {
	( SHAMBLETA_ORPHAN_WAIT=0; . "$WORK/_guard_log_owner.sh"; . "$WORK/_log_holders.sh"; _guard_log_owner "$1" "fixture" 2>/dev/null )
}

M4LOG="$WORK/m4.log"
: > "$M4LOG"
if [ -n "$(call_holders "$M4LOG")" ]; then
	fail "log sem escritor nenhum devolve lista VAZIA" "nenhum pid" "pid onde não há processo"
else
	pass "log sem escritor nenhum devolve lista VAZIA (ausência lida como ausência, não como erro)"
fi

# (a) escritor vivo: `sleep` com stdout apontado para o log abre o fd PARA ESCRITA e o
# segura. Este é exatamente o formato do órfão medido acima.
sleep 120 >> "$M4LOG" &
m4w=$!
holders="$(call_holders "$M4LOG")"
if [ "$holders" = "$m4w" ]; then
	pass "escritor vivo é pelo pid dele ($m4w) — o fd de /proc/<pid>/fd é lido de verdade"
else
	fail "o leitor não achou o escritor vivo" "$m4w" "${holders:-vazio}"
fi
guard_out="$(call_guard "$M4LOG")"; guard_code=$?
if [ "$guard_code" != "0" ] && printf '%s' "$guard_out" | grep -q 'LOG CONCORRENTE' \
	&& printf '%s' "$guard_out" | grep -qF -- "$m4w"; then
	pass "com escritor de fora o veredito é RECUSADO, nomeado o pid ($m4w)"
else
	fail "a guarda deixou passar um log com escritor" "exit!=0 + LOG CONCORRENTE + pid" "exit=$guard_code out=${guard_out:-vazio}"
fi

# (b) o controle do ruído: quem só LÊ o log não envenena veredito. Sem este ramo a
# régua acusaria o `tail` de um operador e o portão viraria motivo para ser ignorado.
sleep 120 < "$M4LOG" &
m4r=$!
if printf '%s\n' "$(call_holders "$M4LOG")" | grep -qw -- "$m4r"; then
	fail "leitor somente-leitura NÃO pode ser acusado como escritor" "só o pid do escritor" "o leitor $m4r apareceu"
else
	pass "leitor somente-leitura não é acusado (o bit de escrita do fdinfo é o que conta)"
fi
kill -TERM -- "$m4r" 2>/dev/null || true
wait "$m4r" 2>/dev/null || true

# (c) morto o escritor, o mesmo log volta a ser legível — sem isso a recusa seria
# forever-e-viraria-pesadelo-de-manutenção.
kill -TERM -- "$m4w" 2>/dev/null || true
wait "$m4w" 2>/dev/null || true
if [ -n "$(call_holders "$M4LOG")" ]; then
	fail "sem escritor o log volta a ser nosso" "lista vazia" "$(call_holders "$M4LOG")"
else
	pass "sem escritor o log volta a ser nosso (recusa não é castigo perpétuo)"
fi
[ "$(call_guard "$M4LOG"; echo $?)" = "0" ] && pass "a guarda devolve 0 no log livre" \
	|| fail "a guarda recusou um log sem escritor" "exit 0" "exit!=0"

# (d) o matador: `_stop_boot` tem de tirar do ar um processo vivo, porque é isto que
# impede o órfão de existir. TERM primeiro; o fixture é um `sleep`, que morre no TERM.
sleep 120 >> "$M4LOG" &
m4k=$!
( . "$WORK/_stop_boot.sh"; _stop_boot "$m4k" ) >/dev/null 2>&1
if kill -0 -- "$m4k" 2>/dev/null; then
	fail "_stop_boot não matou o boot interrompido" "processo $m4k morto" "ainda vivo"
else
	pass "_stop_boot mata o boot interrompido (o órfão não chega a existir)"
fi
wait "$m4k" 2>/dev/null || true

# (e) o anúncio de host sem /proc vai para o stderr com a recusa de ler — não para
# "nenhum escritor", que é a mentira que transformaria o portão em verde automático.
if grep -q 'LOG-WRITERS:' "$WORK/_log_holders.sh" && grep -q '>&2' "$WORK/_log_holders.sh"; then
	pass "host sem /proc declara que a leitura foi IMPOSSÍVEL, no stderr (ausência de leitura não é \"sem escritor\")"
else
	fail "o ramo de /proc ausente não anuncia a impossibilidade de ler" "aviso LOG-WRITERS no stderr" "silêncio ou falso zero"
fi

# (f) o padrão de espera é maior que zero: recusa imediata seria a régua acusando um
# vizinho que sairia em um segundo.
if grep -q 'SHAMBLETA_ORPHAN_WAIT:-120' "$RUNNER"; then
	pass "a espera do órfão tem padrão de 120 s, e é sobrescrevível (SHAMBLETA_ORPHAN_WAIT)"
else
	fail "o runner não declara o padrão da espera de órfão" "SHAMBLETA_ORPHAN_WAIT:-120" "ausente"
fi

# ------------------------------------------------------------- os ligamentos (M4-g/h)

# Função existente e não chamada é a família de defeito desta casa (o gate de teardown
# sem chamador, o revive do `IdlePolicy`). Então o ligamento é medido no CORPO de cada
# gate, por número de linha, na ordem em que tem de acontecer.
m4_gate_body="$(awk '/^gate\(\) \{/,/^\}/' "$RUNNER")"
m4_pre="$(printf '%s\n' "$m4_gate_body" | grep -n '_guard_log_owner "\$log" "\$script antes do boot"' | head -1 | cut -d: -f1)"
m4_post="$(printf '%s\n' "$m4_gate_body" | grep -n '_guard_log_owner "\$log" "\$script depois do boot"' | head -1 | cut -d: -f1)"
m4_verdict="$(printf '%s\n' "$m4_gate_body" | grep -n 'bash scripts/ci_gate_log\.sh' | head -1 | cut -d: -f1)"
m4_bg="$(printf '%s\n' "$m4_gate_body" | grep -n '> "\$log" 2>&1 &' | head -1 | cut -d: -f1)"
m4_wait="$(printf '%s\n' "$m4_gate_body" | grep -n 'wait "\$bootPid"' | head -1 | cut -d: -f1)"
m4_trap="$(printf '%s\n' "$m4_gate_body" | grep -n "trap '_stop_boot" | head -1 | cut -d: -f1)"
m4_untrap="$(printf '%s\n' "$m4_gate_body" | grep -n '^[[:space:]]*trap - TERM INT HUP' | head -1 | cut -d: -f1)"

if [ -n "$m4_pre" ] && [ -n "$reap_line" ] && [ "$m4_pre" -lt "$reap_line" ]; then
	pass "gate() confere o dono do log ANTES de reapar e de truncar ($m4_pre < $reap_line)"
else
	fail "gate() não confere o dono antes de pisar no log" "_guard_log_owner antes de _reap_interrupted_sandbox" "pre=${m4_pre:-ausente} reap=${reap_line:-ausente}"
fi
if [ -n "$m4_post" ] && [ -n "$m4_verdict" ] && [ "$m4_post" -lt "$m4_verdict" ]; then
	pass "gate() confere o dono ANTES de ler o veredito ($m4_post < $m4_verdict)"
else
	fail "gate() lê o veredito sem conferir o dono depois do boot" "guarda antes de ci_gate_log.sh" "post=${m4_post:-ausente} veredito=${m4_verdict:-ausente}"
fi
if [ -n "$m4_bg" ] && [ -n "$m4_wait" ] && [ "$m4_bg" -lt "$m4_wait" ] && [ "$m4_bg" -lt "$m4_trap" ] \
	&& [ "$m4_trap" -lt "$m4_wait" ] && [ "$m4_wait" -lt "$m4_untrap" ]; then
	pass "gate() bota em segundo plano, arma o matador antes do wait e o desarma depois ($m4_bg < $m4_trap < $m4_wait < $m4_untrap)"
else
	fail "gate() não roda o boot em background sob trap de interrupção" "redirect & + trap antes de wait + trap - depois" "bg=${m4_bg:-ausente} trap=${m4_trap:-ausente} wait=${m4_wait:-ausente} untrap=${m4_untrap:-ausente}"
fi

for fn in gate_sh gate_py; do
	body="$(awk "/^$fn\(\) \{/,/^\}/" "$RUNNER")"
	hits="$(printf '%s\n' "$body" | grep -c '_guard_log_owner')"
	if [ "$hits" -ge 1 ]; then
		pass "$fn() também confere o dono do log ($hits chamada(s))"
	else
		fail "$fn() não confere o dono do log" "ao menos um _guard_log_owner" "zero"
	fi
done

# A segunda metade do mesmo defeito: o `--import` regrava `.godot/` inteiro e RODAVA
# fora do lock de boot, então o import de um processo concorrente era capaz de derrubar
# o gate do outro com `== GATES VERMELHOS: import (exit=1) ==`.
ec_body="$(awk '/^ensure_class_cache\(\)/,/^\}/' "$RUNNER")"
ec_lock="$(printf '%s\n' "$ec_body" | grep -n '_acquire boot 8' | head -1 | cut -d: -f1)"
# A âncora é o COMANDO, não a palavra: `--import` aparece primeiro na prosa que explica
# por que ele é destrutivo, e a régua, ancorada na palavra, acusou o comentário de estar
# fora do lock (medido nesta passada: `lock=12 import=9`, um falso). Prosa não é evidência
# de execução — a mesma lição do `check_doc_drift.sh`.
ec_imp="$(printf '%s\n' "$ec_body" | grep -n -- '--editor --import --quit' | head -1 | cut -d: -f1)"
ec_rel="$(printf '%s\n' "$ec_body" | grep -n '_release 8' | head -1 | cut -d: -f1)"
if [ -n "$ec_lock" ] && [ -n "$ec_imp" ] && [ -n "$ec_rel" ] && [ "$ec_lock" -lt "$ec_imp" ] \
	&& [ "$ec_imp" -lt "$ec_rel" ]; then
	pass "ensure_class_cache() amarra o --import no lock de boot ($ec_lock < $ec_imp < $ec_rel)"
else
	fail "ensure_class_cache() roda --import fora do lock de boot" "_acquire boot 8 … --editor --import --quit … _release 8" "lock=${ec_lock:-ausente} import=${ec_imp:-ausente} release=${ec_rel:-ausente}"
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
