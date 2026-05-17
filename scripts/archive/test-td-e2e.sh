#!/usr/bin/env bash
# TIM-465: Build TD WASM, serve bundle + assets, run Playwright e2e tests.
#
# Usage (from repo root):
#   bash scripts/test-td-e2e.sh
#
# With Emscripten via Nix:
#   nix --extra-experimental-features "nix-command flakes" develop \
#       --command bash scripts/test-td-e2e.sh
#
# Prerequisites:
#   - Emscripten toolchain in PATH (or run via Nix as shown above)
#   - TD MIX assets at /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/
#   - Node.js + npx (Playwright)
#
# Servers started:
#   port 8082  — serve-coop.py (WASM bundle with COOP+COEP headers)
#   port 9091  — serve-assets.py (TD MIX file assets with CORS+CORP headers)
#
# The serve-coop.py script is used with a custom port for TD (8080 is for RA).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TD_ASSET_DIR="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
WASM_PORT=8082
ASSET_PORT=9091

cleanup() {
    echo "[test-td-e2e] cleaning up servers..."
    kill "$WASM_PID" 2>/dev/null || true
    kill "$ASSET_PID" 2>/dev/null || true
}
trap cleanup EXIT

cd "$REPO_ROOT"

# ── 1. Build WASM ──────────────────────────────────────────────────────────
if [ ! -f build-wasm/td.html ]; then
    echo "[test-td-e2e] building TD WASM bundle..."
    emcmake cmake --preset wasm
    cmake --build build-wasm --target td -j"$(nproc)"
    echo "[test-td-e2e] TD WASM build complete."
else
    echo "[test-td-e2e] build-wasm/td.html exists, skipping build."
fi

# ── 2. Verify assets ──────────────────────────────────────────────────────
if [ ! -d "$TD_ASSET_DIR" ]; then
    echo "ERROR: TD asset directory not found: $TD_ASSET_DIR" >&2
    exit 1
fi
echo "[test-td-e2e] TD assets found at $TD_ASSET_DIR:"
ls "$TD_ASSET_DIR"

# ── 3. Start WASM server on port 8082 ────────────────────────────────────
echo "[test-td-e2e] starting TD WASM server on port $WASM_PORT..."
python3 wasm/serve-coop.py "$WASM_PORT" &
WASM_PID=$!

# ── 4. Start asset server on port 9091 ───────────────────────────────────
echo "[test-td-e2e] starting TD asset server on port $ASSET_PORT..."
python3 wasm/serve-assets.py "$TD_ASSET_DIR" "$ASSET_PORT" &
ASSET_PID=$!

# Wait for servers to be ready.
sleep 2

# Confirm COOP+COEP headers on WASM server.
echo "[test-td-e2e] checking COOP/COEP headers..."
curl -sI "http://localhost:$WASM_PORT/td.html" | grep -i "cross-origin" || true

# Confirm CORS on asset server.
echo "[test-td-e2e] checking CORS headers on asset server..."
if ls "$TD_ASSET_DIR"/*.MIX 2>/dev/null | head -1 | xargs -I{} basename {} > /dev/null 2>&1; then
    FIRST_MIX="$(ls "$TD_ASSET_DIR"/*.MIX 2>/dev/null | head -1 | xargs basename)"
    curl -sI "http://localhost:$ASSET_PORT/$FIRST_MIX" | grep -i "access-control" || true
fi

# ── 5. Install Playwright (idempotent) ───────────────────────────────────
if [ ! -d node_modules ]; then
    echo "[test-td-e2e] installing npm deps..."
    npm install
fi
echo "[test-td-e2e] installing Playwright Chromium browser..."
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

# ── 6. Start Xvfb virtual display ────────────────────────────────────────
# Tests run headed (headless: false) for WebGL/OffscreenCanvas support.
if ! pgrep -x Xvfb > /dev/null; then
    echo "[test-td-e2e] starting Xvfb on :99..."
    Xvfb :99 -screen 0 1280x1024x24 &
    XVFB_PID=$!
    trap "cleanup; kill $XVFB_PID 2>/dev/null || true" EXIT
    sleep 1
else
    echo "[test-td-e2e] Xvfb already running."
fi

# ── 7. Run TD e2e tests ───────────────────────────────────────────────────
echo "[test-td-e2e] running TD gameplay Playwright tests..."
DISPLAY=:99 npx playwright test e2e/td-gameplay.spec.ts --reporter=list 2>&1 | tee e2e/test-run-td.log

echo "[test-td-e2e] done."
