#!/usr/bin/env bash
# Regression — build + full regression (all targets, no diff-gating).
# Usage: bash scripts/regression.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Build all ==="
bash "$SCRIPT_DIR/build.sh" --all
echo ""

echo "=== Regression ==="

FAIL=0

run_regression() {
	local game="$1" platform="$2"
	echo "--- $game-$platform-regression ---"
	bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" --full || FAIL=$((FAIL + 1))
}

run_regression ra native
run_regression ra wasm
run_regression td native
run_regression td wasm

echo ""
if [ "$FAIL" -gt 0 ]; then
	echo "✗ Regression: $FAIL failure(s)"
	exit 1
fi
echo "✓ Regression complete"
