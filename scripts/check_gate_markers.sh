#!/usr/bin/env bash
# Gate do contrato de marcador — finding #81.
#
# O defeito medido (duas vezes, por dois juízes independentes, no mesmo sítio):
# `harness_marker()` em scripts/test.sh casava só `"== [A-Z]+[A-Z ]*:` e, não
# achando, cobrava o literal `== RESULT:`. `bash scripts/test.sh one benchmarks`
# devolvia GATE VERMELHO com `godot exit=0` e `== Benchmarks: 0 failures ==` no log
# — o portão afirmava o oposto da fonte porque a regex era cega a marcador
# mixed-case. Idem `one test_backup_restore` (`== Backup Restore Probe:`). E
# `reason_toast_test.gd` passava por acidente textual: a regex achava o
# `== RESULT:` de `_finish` (linha 57) antes do `== REASON:` de `_initialize`
# (linha 61); mover `_finish` para o fim do arquivo troca o marcador cobrado. Um
# veredito que depende da ordem das linhas não é veredito.
#
# Esta régua fecha a classe, genérica e não por arquivo:
#   R1  o marcador cobrado de cada harness É o marcador do harness — a declaração
#       `# gate-marker: <M>` lida das primeiras linhas vence, e uma declaração que
#       não é a última linha de resultado do arquivo é gate vermelho.
#   R2  todo marcador LITERAL escrito numa chamada `gate`/`gate_sh`/`gate_py` de
#       scripts/test.sh é o veredito daquele alvo (é o que impede um portão de
#       regravar o veredito de outro — a mentira que sobreviveu duas rodadas).
#   R3  os casos anunciados na interface de scripts/test.sh existem no `case`, e
#       todo rótulo do `case` está anunciado. #81: a ajuda prometia um caso `gate`
#       que é função interna; quem por aquela porta entrou rodou check_*.sh na mão
#       e o verde dele não era o verde do portão.
#   R4  o veredito do arquivo é uma linha que scripts/ci_gate_log.sh sabe parsear
#       (a contagem de falhas é lida DA LINHA; linha não reconhecida = sem verde).
#   R5  o contrato continua documentado em scripts/test.sh (sem o contrato escrito,
#       R1 é comportamento secreto de um script).
#   R6  canário: cada regra come um defeito sintético plantado e poupa o equivalente
#       limpo, na mesma passada. Zero falha sem canário vivo é a frase "regex
#       quebrada também acha zero" que scripts/check_secrets.sh:317 registra.
#
# Uso:   bash scripts/check_gate_markers.sh
# Saída: uma linha por regra ([PASS]/[FAIL]) e, no fim,
#        `== GATE-MARKER: N checks, M failures ==` — formato que
#        scripts/ci_gate_log.sh:42 lê. Exit code = nº de falhas.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

TESTSH="scripts/test.sh"
DEFAULT_MARKER="== RESULT:"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[ -r "$TESTSH" ] || { fail "$TESTSH ilegível" "arquivo presente" "ausente"; echo "== GATE-MARKER: 1 checks, 1 failures =="; exit 1; }

# A derivadora do portão, extraída do próprio scripts/test.sh e executada aqui.
# Copiar a função seria a divergência clássica (régua local x régua da CI): o que
# esta gate confere é o código que cobra o veredito no run real.
eval "$(awk '/^harness_marker\(\)/,/^}/' "$TESTSH")"
if [ "$(type -t harness_marker)" != "function" ]; then
	fail "scripts/test.sh não define harness_marker() (a régua ficou cega)" "a função existe e é extrainível" "extração vazia"
	echo "== GATE-MARKER: $CHECKS checks, $FAILURES failures =="
	exit "${FAILURES}"
fi

# ------------------------------------------------------------------ derivadores
# `last_result_line <arquivo>` — a ÚLTIMA string impressa que carrega contagem de
# falhas. Caixa não importa; a primeira aparição não elege. É o mesmo formato que
# ci_gate_log.sh lê, e é por isso que "linha de resultado" exige a palavra failures:
# banner (`== REASON: toast do jogador …`) não é veredito e não concorre.
# Literal de string nos dois estilos de aspa: gdscript escreve `print("…")`, shell
# escreve `printf '…\n'` (é o caso de scripts/check_boot_sandbox.sh) — ignorar aspa
# simples seria cegar metade dos vereditos do portão.
quoted_literals() { grep -oE "(\"[^\"]{0,300}\")|('[^']{0,300}')" "$1" 2>/dev/null || true; }
# Candidato a LINHA DE RESULTADO, não a qualquer prosa que fale de falha: a string
# precisa (i) de um marcador delimitedo pelo primeiro dois-pontos e (ii) de uma
# CONTAGEM colada na palavra failures — `%d failures`, `$failures`, `0 failures`.
# Sem (ii) o portão leria prosa (`"…falha…"`, `"37 checks, 0 failures"` solto, ou o
# fixture `"== RESULT: 12 checks, 0 failures =="` que um gate escreve num log
# temporário) como veredito — e régua que escolhe por forma errada é a #81 de novo.
# As duas aspas vivas (dupla e simples) são montadas por printf, não escritas dentro
# de um padrão já entre aspas: `grep -E "^["'']…"` é sintaticamente válida em bash e
# devolve um padrão MUDO — foi assim que esta régua ficou aprovando "nenhum candidato"
# em 60 harnesses. Uma régua que não acha nada também acha zero.
QD="$(printf '\042')"
QA="$(printf '\047')"
result_lines() {
	quoted_literals "$1" | grep -E "^[$QD$QA][^$QD$QA]{1,90}:" \
		| grep -E '(%[-0-9.]*[diu]|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$\([^(]*\)|\$[A-Za-z_][A-Za-z0-9_]*|[0-9]+)[[:space:]]+failures'
}
last_result_line() { result_lines "$1" | tail -n 1; }
result_marker_of_line() {
	printf '%s\n' "${1:-}" | sed -nE "s/^[$QD$QA]([^:$QD$QA]{1,90}):.*/\1:/p" | sed -E 's/[[:space:]]+$//'
}
# `result_markers_all <arquivo>` — todos os marcadores de resultado do arquivo.
result_markers_all() {
	while IFS= read -r l; do
		result_marker_of_line "$l"
	done < <(result_lines "$1") | grep -E . | sort -u
}
last_result_marker() { result_marker_of_line "$(last_result_line "$1")"; }
# A declaração é contrato, e contrato mora no topo: mesmo teto de 40 linhas do
# portão. Marcador no meio do arquivo é texto de teste, não declaração.
declared_marker() {
	{ head -n 40 "$1" 2>/dev/null || true; } \
		| sed -nE 's/^[[:space:]]*#[[:space:]]*gate-marker:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -n 1
}
# Suíte do companion: o veredito é `sys.exit(report("PUSH COMMON"))` — o marcador
# é o nome passado a `report()`, não uma literal com "failures".
companion_marker() {
	local l
	l="$(grep -oE 'report\("[^"]+"\)' "$1" 2>/dev/null | tail -n 1 | sed -nE 's/report\("([^"]+)"\)/== \1:/p')"
	[ -n "$l" ] || l="$(last_result_marker "$1")"
	printf '%s' "$l"
}
# Renderiza a linha de resultado do FONTE para o formato que cai no log: `%d`
# (gdscript), `$var` / `${var}` / `$((…))` (shell). A régua então roda o sed de
# ci_gate_log.sh sobre ela — é a mesma leitura, não uma reimplementação dela.
render_result_line() {
	printf '%s' "${1:-}" \
		| sed -E 's/^"//; s/"$//' \
		| sed -E 's/%[-0-9.]*[diufs]/1/g' \
		| sed -E 's/\$\(\([^)]*\)\)/1/g; s/\$\{[A-Za-z_][A-Za-z0-9_]*\}/1/g; s/\$[A-Za-z_][A-Za-z0-9_]*/1/g' \
		| sed -E 's/[[:space:]]+/ /g'
}

# ------------------------------------------------------------------ corpo das regras
# Vereditões puros (usados pelo laço real e pelo canário R6 — uma régua só).
verdict_r1() { # <nome> <declarado> <cobrado> <ultimo> <n_candidatos> <candidatos-linha>
	local nome="$1" dec="$2" charged="$3" last="$4" ncand="$5" cands="$6"
	if [ -n "$dec" ]; then
		if [ "$charged" != "$dec" ]; then
			printf '%s: o portão cobra "%s", mas o arquivo declara "%s" — a declaração está sendo ignorada\n' "$nome" "$charged" "$dec"; return 1
		fi
		if ! printf '%s\n' "$cands" | grep -qxF "$dec"; then
			printf '%s: declarado "%s", mas nenhuma linha de resultado do arquivo imprime esse marcador (candidatos: %s)\n' "$nome" "$dec" "$(printf '%s ' $cands)"; return 1
		fi
		if [ "$ncand" -gt 1 ] && [ "$dec" != "$last" ]; then
			printf '%s: declarado "%s", mas com %s linhas de resultado no arquivo a última é "%s" — o veredito cobrado tem de ser o último\n' "$nome" "$dec" "$ncand" "$last"; return 1
		fi
		return 0
	fi
	if [ "$ncand" = "0" ]; then
		if [ "$charged" = "$DEFAULT_MARKER" ]; then
			printf '%s: o arquivo não imprime nenhuma linha de resultado e o portão cobra o default "%s" — nada no log vai validar este veredito\n' "$nome" "$DEFAULT_MARKER"; return 1
		fi
		printf '%s: nenhuma linha de resultado no arquivo, mas o portão cobra "%s"\n' "$nome" "$charged"; return 1
	fi
	if [ "$ncand" != "1" ]; then
		printf '%s: %s linhas de resultado candidatas e nenhuma declaração — o marcador não pode ser adivinhado (escreva a linha de declaração no topo)\n' "$nome" "$ncand"; return 1
	fi
	if [ "$charged" != "$last" ]; then
		printf '%s: cobra "%s", o veredito do arquivo é "%s"\n' "$nome" "$charged" "$last"; return 1
	fi
	return 0
}
verdict_r2() { # <literal> <alvo> <candidatos-linha>
	local mk="$1" alvo="$2" cands="$3"
	if printf '%s\n' "$cands" | grep -qxF "$mk"; then
		return 0
	fi
	printf '%s: o portão cobra o literal "%s", que não é linha de resultado do alvo (candidatos: %s)\n' "$alvo" "$mk" "$(printf '%s ' $cands)"; return 1
}
verdict_r3() { # <anunciados-csv> <rotulos-csv>
	local a b bad="" miss=""
	IFS=',' read -ra A <<< "$1"
	IFS=',' read -ra B <<< "$2"
	for a in "${A[@]}"; do
		[ -n "$a" ] || continue
		b=0
		for x in "${B[@]}"; do [ "$x" = "$a" ] && b=1; done
		[ "$b" = 1 ] || bad="$bad $a"
	done
	for b in "${B[@]}"; do
		[ -n "$b" ] || continue
		a=0
		for x in "${A[@]}"; do [ "$x" = "$b" ] && a=1; done
		[ "$a" = 1 ] || miss="$miss $b"
	done
	[ -z "$bad" ] || { printf 'caso anunciado e inexistente no `case`:%s\n' "$bad"; return 1; }
	[ -z "$miss" ] || { printf 'rótulo de `case` não anunciado na ajuda:%s\n' "$miss"; return 1; }
	return 0
}
verdict_r4() { # <nome> <linha-renderizada> <marcador-cobrado>
	local rendered="$2" marker="$3" fails
	case "$rendered" in
	"$marker"*) ;;
	*) printf '%s: a linha de resultado renderizada não começa do marcador cobrado "%s" (%s)\n' "$1" "$marker" "$rendered"; return 1 ;;
	esac
	fails="$(printf '%s\n' "$rendered" | sed -nE 's/.*[^0-9]([0-9]+) failures?.*/\1/p')"
	if [ -z "$fails" ]; then
		printf '%s: ci_gate_log não leria a contagem desta linha: %s\n' "$1" "$rendered"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------ conjunto cobrado
# Harnesses cobrados = nomeados num `gate` de test.sh + descobertos por nome (mesma
# regra de harnesses_extra). IdleTests/IdleTestsFrontier são a FONTE das suítes
# (carregadas por run_idle_tests.gd, sem veredito próprio) e ficam fora com motivo.
SUITE_SOURCES=" IdleTests IdleTestsFrontier "
HARNESSES="$(
	{ sed -nE 's/^[[:space:]]*gate[[:space:]]+[^[:space:]]+[[:space:]]+"[^"]*"[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+[0-9]+[[:space:]]*$/\1/p' "$TESTSH"
	  ls tests/*_test.gd tests/*_fuzz.gd 2>/dev/null | sed 's|.*/||; s|\.gd$||'; } | sort -u
)"
CHARGED=""
for n in $HARNESSES; do
	case "$SUITE_SOURCES" in *" $n "*) continue ;; esac
	[ -f "tests/$n.gd" ] || continue
	CHARGED="$CHARGED $n"
done
[ -n "$CHARGED" ] || fail "nenhum harness cobrado pelo portão" "lista não-vazia" "extração regrediu — esta régua está olhando para nada"

# ------------------------------------------------------------------ R1
r1_bad=""
r1_declared=0
r1_count=0
for n in $CHARGED; do
	f="tests/$n.gd"
	r1_count=$((r1_count + 1))
	dec="$(declared_marker "$f")"
	charged="$(harness_marker "$n")"
	last="$(last_result_marker "$f")"
	cands="$(result_markers_all "$f")"
	ncand="$(printf '%s\n' "$cands" | grep -c . || true)"
	[ -n "$dec" ] && r1_declared=$((r1_declared + 1))
	msg="$(verdict_r1 "$n" "$dec" "$charged" "$last" "$ncand" "$cands")" || r1_bad="$r1_bad
      $msg"
done
if [ -z "$r1_bad" ]; then
	pass "R1: o marcador cobrado de cada harness é o marcador do próprio harness ($r1_count harnesses, $r1_declared com '# gate-marker:')"
	[ "$r1_declared" -gt 0 ] || fail "R1: nenhum harness declara `# gate-marker:`" "ao menos o controle plantado tests/gate_marker_control_test.gd" "zero — o campo lido pode estar morto e este verde seria mudo"
else
	fail "R1: marcador cobrado != veredito do arquivo" "cada harness declara ou imprime exatamente um veredito, e o portão cobra esse" "$r1_bad"
fi

# ------------------------------------------------------------------ R2
r2_bad=""
r2_n=0
while IFS='|' read -r fn mk tgt; do
	[ -n "${fn:-}" ] || continue
	case "$fn" in
	gate_sh) target="$tgt"; cands="$(result_markers_all "$target")" ;;
	gate_py) target="companion/${tgt}.py"; cands="$(companion_marker "$target")" ;;
	*) target="tests/${tgt}.gd"; cands="$(result_markers_all "$target")" ;;
	esac
	[ -f "$target" ] || continue
	r2_n=$((r2_n + 1))
	msg="$(verdict_r2 "$mk" "$fn/$tgt" "$cands")" || r2_bad="$r2_bad
      $msg"
done <<EOF
$(sed -nE 's/^[[:space:]]*(gate|gate_sh|gate_py)[[:space:]]+[^[:space:]]+[[:space:]]+"([^"$]{2,60})"[[:space:]]+([A-Za-z0-9_./-]+).*/\1|\2|\3/p' "$TESTSH")
EOF
if [ -z "$r2_bad" ]; then
	pass "R2: os $r2_n marcadores literais do portão são o veredito do próprio alvo (gate/gate_sh/gate_py)"
else
	fail "R2: gate cobra marcador que o alvo não imprime (portão regrava veredito de outro)" "literal == veredito do alvo" "$r2_bad"
fi

# ------------------------------------------------------------------ R3
CASE_LABELS="$(sed -nE 's/^[[:space:]]{0,4}([a-z][a-z0-9_-]*)\)[[:space:]]*$/\1/p' "$TESTSH" | grep -vE '^\*$' | sort -u | paste -sd, -)"
# Sequência `a|b|c` de ao menos dois tubos: é a forma da ajuda e do cabeçalho. Não
# ler só a linha "Usage:" — o cabeçalho também anuncia portas, e foi ele que mentiu.
ADVERTISED="$(grep -oE '[a-z][a-z0-9_-]*(\|[a-z0-9_-]+){2,}' "$TESTSH" | tr '|' '\n' | sort -u | paste -sd, -)"
if [ -z "$CASE_LABELS" ]; then
	fail "R3: nenhum rótulo de 'case' lido de $TESTSH" "a lista real de casos" "extração regrediu"
elif [ -z "$ADVERTISED" ]; then
	fail "R3: nenhum caso anunciado em $TESTSH" "a ajuda nomear os casos" "extração regrediu — ninguém veria um caso anunciado errado"
else
	msg="$(verdict_r3 "$ADVERTISED" "$CASE_LABELS")"
	if [ $? -eq 0 ] && [ -z "$msg" ]; then
		pass "R3: casos anunciados ($ADVERTISED) == rótulos do 'case' — nem porta falsa nem caso oculto"
	else
		fail "R3: interface de $TESTSH não bate com o 'case'" "anunciado existe, e todo caso está anunciado" "$msg"
	fi
fi

# ------------------------------------------------------------------ R4
r4_bad=""
r4_n=0
for n in $CHARGED; do
	f="tests/$n.gd"
	line="$(last_result_line "$f")"
	[ -n "$line" ] || continue
	r4_n=$((r4_n + 1))
	rendered="$(render_result_line "$line")"
	msg="$(verdict_r4 "$n" "$rendered" "$(harness_marker "$n")")" || r4_bad="$r4_bad
      $msg"
done
if [ -z "$r4_bad" ]; then
	pass "R4: as $r4_n linhas de resultado renderizadas têm contagem legível por scripts/ci_gate_log.sh:42"
else
	fail "R4: linha de resultado que o leitor de veredito não sabe parsear" "\"<marcador>: N checks, M failures ==\"" "$r4_bad"
fi

# ------------------------------------------------------------------ R5
missing_r5=""
for needle in '# gate-marker:' '== RESULT:' 'harness_marker()'; do
	grep -qF "$needle" "$TESTSH" || missing_r5="$missing_r5 [$needle]"
done
if [ -z "$missing_r5" ]; then
	pass "R5: o contrato do marcador está escrito em $TESTSH (declaração, default e função de derivação)"
else
	fail "R5: $TESTSH perdeu a documentação do contrato$missing_r5" "contrato legível junto da função que o aplica" "ausente"
fi

# ------------------------------------------------------------------ R6 canário
# Cada regra come um defeito plantado e poupa o equivalente limpo. O canário de R1
# é o único que exerce a DERIVAÇÃO REAL (harness_marker, extraída de test.sh) num
# arquivo sintético: é o que prova que o campo `# gate-marker:` é lido, e não só
# anunciado. Os três diretórios `old`/`new`/`amb` são escritos só no disco temporário
# desta passada — nada aqui toca `tests/`.
mkdir -p "$WORK/tests"
cat > "$WORK/tests/probe_ok.gd" <<'EOF'
extends SceneTree
# gate-marker: == Canary Probe:
func _initialize() -> void:
	print("== Canary Banner: sem contagem, não concorre ==")
	print("== Canary Probe: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
EOF
cat > "$WORK/tests/probe_oldregex.gd" <<'EOF'
extends SceneTree
func _initialize() -> void:
	print("== Canary Probe: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
EOF
# A regex DO defeito #81, escrita aqui para o canário poder nomear o que morreu:
old_regex_marker() {
	local m
	m="$(grep -ohE '"== [A-Z]+[A-Z ]*:' "$1" 2>/dev/null | head -1 | tr -d '"')"
	[ -n "$m" ] || m="$DEFAULT_MARKER"
	echo "$m"
}
old_mixed='extends SceneTree
func _initialize() -> void:
	print("== Mixed Case: %d checks, %d failures ==" % [checks, failures])
	quit(failures)'
printf '%s\n' "$old_mixed" > "$WORK/tests/probe_mixed.gd"
old_wrong="$(cd "$WORK" && old_regex_marker tests/probe_mixed.gd)"
new_right="$(cd "$WORK" && harness_marker probe_mixed)"
if [ "$old_wrong" = "$DEFAULT_MARKER" ] && [ "$new_right" = "== Mixed Case:" ]; then
	pass "R6/canário: a regex antiga cobrava \"$DEFAULT_MARKER\" num veredito mixed-case e a nova cobra \"== Mixed Case:\" — a classe #81 está fechada, não contornada"
else
	fail "R6/canário mixed-case (antigo=$old_wrong, novo=$new_right)" "antigo=default, novo=o marcador real" "o canário não distingue as duas derivativas — régua morta"
fi

dec_ok="$(declared_marker "$WORK/tests/probe_ok.gd")"
charged_ok="$(cd "$WORK" && harness_marker probe_ok)"
last_ok="$(last_result_marker "$WORK/tests/probe_ok.gd")"
if [ "$dec_ok" = "== Canary Probe:" ] && [ "$charged_ok" = "$dec_ok" ] && [ "$last_ok" = "$dec_ok" ] \
	&& verdict_r1 "probe_ok" "$dec_ok" "$charged_ok" "$last_ok" 1 "$(result_markers_all "$WORK/tests/probe_ok.gd")"; then
	pass "R6/canário: declaração lida, cobrada e conferida contra a última linha de resultado (verde sintético)"
else
	fail "R6/canário: declaração '# gate-marker:' não é lida pelo portão (declarado=\"$dec_ok\" cobrado=\"$charged_ok\" último=\"$last_ok\")" "cobrado == declarado == último" "R1 não consegue aprovar nem o caso limpo — a régua está quebrada"
fi

cands_two="$(printf '%s\n%s' "== First Verdict:" "== Second Verdict:")"
if verdict_r1 "probe_ruim" "== First Verdict:" "== First Verdict:" "== Second Verdict:" 2 "$cands_two" >/dev/null; then
	fail "R6/canário: declaração mentirosa aprovada (declarado é candidato, mas não é o último veredito)" "R1 reprovar declarado != último veredito" "verde falso — a régua não morde"
else
	pass "R6/canário: declaração que não é a última linha de resultado é REPROVADA (o controle plantado que fecha #81)"
fi
if verdict_r1 "probe_fora" "== Não Imprimido:" "== Não Imprimido:" "== Canary Probe:" 1 "$(result_markers_all "$WORK/tests/probe_ok.gd")" >/dev/null; then
	fail "R6/canário: declaração de marcador que o arquivo não imprime foi aprovada" "R1 reprovar" "verde falso"
else
	pass "R6/canário: declaração que nomeia um marcador inexistente no arquivo é REPROVADA"
fi
cat > "$WORK/tests/probe_amb.gd" <<'EOF'
extends SceneTree
func _initialize() -> void:
	print("== First Verdict: %d checks, %d failures ==" % [checks, failures])
	print("== Second Verdict: %d checks, %d failures ==" % [checks, failures])
	quit(failures)
EOF
amb_cand="$(result_markers_all "$WORK/tests/probe_amb.gd" | grep -c . || true)"
if verdict_r1 "probe_amb" "" "$(cd "$WORK" && harness_marker probe_amb)" "$(last_result_marker "$WORK/tests/probe_amb.gd")" "$amb_cand" "$(result_markers_all "$WORK/tests/probe_amb.gd")" >/dev/null; then
	fail "R6/canário: dois vereditos sem declaração aprovados" "R1 exigir '# gate-marker:'" "verde falso por adivinhação"
else
	pass "R6/canário: dois vereditos candidatos ($amb_cand) sem declaração são REPROVADOS (marcador não se adivinha)"
fi
x_cands="$(printf '%s\n' "== X:")"
if verdict_r2 "== X:" alvo "$x_cands" >/dev/null && ! verdict_r2 "== Y:" alvo "$x_cands" >/dev/null; then
	pass "R6/canário: R2 aprova literal igual ao alvo e reprova literal divergente"
else
	fail "R6/canário: verdict_r2 não discrimina" "aprove igual, reprove divergente" "régua morta"
fi
if verdict_r3 "one,all" "all,one" >/dev/null && ! verdict_r3 "one,all,gate" "all,one" >/dev/null; then
	pass "R6/canário: R3 aprova anúncio==case e reprova o caso fantasma ('gate' da #81)"
else
	fail "R6/canário: verdict_r3 não discrimina" "aprove igual, reprove anunciado-inexistente" "régua morta"
fi
rendered_ok="$(render_result_line '"== RESULT: %d checks, %d failures ==" % [checks, failures]')"
rendered_bad="$(render_result_line '"== RESULT: sem contagem alguma"')"
if verdict_r4 "c" "$rendered_ok" "== RESULT:" >/dev/null && ! verdict_r4 "c" "$rendered_bad" "== RESULT:" >/dev/null; then
	pass "R6/canário: R4 lê a contagem da linha renderizada e reprova linha sem contagem"
else
	fail "R6/canário: verdict_r4 não discrimina" "aprove \"N failures\", reprove sem contagem" "régua morta"
fi

echo "== GATE-MARKER: $CHECKS checks, $FAILURES failures =="
exit "$FAILURES"
