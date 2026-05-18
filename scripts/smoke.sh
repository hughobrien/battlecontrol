#!/usr/bin/env bash
# Smoke — build + CI-tier boot tests.
# Usage: bash scripts/smoke.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Build first (includes lint)
bash "$SCRIPT_DIR/build.sh" "$@"

echo ""
echo "=== Smoke ==="

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_gating.sh" "$@"

FAIL=0

run_smoke() {
	local game="$1" platform="$2"
	echo "--- $game-$platform-test ---"
	bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" || FAIL=$((FAIL + 1))
}

if $GATE_RA_NATIVE; then
	run_smoke ra native
else
	echo "SKIP: ra-native-test (no RA changes)"
fi

if $GATE_TD_NATIVE; then
	run_smoke td native
else
	echo "SKIP: td-native-test (no TD changes)"
fi

if $GATE_RA_WASM; then
	run_smoke ra wasm
else
	echo "SKIP: ra-wasm-test (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
	run_smoke td wasm
else
	echo "SKIP: td-wasm-test (no TD/wasm changes)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
	echo "✗ Smoke: $FAIL failure(s)"
	exit 1
fi
echo "✓ Smoke complete"
