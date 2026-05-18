#!/usr/bin/env bash
# Build — lint + diff-gated compile.
# Usage: bash scripts/build.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Lint ==="
bash "$SCRIPT_DIR/lint.sh"

echo ""
echo "=== Build ==="

source "$SCRIPT_DIR/_gating.sh" "$@"

build_native() {
  local target="$1"
  echo "--- $target-native-build ---"
  bash scripts/build-native.sh "$target"
}

build_wasm() {
  local target="$1"
  echo "--- $target-wasm-build ---"
  if [ "$target" = "ra" ]; then
    nix run .#ra-wasm-build
  else
    nix run .#td-wasm-build
  fi
}

if $GATE_RA_NATIVE; then
  build_native ra
else
  echo "SKIP: ra-native-build (no RA changes)"
fi

if $GATE_TD_NATIVE; then
  build_native td
else
  echo "SKIP: td-native-build (no TD changes)"
fi

if $GATE_RA_WASM; then
  build_wasm ra
else
  echo "SKIP: ra-wasm-build (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
  build_wasm td
else
  echo "SKIP: td-wasm-build (no TD/wasm changes)"
fi

echo ""
echo "✓ Build complete"
