#!/usr/bin/env bash
set -euo pipefail

# Raiz do projeto derivada do lugar onde este script está (não do HOME de um
# desenvolvedor específico).
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$PROJECT"

# Mesma régua da CI: exit code sozinho não prova nada (um harness que termina em
# quit(0) sobre um segfault sai 0). Cada harness é gravado em log e passado por
# scripts/ci_gate_log.sh, que exige zero SCRIPT ERROR/Parse Error, linha de
# resultado presente, contagem de falhas lida DA LINHA e exit code conferido à
# parte. `gate <log> <marker> <script>` roda e avalia.
#
# Gate vermelho não aborta a passada: ele é anotado e o veredito sai no resumo do
# case. Um `all` que morre no primeiro gate conta uma falha por execução — e as
# três execuções perdidas desta rodada foram exatamente isso, descobrir o segundo
# problema depois de corrigir o primeiro.
FAILED_GATES=""
record_gate() {
	if [ "$1" != "0" ]; then
		FAILED_GATES="$FAILED_GATES $2"
		echo "GATE VERMELHO: $2"
	fi
}

# Um harness por vez. O log e o sandbox são nomeados por harness
# (`/tmp/shambleta-<script>.log`, `.test-home/<script>/`), então duas execuções do
# MESMO harness — um `all` meu e um harness rodando num agente, dois terminais, a
# CI e um pre-commit — escrevem no mesmo arquivo ao mesmo tempo. O veredito lido do
# log passa a ser a mistura das duas, e mistura pode ser verde falso: uma execução
# imprime `0 failures` e a outra nem terminou. O `flock` serializa por nome;
# harnesses diferentes continuam em paralelo. Onde `flock` não existe no host o
# gate roda igual (não se bloqueia o portão por falta de utilitário).
SHAMBLETA_GATE_WAIT="${SHAMBLETA_GATE_WAIT:-1800}"

_acquire() {
	command -v flock >/dev/null 2>&1 || return 0
	exec 9>"/tmp/shambleta-$1.lock"
	if ! flock -w "$SHAMBLETA_GATE_WAIT" 9; then
		echo "GATE BLOQUEADO: $1 segura o lock há mais de ${SHAMBLETA_GATE_WAIT}s — outra execução do mesmo harness não foi esperada (veredito não pode ser lido de log misturado)"
		exec 9>&-
		return 1
	fi
	return 0
}

_release() {
	command -v flock >/dev/null 2>&1 || return 0
	exec 9>&-
}

# Cache global de `class_name`. Um `class_name X` só resolve como identificador
# global depois que o Godot varre o projeto e regrava
# `.godot/global_script_class_cache.cfg`. Quem cria o arquivo por fora do editor
# (agente, `cp`, `git checkout`, `git pull`) deixa o cache velho, e o sintoma é o
# pior possível: `SCRIPT ERROR: Parse Error: Identifier "StreakService" not
# declared in the current scope` no BOOT de todo harness — não do arquivo novo, de
# todos. O §24-8 lê isso como gate vermelho e nada do que estava certo roda.
# A CI já se protege sozinha (`godot --headless --editor --import --quit` antes de
# cada job); localmente não havia o mesmo passo, e a diferença entre os dois
# caminhos é exatamente o tipo de surpresas que este script existe para acabar.
#
# O disparo é por mtime, não por contagem: um arquivo `.gd` mais novo que o cache
# é a condição exata do defeito, e na máquina quieta o teste sai sem gastar nada.
# Um `.gd` mais novo que o cache, ou cache ausente com `.gd` presente. `head -1`
# fecha o pipe do find de propósito, então o status da pipeline não é confiável:
# quem chama trata vazio como "nada a fazer" e ignora o código.
_stale_class_probe() {
	local cache="$PROJECT/.godot/global_script_class_cache.cfg"
	if [ ! -f "$cache" ]; then
		find sources addons tests -name '*.gd' 2>/dev/null | head -1
		return 0
	fi
	find sources addons tests -name '*.gd' -newer "$cache" 2>/dev/null | head -1
}

ensure_class_cache() {
	local stale
	stale="$(_stale_class_probe)" || true
	[ -z "$stale" ] && return 0
	if ! _acquire class_cache; then
		record_gate 1 class_cache
		return 0
	fi
	# Re-confere sob o lock: quem estava na fila pode ter acabado de importar.
	stale="$(_stale_class_probe)" || true
	if [ -n "$stale" ]; then
		echo "==> cache de class_name velho (ex.: $stale) — rodando --import"
		set +e
		timeout 900 "$GODOT" --headless --editor --import --quit > /tmp/shambleta-import.log 2>&1
		local code=$?
		set -e
		# Import falho NÃO é gate: o portão de verdade é o harness, que vai ler o
		# cache que existe. Anunciar o código é o que impede o silêncio de virar
		# "importou e ficou bom" quando não importou.
		if [ "$code" -ne 0 ]; then
			echo "    (--import saiu com $code; ver /tmp/shambleta-import.log)"
		fi
	fi
	_release class_cache
}

gate() {
	local log="$1" marker="$2" script="$3" timeout="${4:-900}"
	if ! _acquire "$script"; then
		record_gate 1 "$script"
		return 0
	fi
	set +e
	env XDG_DATA_HOME="$PROJECT/.test-home/$script/data" \
		XDG_CACHE_HOME="$PROJECT/.test-home/$script/cache" \
		timeout "$timeout" "$GODOT" --headless --path . -s "tests/$script.gd" > "$log" 2>&1
	local code=$?
	set -e
	echo "godot exit=$code" >> "$log"
	local verdict=0
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code" || verdict=$?
	_release
	record_gate "$verdict" "$script"
}

# As três suítes do companion são a fronteira do dinheiro real (HMAC do webhook,
# idempotência do grant, CLI de reembolso). A CI já roda cada uma, mas o
# `test.sh all` local não — um "beta gate verde" na máquina deixava 138 checks de
# fora. Mesmo quádruplo de §24-8: marcador próprio por suíte, contagem lida do log,
# exit code conferido à parte.
gate_py() {
	local log="$1" marker="$2" script="$3"
	if ! _acquire "$script"; then
		record_gate 1 "$script"
		return 0
	fi
	set +e
	timeout 300 python3 "companion/$script.py" > "$log" 2>&1
	local code=$?
	set -e
	echo "python exit=$code" >> "$log"
	local verdict=0
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code" || verdict=$?
	_release
	record_gate "$verdict" "$script"
}

companion_gates() {
	gate_py /tmp/shambleta-companion.log "== COMPANION:" test_webhook
	gate_py /tmp/shambleta-security.log "== SECURITY:" test_security
	gate_py /tmp/shambleta-refund.log "== REFUND CLI:" test_refund_cli
}

# Gate de estrutura em shell, pelo mesmo quádruplo de §24-8. Existe porque a CI roda
# `scripts/check_god_nodes.sh` num job próprio e o `test.sh all` não: o beta gate
# verde na máquina conviveu com a CI vermelha (Gui.gd 815 linhas contra o teto de
# 800). Um gate que só a CI roda não é gate de lançamento — é surpresa de diff.
gate_sh() {
	local log="$1" marker="$2" script="$3"
	if ! _acquire "$(basename "$script")"; then
		record_gate 1 "$(basename "$script")"
		return 0
	fi
	set +e
	bash "$script" > "$log" 2>&1
	local code=$?
	set -e
	echo "bash exit=$code" >> "$log"
	local verdict=0
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code" || verdict=$?
	_release
	record_gate "$verdict" "$(basename "$script")"
}

# Pré-checagem de parse. Um harness que não compila é morte lenta: `run_idle_tests.gd:76`
# faz `load()` de `IdleTests.gd` e chama `.new()` — se o arquivo não parseia, o
# load devolve um GDScript inválido, `.new()` falha, nenhuma suíte roda, a linha
# de marcador nunca aparece e o gate só descobre isso no timeout de 1200 s. Três
# execuções do portão foram perdidas exatamente assim (um `CheckEq` recebeu String
# onde a assinatura é `(int, int, String)`). A régua é ancorada em
# `SCRIPT ERROR: Parse Error`: `--check-only` também emite
# `ERROR: …tscn - Parse Error: [ext_resource]` para scripts que referenciam
# autoload (falso positivo do modo, não do código).
#
# A régua vale para os seis históricos e para todo harness descoberto: falhar em
# 1 s é melhor que falhar em 1200 s.
#
# Descoberta: os seis acima são chamados por nome em `all` (cada um com timeout
# próprio e marcador já conhecido). Todo o resto é harness de fixação e entra por
# padrão de nome — criar o arquivo compra a execução, sem editar este script nem
# o workflow. O marcador vem do próprio arquivo (a linha que ele imprime), porque
# um gate que regrava o veredito de outro não é gate: `web_delivery_test` apura
# `== WEB DELIVERY:`, `perf_fix_test` apura `== RESULT:`.
EXPLICIT_HARNESSES=" run_idle_tests IdleTests run_rpc_identity_test test_e2e_implementation test_backup_restore benchmarks "

harnesses_extra() {
	local f n
	for f in tests/*_test.gd tests/*_fuzz.gd; do
		[ -e "$f" ] || continue
		n="$(basename "$f" .gd)"
		case "$EXPLICIT_HARNESSES" in
			*" $n "*) continue ;;
		esac
		echo "$n"
	done
}

harness_marker() {
	local m
	m="$(grep -ohE '"== [A-Z]+[A-Z ]*:' "tests/$1.gd" 2>/dev/null | head -1 | tr -d '"')"
	[ -n "$m" ] || m="== RESULT:"
	echo "$m"
}

preflight_parse() {
	local bad="" count=0 script
	for script in $EXPLICIT_HARNESSES $(harnesses_extra); do
		local errs
		errs="$("$GODOT" --headless --path . --check-only --script "tests/$script.gd" 2>&1 |
			grep '^SCRIPT ERROR: Parse Error' || true)"
		count=$((count + 1))
		[ -n "$errs" ] && bad="$bad$script
$errs
"
	done
	if [ -n "$bad" ]; then
		echo "PREFLIGHT FALHOU: harness não compila, o gate morreria no timeout."
		printf '%s' "$bad"
		exit 1
	fi
	echo "Preflight parse OK: $count harnesses, zero SCRIPT ERROR: Parse Error."
}

gates_extra() {
	local script
	for script in $(harnesses_extra); do
		gate "/tmp/shambleta-${script}.log" "$(harness_marker "$script")" "$script" 300
	done
}

# Gates de estrutura: medem o repo sem rodar jogo. Um arquivo que escreveu a
# própria régua e não foi chamado por ninguém é régua sem efeito — foi o destino
# de `gut_runner.gd`, do `check_doc_drift.sh` e do `check_compose.sh` (42 checks
# verdes, zero chamadores). Todos vivem aqui, e `all` e o case `structure`
# chamam ESTA função, para que local e CI não divirjam.
#
# `check_secrets.sh` entrou nesta lista por um motivo que não é de bom tom: o
# `.gitignore` deste repo não tinha nenhuma regra de dotenv e o job `code-health`
# da CI só chamava esta função com três gates — ou seja, um `git add -A` com um
# `.env` contendo a chave do provedor de pagamento (.env.example:19-20) atravessava
# o CI de um repositório que se declara open source. Gate de segredo que não está
# aqui é comentário de README.
structure_gates() {
	gate_sh /tmp/shambleta-godnodes.log "Gate anti-god-node:" scripts/check_god_nodes.sh
	gate_sh /tmp/shambleta-docdrift.log "== DOC DRIFT:" scripts/check_doc_drift.sh
	gate_sh /tmp/shambleta-compose.log "== COMPOSE GATE:" scripts/check_compose.sh
	gate_sh /tmp/shambleta-secrets.log "== SECRETS GATE:" scripts/check_secrets.sh
}

# Qualquer coisa que abra o projeto precisa do cache de `class_name` em dia — o
# `preflight` inclusive, cujo régua é justamente `SCRIPT ERROR: Parse Error` e um
# cache velho produz exatamente essa linha em todo arquivo que referencia uma classe
# nova. `clean` não abre nada, então não paga o import.
if [ "${1:-all}" != "clean" ]; then
	ensure_class_cache
fi

case "${1:-all}" in
  all)
    echo "==> Running all tests..."
    preflight_parse
    structure_gates
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    gate /tmp/shambleta-rpc.log "== RPC IDENTITY:" run_rpc_identity_test 180
    gate /tmp/shambleta-e2e.log "== RESULT:" test_e2e_implementation 120
    gate /tmp/shambleta-backup.log "== Backup Restore Probe:" test_backup_restore 120
    gate /tmp/shambleta-bench.log "== Benchmarks:" benchmarks 120
    gates_extra
    companion_gates
    ;;
  companion)
    echo "==> Running companion (money frontier)..."
    companion_gates
    ;;
  fixation)
    # Mesma descoberta do `all`, para a CI poder chamar sem duplicar a régua:
    # workflow e script local divergindo é exatamente como um gate vira enfeite.
    echo "==> Running discovered fixation gates..."
    gates_extra
    ;;
  preflight)
    # O `all` começa daqui; esta porta existe para a CI chamar a MESMA função em
    # vez de manter uma cópia do laço de parse — foi assim que o preflight da CI
    # ficou olhando para seis arquivos enquanto o gate descobria por nome.
    preflight_parse
    ;;
  quick)
    echo "==> Running quick tests (no real-time sims)..."
    preflight_parse
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    ;;
  idle)
    echo "==> Running idle tests..."
    preflight_parse
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    ;;
  backup)
    echo "==> Running backup restore probe..."
    gate /tmp/shambleta-backup.log "== Backup Restore Probe:" test_backup_restore 120
    ;;
  benchmarks)
    echo "==> Running benchmarks..."
    gate /tmp/shambleta-bench.log "== Benchmarks:" benchmarks 120
    ;;
  rpc)
    echo "==> Running RPC identity transport test..."
    gate /tmp/shambleta-rpc.log "== RPC IDENTITY:" run_rpc_identity_test 180
    ;;
  structure)
    # Três gates de estrutura no mesmo case: teto de tamanho, drift de doc e a
    # atribuição do compose contra as constantes do código. Ver `structure_gates`.
    echo "==> Running structure gates (god-node ceiling + doc drift + compose)..."
    structure_gates
    ;;
  diag)
    echo "==> Running diagnostics..."
    "$GODOT" --headless --path . -s tests/diag_pacing.gd
    ;;
  clean)
    echo "==> Cleaning test artifacts..."
    # Os caminhos reais: `user://` do Godot 4 com config/use_custom_user_dir=true é
    # $HOME/.local/share/Shambleta (o layout godot/app_userdata/ do Godot 3 nunca
    # existiu aqui, então este rm era no-op). O harness de cada case roda com
    # XDG_DATA_HOME apontando para .test-home/<script>/data, limpo no final.
    rm -f testing.db data/db/testing.db*
    rm -rf "$HOME/.local/share/Shambleta/"testing*
    rm -rf .test-home
    ;;
  *)
    echo "Usage: $0 {all|quick|idle|backup|benchmarks|rpc|companion|fixation|preflight|structure|diag|clean}"
    exit 1
    ;;
esac

# Veredito da passada inteira, não do primeiro gate que caiu. O marcador é
# legível de propósito: `GATES VERMELHOS: none` é a linha que um beta gate deve
# imprimir, e a ausência dela não é passagem (§24-8).
if [ -n "$FAILED_GATES" ]; then
	echo "== GATES VERMELHOS:$FAILED_GATES =="
	exit 1
fi
echo "== GATES VERMELHOS: none =="
