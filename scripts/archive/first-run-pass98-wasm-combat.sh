#!/usr/bin/env bash
# TIM-541 pass-98 WASM combat: verify enemy AI engagement in the browser build.
#
# Runs a 5000+ frame WASM gameplay session under Playwright Chromium with
# RA_AUTOSTART=1 and RA_GAME_CLICK=1 (?autostart=1&gameclk=1&debug=1) and
# confirms that enemy AI is active and combat occurs in the browser build.
#
# ACCEPTANCE CRITERIA (TIM-541):
#   1. WASM game runs 5000+ frames in Playwright Chromium — no crash, no hang.
#   2. At least one of:
#        [TIM-536] enemy_units > 0 at any 1000-frame probe (AI ticking), or
#        [TIM-301] death_announcement logged (combat event), or
#        fps ≥10 at frame 5000 (game alive and processing AI).
#   3. wasm-frame-5000-combat.png written with ≥10% pixel fill.
#   4. No TIM-538 regressions: no crash, SDL2 audio OK, fill≥40%@500, fps≥15 (300→500).
#   5. e2e/tim541-combat.spec.ts committed (this script drives it).
#
# Prerequisites:
#   - serve-assets.py already running on port 9090 serving RA MIX files
#   - Node.js + npx (Playwright) installed
#   - Xvfb running on :99 (required for headed Chrome with WebGL/SharedArrayBuffer)
#   - git remote 'battlecontrol' configured with gh-pages access
#
# Usage (from repo root):
#   bash scripts/first-run-pass98-wasm-combat.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

WASM_PORT=8080
ASSET_PORT=9090
LOG_FILE="e2e/test-run-tim541.log"

echo "[pass-98-combat] === Step 1: Extract WASM from gh-pages ==="
echo "[pass-98-combat] Fetching battlecontrol remote..."
git fetch battlecontrol

GH_PAGES_COMMIT="$(git rev-parse battlecontrol/gh-pages)"
MASTER_COMMIT="$(git rev-parse battlecontrol/master)"
echo "[pass-98-combat] gh-pages: $GH_PAGES_COMMIT"
echo "[pass-98-combat] master:   $MASTER_COMMIT"

mkdir -p build-wasm

echo "[pass-98-combat] Extracting ra.html, ra.js, ra.wasm, preloader.js, coi-serviceworker.min.js..."
git show battlecontrol/gh-pages:ra.html                   > build-wasm/ra.html
git show battlecontrol/gh-pages:ra.js                     > build-wasm/ra.js
git show battlecontrol/gh-pages:ra.wasm                   > build-wasm/ra.wasm
git show battlecontrol/gh-pages:preloader.js              > build-wasm/preloader.js
git show battlecontrol/gh-pages:coi-serviceworker.min.js  > build-wasm/coi-serviceworker.min.js

echo "[pass-98-combat] Verifying gameclk=1 support in ra.html (TIM-537)..."
grep -q "gameclk" build-wasm/ra.html \
    && echo "[pass-98-combat] ✓ gameclk param found in ra.html" \
    || { echo "[pass-98-combat] ✗ gameclk NOT found in ra.html — aborting"; exit 1; }

echo "[pass-98-combat] Verifying RA_GAME_CLICK propagation (TIM-540)..."
grep -q "RA_GAME_CLICK" build-wasm/ra.html \
    && echo "[pass-98-combat] ✓ RA_GAME_CLICK found in ra.html (TIM-540 PROXY_TO_PTHREAD fix present)" \
    || echo "[pass-98-combat] ℹ RA_GAME_CLICK not found in ra.html (may be set in JS rather than HTML)"

echo "[pass-98-combat] WASM binary: $(ls -lh build-wasm/ra.wasm | awk '{print $5, $9}')"

echo ""
echo "[pass-98-combat] === Step 2: Start WASM server on port $WASM_PORT ==="
OLD_PID="$(lsof -ti ":$WASM_PORT" 2>/dev/null || true)"
if [ -n "$OLD_PID" ]; then
    echo "[pass-98-combat] Killing stale server PID=$OLD_PID on port $WASM_PORT"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
fi

python3 wasm/serve-coop.py "$WASM_PORT" "$(pwd)/build-wasm" &
WASM_SERVER_PID=$!
echo "[pass-98-combat] Started serve-coop.py PID=$WASM_SERVER_PID"
sleep 2

echo "[pass-98-combat] COOP/COEP headers check:"
curl -sI "http://localhost:$WASM_PORT/ra.html" \
    | grep -E "cross-origin|HTTP" | sed 's/^/  /' || true

echo ""
echo "[pass-98-combat] === Step 3: Verify asset server on port $ASSET_PORT ==="
if curl -sI "http://localhost:$ASSET_PORT/" 2>/dev/null | grep -q "200\|403"; then
    echo "[pass-98-combat] ✓ Asset server responding on port $ASSET_PORT"
else
    echo "[pass-98-combat] ✗ No asset server on port $ASSET_PORT — cannot run"
    echo "  Start it first: python3 wasm/serve-assets.py /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 $ASSET_PORT &"
    kill "$WASM_SERVER_PID" 2>/dev/null || true
    exit 1
fi

echo ""
echo "[pass-98-combat] === Step 4: Run TIM-541 combat spec (5000-frame WASM run) ==="
echo "[pass-98-combat] NOTE: This test takes ~20-30 min at WASM speeds. Timeout = 30 min."

if [ ! -d node_modules ]; then
    echo "[pass-98-combat] Installing npm deps..."
    npm install
fi

DISPLAY="${DISPLAY:-:99}" npx playwright test e2e/tim541-combat.spec.ts \
    --config playwright.config.ts \
    --reporter=list 2>&1 | tee "$LOG_FILE"

PLAYWRIGHT_EXIT=${PIPESTATUS[0]}

echo ""
echo "[pass-98-combat] === Step 5: Check screenshots ==="
SCREENSHOT_DIR="$REPO_ROOT/e2e/screenshots"

if [ -f "$SCREENSHOT_DIR/wasm-frame-5000-combat.png" ]; then
    echo "[pass-98-combat] ✓ wasm-frame-5000-combat.png written"
    ls -lh "$SCREENSHOT_DIR/wasm-frame-5000-combat.png"
else
    echo "[pass-98-combat] ✗ wasm-frame-5000-combat.png NOT found — spec may not have reached frame 5000"
fi

echo ""
echo "[pass-98-combat] === Step 6: Optional — TIM-538 regression spec ==="
echo "[pass-98-combat] Running tim538-audit.spec.ts to confirm no WASM regressions..."

DISPLAY="${DISPLAY:-:99}" npx playwright test e2e/tim538-audit.spec.ts \
    --config playwright.config.ts \
    --reporter=list 2>&1 | tee -a "$LOG_FILE"

TIM538_EXIT=${PIPESTATUS[0]}

kill "$WASM_SERVER_PID" 2>/dev/null || true

echo ""
if [ "$PLAYWRIGHT_EXIT" -eq 0 ]; then
    echo "[pass-98-combat] ✓ TIM-541 combat spec PASS"
else
    echo "[pass-98-combat] ✗ TIM-541 combat spec FAILED (exit=$PLAYWRIGHT_EXIT)"
fi

if [ "$TIM538_EXIT" -eq 0 ]; then
    echo "[pass-98-combat] ✓ TIM-538 regression spec PASS"
else
    echo "[pass-98-combat] ✗ TIM-538 regression spec FAILED (exit=$TIM538_EXIT)"
fi

echo ""
echo "[pass-98-combat] Acceptance criteria (TIM-541):"
echo "  1. 5000+ frames, no crash:         see test output above"
echo "  2. Enemy AI evidence:              see [TIM-536] / [TIM-301] lines in $LOG_FILE"
echo "  3. wasm-frame-5000-combat.png:     $([ -f "$SCREENSHOT_DIR/wasm-frame-5000-combat.png" ] && echo "✓ written" || echo "✗ NOT FOUND")"
echo "  4. TIM-538 regression:             $([ "$TIM538_EXIT" -eq 0 ] && echo "✓ PASS" || echo "✗ FAIL")"
echo "  5. tim541-combat.spec.ts committed (already in repo)"

if [ "$PLAYWRIGHT_EXIT" -ne 0 ]; then
    exit "$PLAYWRIGHT_EXIT"
fi
