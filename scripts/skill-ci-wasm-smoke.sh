#!/usr/bin/env bash
# Full local WASM CI smoke: configure, build, validate, serve, smoke, cleanup.
# Used by: ci-cd skill §4.
#
# Usage:
#   bash scripts/skill-ci-wasm-smoke.sh
#
# Steps:
#   1. emcmake cmake --preset wasm
#   2. cmake --build build-wasm --target ra --parallel
#   3. cmake --build build-wasm --target td --parallel
#   4. Validate WASM magic + size (>1MB)
#   5. Start dev server + Xvfb
#   6. Run T1 (RA boot) + T2 (TD boot) smoke tests
#   7. Cleanup
#
# Exit code: 0 = all pass, non-zero = first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "=== WASM CI Smoke (local) ==="

# Step 1: Configure
echo ""
echo "--- Step 1: emcmake configure ---"
emcmake cmake --preset wasm

# Step 2: Build RA
echo ""
echo "--- Step 2: Build ra.wasm ---"
cmake --build build-wasm --target ra --parallel

# Step 3: Build TD
echo ""
echo "--- Step 3: Build td.wasm ---"
cmake --build build-wasm --target td --parallel

# Step 4: Validate WASM binaries
echo ""
echo "--- Step 4: Validate WASM binaries ---"
python3 - <<'EOF'
import os, struct
MIN_SIZE = 1_000_000
for name in ('build-wasm/ra.wasm', 'build-wasm/td.wasm'):
    with open(name, 'rb') as f:
        magic = f.read(4)
    assert magic == b'\x00asm', f'{name}: invalid WASM magic {magic!r}'
    size = os.path.getsize(name)
    assert size > MIN_SIZE, f'{name}: suspiciously small ({size} bytes < {MIN_SIZE})'
    print(f'  {name}: {size // 1024} KB — OK')
EOF
echo "  PASS: WASM binaries valid"

# Step 5-6: Start Xvfb + server, run smoke tests
echo ""
echo "--- Step 5-6: Smoke tests ---"

# Start Xvfb
# shellcheck disable=SC1091
source "$SCRIPT_DIR/skill-xvfb-ensure.sh" :99 1280x1024x24

# Start WASM server
# shellcheck disable=SC1091
source "$SCRIPT_DIR/skill-wasm-serve.sh" 8080

# Run T1: RA boot smoke
echo ""
echo "  --- T1: RA WASM boot smoke ---"
DISPLAY="$XVFB_DISPLAY" playwright test e2e/regression/T1-ra-wasm-boot.spec.ts
RA_EXIT=$?
if [[ $RA_EXIT -ne 0 ]]; then
	echo "FAIL: T1 RA boot smoke failed"
	exit $RA_EXIT
fi

# Run T2: TD boot smoke
echo ""
echo "  --- T2: TD WASM boot smoke ---"
DISPLAY="$XVFB_DISPLAY" playwright test e2e/regression/T2-td-wasm-boot.spec.ts
TD_EXIT=$?
if [[ $TD_EXIT -ne 0 ]]; then
	echo "FAIL: T2 TD boot smoke failed"
	exit $TD_EXIT
fi

# Xvfb and server are killed by EXIT traps from sourced scripts

echo ""
echo "=== All WASM CI smoke checks PASS ==="
