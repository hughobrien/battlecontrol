#!/usr/bin/env bash
# TIM-546: TD WASM full gameplay audit — unit interaction, enemy AI, complete e2e.
#
# Runs the comprehensive Playwright audit (td-wasm-audit.spec.ts) against the
# live TD WASM build.  Both servers are expected to already be running;
# if not, they are started here.
#
# Acceptance criteria:
#   1. Main menu renders       — canvas non-black after game init
#   2. Scenario loads          — SCG01EA starts via TD_AUTOSTART
#   3. Graphics                — frame-500 fill ≥10% at ≥10fps (WASM threshold)
#   4. Unit interaction        — [GAME-CLICK] injection confirmed (TD_GAME_CLICK.FLAG)
#   5. Enemy AI                — enemy_units>0 OR fps≥10 at frame 5000
#   6. Audio                   — SDL2 audio opened, no AudioContext crash
#   7. No regression           — TIM-466 criteria (fill≥20%@300, fill≥20%@500, audio)
#
# Usage (from repo root):
#   bash scripts/first-run-td-wasm-audit.sh
#
# Prerequisites:
#   - Node.js + npx (Playwright)
#   - TD WASM bundle already built at build-wasm/td.html
#   - TD MIX assets at /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/
#   - ports 8082 and 9091 available (or already running)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
WASM_PORT=8082
ASSET_PORT=9091
LOG="$REPO_ROOT/e2e/test-run-td-wasm-audit.log"

WASM_PID=""
ASSET_PID=""

cleanup() {
    echo "[td-audit] cleaning up…"
    [[ -n "$WASM_PID"  ]] && kill "$WASM_PID"  2>/dev/null || true
    [[ -n "$ASSET_PID" ]] && kill "$ASSET_PID" 2>/dev/null || true
}
trap cleanup EXIT

cd "$REPO_ROOT"

# ── 1. Verify WASM bundle ─────────────────────────────────────────────────
if [[ ! -f build-wasm/td.html ]]; then
    echo "[td-audit] ERROR: build-wasm/td.html not found — build the TD WASM bundle first" >&2
    echo "  Hint: emcmake cmake --preset wasm && cmake --build build-wasm --target td -j\$(nproc)" >&2
    exit 1
fi
echo "[td-audit] WASM bundle: $(ls -lh build-wasm/td.html)"

# ── 2. Verify assets ──────────────────────────────────────────────────────
if [[ ! -d "$ASSET_DIR" ]]; then
    echo "[td-audit] ERROR: TD asset directory not found: $ASSET_DIR" >&2
    exit 1
fi
echo "[td-audit] assets found at $ASSET_DIR:"
ls "$ASSET_DIR" | head -10

# ── 3. Start servers (skip if already listening) ───────────────────────────
echo "[td-audit] checking WASM server (port $WASM_PORT)…"
if curl -s --max-time 1 "http://localhost:$WASM_PORT/td.html" >/dev/null 2>&1; then
    echo "[td-audit] WASM server already running on port $WASM_PORT — reusing"
else
    echo "[td-audit] starting serve-coop.py on port $WASM_PORT…"
    python3 wasm/serve-coop.py "$WASM_PORT" &
    WASM_PID=$!
    sleep 2
    echo "[td-audit] WASM server PID=$WASM_PID"
fi

echo "[td-audit] checking asset server (port $ASSET_PORT)…"
if curl -s --max-time 1 "http://localhost:$ASSET_PORT/" >/dev/null 2>&1; then
    echo "[td-audit] asset server already running on port $ASSET_PORT — reusing"
else
    echo "[td-audit] starting serve-assets.py on port $ASSET_PORT…"
    python3 wasm/serve-assets.py "$ASSET_DIR" "$ASSET_PORT" &
    ASSET_PID=$!
    sleep 2
    echo "[td-audit] asset server PID=$ASSET_PID"
fi

# ── 4. Verify COOP/COEP and CORS headers ─────────────────────────────────
echo "[td-audit] checking COOP/COEP headers on WASM server…"
curl -sI "http://localhost:$WASM_PORT/td.html" | grep -i "cross-origin" || \
    echo "[td-audit] WARNING: COOP/COEP headers not detected — SharedArrayBuffer may fail"

echo "[td-audit] checking CORS headers on asset server…"
FIRST_MIX="$(ls "$ASSET_DIR"/*.MIX 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo '')"
if [[ -n "$FIRST_MIX" ]]; then
    curl -sI "http://localhost:$ASSET_PORT/$FIRST_MIX" | grep -i "access-control" || \
        echo "[td-audit] WARNING: CORS headers not detected on asset server"
fi

# ── 5. Install Playwright (idempotent) ────────────────────────────────────
if [[ ! -d node_modules ]]; then
    echo "[td-audit] installing npm deps…"
    npm install
fi
echo "[td-audit] installing Playwright Chromium browser…"
npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium

# ── 6. Run the TD WASM audit spec ─────────────────────────────────────────
echo "[td-audit] running TIM-546 TD WASM full gameplay audit…"
echo "[td-audit] log → $LOG"
echo ""

SPEC="e2e/td-wasm-audit.spec.ts"
EXIT_CODE=0

npx playwright test \
    --config playwright.config.ts \
    --reporter=list \
    "$SPEC" 2>&1 | tee "$LOG" || EXIT_CODE=$?

echo ""
echo "[td-audit] ──────────────────────────────────────────"
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "[td-audit] RESULT: ALL TESTS PASSED (exit 0)"
else
    echo "[td-audit] RESULT: SOME TESTS FAILED (exit $EXIT_CODE)"
fi
echo "[td-audit] log: $LOG"
echo "[td-audit] screenshots: e2e/screenshots/"
echo ""
echo "[td-audit] Key artifacts:"
for f in \
    e2e/screenshots/td546-A-menu.png \
    e2e/screenshots/td546-B-frame500.png \
    e2e/screenshots/td-wasm-frame-5000-audit.png; do
    if [[ -f "$f" ]]; then
        echo "  $f ($(du -h "$f" | cut -f1))"
    else
        echo "  $f (NOT FOUND)"
    fi
done

exit $EXIT_CODE
