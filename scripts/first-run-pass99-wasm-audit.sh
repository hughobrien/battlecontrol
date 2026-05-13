#!/usr/bin/env bash
# TIM-543 pass-99: RA WASM full gameplay audit — VQA, graphics, input, audio, AI.
#
# Runs the comprehensive Playwright audit (tim542-wasm-audit.spec.ts) against the
# live WASM build (post-TIM-541).  Both servers are expected to already be running;
# if not, they are started here.
#
# Acceptance criteria:
#   1. VQA intro plays         — wasm-vqa-frame-300.png ≥10% fill
#   2. Main menu renders       — canvas non-black after intro
#   3. Scenario loads          — SCG01EA starts via RA_AUTOSTART
#   4. Graphics                — frame-500 fill ≥10% at ≥10fps
#   5. Unit interaction        — [GAME-CLICK] injection confirmed
#   6. Enemy AI                — enemy_units>0 OR death events within 5000 frames
#   7. Audio                   — SDL2 audio opened, no AudioContext crash
#   8. No regression           — TIM-538 criteria (fill≥40%, fps≥15, audio)
#
# Usage (from repo root):
#   bash scripts/first-run-pass99-wasm-audit.sh
#
# Prerequisites:
#   - Node.js + npx (Playwright)
#   - WASM bundle already built at build-wasm/ra.html  (post-TIM-541)
#   - RA MIX assets at /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/
#   - ports 8080 and 9090 available (or already running)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1"
WASM_PORT=8080
ASSET_PORT=9090
LOG="$REPO_ROOT/e2e/test-run-pass99-wasm-audit.log"

WASM_PID=""
ASSET_PID=""

cleanup() {
    echo "[pass-99] cleaning up…"
    [[ -n "$WASM_PID"  ]] && kill "$WASM_PID"  2>/dev/null || true
    [[ -n "$ASSET_PID" ]] && kill "$ASSET_PID" 2>/dev/null || true
}
trap cleanup EXIT

cd "$REPO_ROOT"

# ── 1. Verify WASM bundle ─────────────────────────────────────────────────
if [[ ! -f build-wasm/ra.html ]]; then
    echo "[pass-99] ERROR: build-wasm/ra.html not found — build the WASM bundle first" >&2
    echo "  Hint: emcmake cmake --preset wasm && cmake --build build-wasm --target ra -j\$(nproc)" >&2
    exit 1
fi
echo "[pass-99] WASM bundle: $(ls -lh build-wasm/ra.html)"

# ── 2. Verify assets ──────────────────────────────────────────────────────
if [[ ! -d "$ASSET_DIR" ]]; then
    echo "[pass-99] ERROR: RA asset directory not found: $ASSET_DIR" >&2
    exit 1
fi
echo "[pass-99] assets found at $ASSET_DIR:"
ls "$ASSET_DIR" | head -10

# ── 3. Start servers (skip if already listening) ───────────────────────────
start_server_if_needed() {
    local port=$1
    local label=$2
    local cmd=$3

    if curl -s --max-time 1 "http://localhost:$port/" >/dev/null 2>&1; then
        echo "[pass-99] $label already running on port $port — reusing"
    else
        echo "[pass-99] starting $label on port $port…"
        eval "$cmd" &
        local pid=$!
        echo "[pass-99] $label PID=$pid"
        sleep 2
        if ! curl -s --max-time 2 "http://localhost:$port/" >/dev/null 2>&1; then
            echo "[pass-99] WARNING: $label on port $port did not respond after 2s" >&2
        fi
        echo "$pid"
    fi
    echo ""
}

echo "[pass-99] checking WASM server (port $WASM_PORT)…"
if curl -s --max-time 1 "http://localhost:$WASM_PORT/ra.html" >/dev/null 2>&1; then
    echo "[pass-99] WASM server already running on port $WASM_PORT — reusing"
else
    echo "[pass-99] starting serve-coop.py on port $WASM_PORT…"
    python3 wasm/serve-coop.py "$WASM_PORT" &
    WASM_PID=$!
    sleep 2
    echo "[pass-99] WASM server PID=$WASM_PID"
fi

echo "[pass-99] checking asset server (port $ASSET_PORT)…"
if curl -s --max-time 1 "http://localhost:$ASSET_PORT/" >/dev/null 2>&1; then
    echo "[pass-99] asset server already running on port $ASSET_PORT — reusing"
else
    echo "[pass-99] starting serve-assets.py on port $ASSET_PORT…"
    python3 wasm/serve-assets.py "$ASSET_DIR" "$ASSET_PORT" &
    ASSET_PID=$!
    sleep 2
    echo "[pass-99] asset server PID=$ASSET_PID"
fi

# ── 4. Verify COOP/COEP and CORS headers ─────────────────────────────────
echo "[pass-99] checking COOP/COEP headers on WASM server…"
curl -sI "http://localhost:$WASM_PORT/ra.html" | grep -i "cross-origin" || \
    echo "[pass-99] WARNING: COOP/COEP headers not detected — SharedArrayBuffer may fail"

echo "[pass-99] checking CORS headers on asset server…"
FIRST_MIX="$(ls "$ASSET_DIR"/*.MIX 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo '')"
if [[ -n "$FIRST_MIX" ]]; then
    curl -sI "http://localhost:$ASSET_PORT/$FIRST_MIX" | grep -i "access-control" || \
        echo "[pass-99] WARNING: CORS headers not detected on asset server"
fi

# ── 5. Install Playwright (idempotent) ────────────────────────────────────
if [[ ! -d node_modules ]]; then
    echo "[pass-99] installing npm deps…"
    npm install
fi
echo "[pass-99] installing Playwright Chromium browser…"
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

# ── 6. Run the pass-99 audit spec ─────────────────────────────────────────
echo "[pass-99] running TIM-543 WASM full gameplay audit…"
echo "[pass-99] log → $LOG"
echo ""

SPEC="e2e/tim542-wasm-audit.spec.ts"
EXIT_CODE=0

npx playwright test \
    --config playwright.config.ts \
    --reporter=list \
    "$SPEC" 2>&1 | tee "$LOG" || EXIT_CODE=$?

echo ""
echo "[pass-99] ──────────────────────────────────────────"
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "[pass-99] RESULT: ALL TESTS PASSED (exit 0)"
else
    echo "[pass-99] RESULT: SOME TESTS FAILED (exit $EXIT_CODE)"
fi
echo "[pass-99] log: $LOG"
echo "[pass-99] screenshots: e2e/screenshots/"
echo ""
echo "[pass-99] Key artifacts:"
for f in \
    e2e/screenshots/wasm-vqa-frame-300.png \
    e2e/screenshots/tim543-A-main-menu.png \
    e2e/screenshots/tim543-B-frame500.png \
    e2e/screenshots/wasm-frame-5000-audit.png; do
    if [[ -f "$f" ]]; then
        echo "  $f ($(du -h "$f" | cut -f1))"
    else
        echo "  $f (NOT FOUND)"
    fi
done

exit $EXIT_CODE
