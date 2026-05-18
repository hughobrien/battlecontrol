#!/usr/bin/env bash
# Test — build + full regression.
# Usage: bash scripts/test.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Build first (includes lint)
bash "$SCRIPT_DIR/build.sh" "$@"

echo ""
echo "=== Test (full regression) ==="

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_gating.sh" "$@"

FAIL=0

run_full() {
  local game="$1" platform="$2"
  echo "--- $game-$platform-test --full ---"
  bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" --full || FAIL=$((FAIL + 1))
}

if $GATE_RA_NATIVE; then
  run_full ra native
else
  echo "SKIP: ra-native-test --full (no RA changes)"
fi

if $GATE_TD_NATIVE; then
  run_full td native
else
  echo "SKIP: td-native-test --full (no TD changes)"
fi

if $GATE_RA_WASM; then
  run_full ra wasm
else
  echo "SKIP: ra-wasm-test --full (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
  run_full td wasm
else
  echo "SKIP: td-wasm-test --full (no TD/wasm changes)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ Test: $FAIL failure(s)"
  exit 1
fi
echo "✓ Test complete"
