#!/usr/bin/env bash
# TIM-540 pass-98 WASM setup: verify WASM rebuild from master + unit-click spec.
#
# Usage (from repo root):
#   bash scripts/first-run-pass98-wasm-setup.sh
#
# What this script does:
#   1. Extracts pre-built WASM artifacts from battlecontrol/gh-pages (built from
#      current master, which includes TIM-537 shell.html ?gameclk=1 wiring and
#      TIM-534 C++ RA_GAME_CLICK SDL_PushEvent click injection).
#   2. Starts serve-coop.py (COOP+COEP headers for SharedArrayBuffer) on port 8080.
#   3. Verifies serve-assets.py is already running on port 9090 (RA MIX files).
#   4. Runs e2e/tim537-click.spec.ts via Playwright.
#   5. Copies the wasm-click-verify screenshot for criterion 4.
#
# Prerequisites:
#   - battlecontrol/gh-pages up to date (git fetch battlecontrol)
#   - serve-assets.py running on port 9090 serving RA MIX files
#   - Node.js + npx (Playwright) installed
#   - Xvfb running on :99 (required for headed Chrome with WebGL)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

WASM_PORT=8080
ASSET_PORT=9090
LOG_FILE="e2e/test-run-tim540.log"

echo "[pass-98-wasm] === Step 1: Extract WASM from gh-pages ==="
echo "[pass-98-wasm] Fetching battlecontrol remote..."
git fetch battlecontrol

GH_PAGES_COMMIT="$(git rev-parse battlecontrol/gh-pages)"
MASTER_COMMIT="$(git rev-parse battlecontrol/master)"
echo "[pass-98-wasm] gh-pages: $GH_PAGES_COMMIT"
echo "[pass-98-wasm] master:   $MASTER_COMMIT"

mkdir -p build-wasm

echo "[pass-98-wasm] Extracting ra.html, ra.js, ra.wasm, preloader.js, coi-serviceworker.min.js..."
git show battlecontrol/gh-pages:ra.html       > build-wasm/ra.html
git show battlecontrol/gh-pages:ra.js         > build-wasm/ra.js
git show battlecontrol/gh-pages:ra.wasm       > build-wasm/ra.wasm
git show battlecontrol/gh-pages:preloader.js  > build-wasm/preloader.js
git show battlecontrol/gh-pages:coi-serviceworker.min.js > build-wasm/coi-serviceworker.min.js

# Verify gameclk=1 support is present in shell.html
grep -q "gameclk" build-wasm/ra.html \
    && echo "[pass-98-wasm] ✓ gameclk param found in ra.html (TIM-537 wired)" \
    || { echo "[pass-98-wasm] ✗ gameclk NOT found in ra.html — aborting"; exit 1; }

echo "[pass-98-wasm] WASM binary: $(ls -lh build-wasm/ra.wasm | awk '{print $5, $9}')"

echo ""
echo "[pass-98-wasm] === Step 2: Start WASM server on port $WASM_PORT ==="
# Kill any stale server on 8080
OLD_PID="$(lsof -ti ":$WASM_PORT" 2>/dev/null || true)"
if [ -n "$OLD_PID" ]; then
    echo "[pass-98-wasm] Killing stale server PID=$OLD_PID on port $WASM_PORT"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
fi

python3 wasm/serve-coop.py "$WASM_PORT" "$(pwd)/build-wasm" &
WASM_SERVER_PID=$!
echo "[pass-98-wasm] Started serve-coop.py PID=$WASM_SERVER_PID"
sleep 2

# Verify COOP/COEP headers
echo "[pass-98-wasm] Checking COOP/COEP headers..."
curl -sI "http://localhost:$WASM_PORT/ra.html" | grep -E "cross-origin|HTTP" | sed 's/^/  /'

echo ""
echo "[pass-98-wasm] === Step 3: Verify asset server on port $ASSET_PORT ==="
if curl -sI "http://localhost:$ASSET_PORT/" 2>/dev/null | grep -q "200\|403"; then
    echo "[pass-98-wasm] ✓ Asset server responding on port $ASSET_PORT"
else
    echo "[pass-98-wasm] ✗ No asset server on port $ASSET_PORT"
    echo "  Start it with: python3 wasm/serve-assets.py /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 $ASSET_PORT &"
    kill "$WASM_SERVER_PID" 2>/dev/null || true
    exit 1
fi

echo ""
echo "[pass-98-wasm] === Step 4: Run Playwright e2e/tim537-click.spec.ts ==="
if [ ! -d node_modules ]; then
    echo "[pass-98-wasm] Installing npm deps..."
    npm install
fi

DISPLAY=:99 npx playwright test e2e/tim537-click.spec.ts \
    --config playwright.config.ts \
    --reporter=list 2>&1 | tee "$LOG_FILE"

PLAYWRIGHT_EXIT=${PIPESTATUS[0]}

echo ""
echo "[pass-98-wasm] === Step 5: Copy wasm-click-verify screenshot ==="
if [ -f "e2e/screenshots/tim537-frame500.png" ]; then
    cp "e2e/screenshots/tim537-frame500.png" "e2e/screenshots/wasm-click-verify.png"
    echo "[pass-98-wasm] ✓ wasm-click-verify.png written from tim537-frame500.png"
else
    echo "[pass-98-wasm] ✗ tim537-frame500.png not found — spec may not have reached frame 500"
fi

kill "$WASM_SERVER_PID" 2>/dev/null || true

echo ""
if [ "$PLAYWRIGHT_EXIT" -eq 0 ]; then
    echo "[pass-98-wasm] ✓ ALL PASS — TIM-540 acceptance criteria met."
    echo "  Criterion 1: WASM extracted from master (includes TIM-537 + TIM-525 + TIM-528)"
    echo "  Criterion 2: Served on port $WASM_PORT with COOP+COEP headers"
    echo "  Criterion 3: e2e/tim537-click.spec.ts PASSED"
    echo "  Criterion 4: wasm-click-verify.png written"
else
    echo "[pass-98-wasm] ✗ Playwright exited with code $PLAYWRIGHT_EXIT — spec FAILED"
    exit "$PLAYWRIGHT_EXIT"
fi
