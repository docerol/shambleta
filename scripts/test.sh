#!/usr/bin/env bash
set -euo pipefail

PROJECT="/home/thiago/Thiago/Projetos/shambleta"
GODOT="${GODOT:-godot}"

cd "$PROJECT"

case "${1:-all}" in
  all)
    echo "==> Running all tests..."
    "$GODOT" --headless --path . -s tests/run_idle_tests.gd
    "$GODOT" --headless --path . -s tests/test_backup_restore.gd
    "$GODOT" --headless --path . -s tests/benchmarks.gd
    ;;
  quick)
    echo "==> Running quick tests (no real-time sims)..."
    "$GODOT" --headless --path . -s tests/run_idle_tests.gd
    ;;
  idle)
    echo "==> Running idle tests..."
    "$GODOT" --headless --path . -s tests/run_idle_tests.gd
    ;;
  backup)
    echo "==> Running backup restore probe..."
    "$GODOT" --headless --path . -s tests/test_backup_restore.gd
    ;;
  benchmarks)
    echo "==> Running benchmarks..."
    "$GODOT" --headless --path . -s tests/benchmarks.gd
    ;;
  diag)
    echo "==> Running diagnostics..."
    "$GODOT" --headless --path . -s tests/diag_pacing.gd
    ;;
  clean)
    echo "==> Cleaning test artifacts..."
    rm -f testing.db
    rm -rf .local/share/godot/app_userdata/Shambleta/testing*
    ;;
  *)
    echo "Usage: $0 {all|quick|idle|backup|benchmarks|diag|clean}"
    exit 1
    ;;
esac
