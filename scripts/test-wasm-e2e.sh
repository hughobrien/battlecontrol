#!/usr/bin/env bash
# TIM-399: Build WASM, serve bundle + assets, run Playwright e2e tests.
#
# Usage (from repo root):
#   bash scripts/test-wasm-e2e.sh
#
# Prerequisites:
#   - Emscripten toolchain in PATH (or run via: nix develop --command bash scripts/test-wasm-e2e.sh)
#   - RA MIX assets at /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/
#   - Node.js + npx (Playwright)
#
# Servers started:
#   port 8080  — serve-coop.py (WASM bundle with COOP+COEP headers)
#   port 9090  — serve-assets.py (MIX file assets with CORS+CORP headers)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1"
WASM_PORT=8080
ASSET_PORT=9090

cleanup() {
    echo "[test-wasm-e2e] cleaning up servers..."
    kill "$WASM_PID" 2>/dev/null || true
    kill "$ASSET_PID" 2>/dev/null || true
}
trap cleanup EXIT

cd "$REPO_ROOT"

# ── 1. Build WASM ──────────────────────────────────────────────────────────
if [ ! -f build-wasm/ra.html ]; then
    echo "[test-wasm-e2e] building WASM bundle..."
    emcmake cmake --preset wasm
    cmake --build build-wasm --target ra -j"$(nproc)"
    echo "[test-wasm-e2e] build complete."
else
    echo "[test-wasm-e2e] build-wasm/ra.html exists, skipping build."
fi

# ── 2. Verify assets ──────────────────────────────────────────────────────
if [ ! -d "$ASSET_DIR" ]; then
    echo "ERROR: RA asset directory not found: $ASSET_DIR" >&2
    exit 1
fi
echo "[test-wasm-e2e] assets found at $ASSET_DIR:"
ls "$ASSET_DIR"

# ── 3. Start servers ──────────────────────────────────────────────────────
echo "[test-wasm-e2e] starting WASM server on port $WASM_PORT..."
python3 wasm/serve-coop.py "$WASM_PORT" &
WASM_PID=$!

echo "[test-wasm-e2e] starting asset server on port $ASSET_PORT..."
python3 wasm/serve-assets.py "$ASSET_DIR" "$ASSET_PORT" &
ASSET_PID=$!

# Wait for both servers to be ready.
sleep 2

# Confirm COOP+COEP headers on WASM server.
echo "[test-wasm-e2e] checking COOP/COEP headers..."
curl -sI "http://localhost:$WASM_PORT/ra.html" | grep -i "cross-origin" || true

# Confirm CORS on asset server.
echo "[test-wasm-e2e] checking CORS headers on asset server..."
FIRST_MIX="$(ls "$ASSET_DIR"/*.MIX 2>/dev/null | head -1 | xargs basename)"
if [ -n "$FIRST_MIX" ]; then
    curl -sI "http://localhost:$ASSET_PORT/$FIRST_MIX" | grep -i "access-control" || true
fi

# ── 4. Install Playwright (idempotent) ───────────────────────────────────
if [ ! -d node_modules ]; then
    echo "[test-wasm-e2e] installing npm deps..."
    npm install
fi
echo "[test-wasm-e2e] installing Playwright Chromium browser..."
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

# ── 5. Run Playwright tests ───────────────────────────────────────────────
echo "[test-wasm-e2e] running Playwright tests..."
npx playwright test --config e2e/playwright.config.ts --reporter=list 2>&1 | tee e2e/test-run.log

echo "[test-wasm-e2e] done."
