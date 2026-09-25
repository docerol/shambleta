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
gate() {
	local log="$1" marker="$2" script="$3" timeout="${4:-900}"
	set +e
	env XDG_DATA_HOME="$PROJECT/.test-home/$script/data" \
		XDG_CACHE_HOME="$PROJECT/.test-home/$script/cache" \
		timeout "$timeout" "$GODOT" --headless --path . -s "tests/$script.gd" > "$log" 2>&1
	local code=$?
	set -e
	echo "godot exit=$code" >> "$log"
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code"
}

# As três suítes do companion são a fronteira do dinheiro real (HMAC do webhook,
# idempotência do grant, CLI de reembolso). A CI já roda cada uma, mas o
# `test.sh all` local não — um "beta gate verde" na máquina deixava 138 checks de
# fora. Mesmo quádruplo de §24-8: marcador próprio por suíte, contagem lida do log,
# exit code conferido à parte.
gate_py() {
	local log="$1" marker="$2" script="$3"
	set +e
	timeout 300 python3 "companion/$script.py" > "$log" 2>&1
	local code=$?
	set -e
	echo "python exit=$code" >> "$log"
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code"
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
	set +e
	bash "$script" > "$log" 2>&1
	local code=$?
	set -e
	echo "bash exit=$code" >> "$log"
	bash scripts/ci_gate_log.sh "$log" "$marker" "$code"
}

# Pré-checagem de parse (custa ~1 s, os seis arquivos). Um harness que não
# compila é morte lenta: `run_idle_tests.gd:76` faz `load()` de `IdleTests.gd` e
# chama `.new()` — se o arquivo não parseia, o load devolve um GDScript inválido,
# `.new()` falha, nenhuma suíte roda, a linha `== RESULT:` nunca aparece e o gate
# só descobre isso no timeout de 1200 s. Três execuções do portão foram perdidas
# exatamente assim (um `CheckEq` recebeu String onde a assinatura é `(int, int,
# String)`). A régua é ancorada em `SCRIPT ERROR: Parse Error`: `--check-only`
# também emite `ERROR: …tscn - Parse Error: [ext_resource]` para scripts que
# referenciam autoload (falso positivo do modo, não do código).
preflight_parse() {
	local bad=""
	for script in run_idle_tests IdleTests run_rpc_identity_test test_e2e_implementation test_backup_restore benchmarks; do
		local errs
		errs="$("$GODOT" --headless --path . --check-only --script "tests/$script.gd" 2>&1 |
			grep '^SCRIPT ERROR: Parse Error' || true)"
		[ -n "$errs" ] && bad="$bad$script
$errs
"
	done
	if [ -n "$bad" ]; then
		echo "PREFLIGHT FALHOU: harness não compila, o gate morreria no timeout."
		printf '%s' "$bad"
		exit 1
	fi
	echo "Preflight parse OK: 6 harnesses, zero SCRIPT ERROR: Parse Error."
}

case "${1:-all}" in
  all)
    echo "==> Running all tests..."
    preflight_parse
    gate_sh /tmp/shambleta-godnodes.log "Gate anti-god-node:" scripts/check_god_nodes.sh
    gate /tmp/shambleta-idle.log "== RESULT:" run_idle_tests 1200
    gate /tmp/shambleta-rpc.log "== RPC IDENTITY:" run_rpc_identity_test 180
    gate /tmp/shambleta-e2e.log "== RESULT:" test_e2e_implementation 120
    gate /tmp/shambleta-backup.log "== Backup Restore Probe:" test_backup_restore 120
    gate /tmp/shambleta-bench.log "== Benchmarks:" benchmarks 120
    companion_gates
    ;;
  companion)
    echo "==> Running companion (money frontier)..."
    companion_gates
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
    echo "==> Running structure gates (god-node ceiling)..."
    gate_sh /tmp/shambleta-godnodes.log "Gate anti-god-node:" scripts/check_god_nodes.sh
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
    echo "Usage: $0 {all|quick|idle|backup|benchmarks|rpc|companion|diag|clean}"
    exit 1
    ;;
esac
