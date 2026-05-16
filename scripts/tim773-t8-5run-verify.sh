#!/usr/bin/env bash
# TIM-773: Run T8 RA WASM PROLOG.VQA audio pitch probe 5× from cold cache.
# Each Playwright test run creates a fresh browser context (no shared state),
# satisfying the "cold-cache" requirement per TIM-600 / project memory feedback.
#
# Prerequisites: serve-coop.py running on :8080, RA_ASSETS_URL exported.
# Usage: RA_ASSETS_URL=https://... DISPLAY=:99 bash scripts/tim773-t8-5run-verify.sh
# Output: e2e/report/tim773-t8/run-N.log (N=1..5), e2e/report/tim773-t8/summary.txt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$REPO_ROOT/e2e/report/tim773-t8"
SPEC="$REPO_ROOT/e2e/regression/T8-ra-audio-pitch.spec.ts"

mkdir -p "$REPORT_DIR"

echo "=== TIM-773: 5× cold-cache run of T8 RA audio pitch probe ===" | tee "$REPORT_DIR/summary.txt"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee -a "$REPORT_DIR/summary.txt"
echo "Spec: $SPEC" | tee -a "$REPORT_DIR/summary.txt"
echo "RA_ASSETS_URL: ${RA_ASSETS_URL:-(not set — T8 will skip)}" | tee -a "$REPORT_DIR/summary.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

PASS=0
FAIL=0
declare -a RESULTS

cd "$REPO_ROOT"

for RUN in 1 2 3 4 5; do
    echo "--- Run $RUN/5 started at $(date -u '+%H:%M:%SZ') ---" | tee -a "$REPORT_DIR/summary.txt"
    LOG="$REPORT_DIR/run-$RUN.log"
    START_TS=$(date +%s)

    if DISPLAY="${DISPLAY:-:99}" npx playwright test "$SPEC" \
            --reporter=line \
            --workers=1 \
            --timeout=600000 \
            > "$LOG" 2>&1; then
        STATUS="PASS"
        PASS=$((PASS + 1))
    else
        STATUS="FAIL"
        FAIL=$((FAIL + 1))
    fi

    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    RESULTS+=("Run $RUN: $STATUS  (${ELAPSED}s)")
    echo "  -> $STATUS in ${ELAPSED}s" | tee -a "$REPORT_DIR/summary.txt"

    for F in e2e/screenshots/t8-ra-fft-t5s.json e2e/screenshots/t8-ra-fft-t20s.json; do
        [ -f "$F" ] && cp "$F" "$REPORT_DIR/run-${RUN}-$(basename "$F")" || true
    done
    for PNG in e2e/screenshots/t8-ra-02-prolog-start.png e2e/screenshots/t8-ra-03-t5s.png e2e/screenshots/t8-ra-03-t20s.png; do
        [ -f "$PNG" ] && cp "$PNG" "$REPORT_DIR/run-${RUN}-$(basename "$PNG")" || true
    done
    [ -f e2e/screenshots/t8-ra-console.log ] && \
        cp e2e/screenshots/t8-ra-console.log "$REPORT_DIR/run-${RUN}-console.log" || true
done

echo "" | tee -a "$REPORT_DIR/summary.txt"
echo "=== RESULTS ===" | tee -a "$REPORT_DIR/summary.txt"
for R in "${RESULTS[@]}"; do
    echo "  $R" | tee -a "$REPORT_DIR/summary.txt"
done
echo "" | tee -a "$REPORT_DIR/summary.txt"
echo "Total: PASS=$PASS  FAIL=$FAIL" | tee -a "$REPORT_DIR/summary.txt"
echo "Finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee -a "$REPORT_DIR/summary.txt"

if [ "$FAIL" -eq 0 ]; then
    echo "VERDICT: ALL 5 PASS — RA WASM audio pitch fix verified 5× cold-cache" | tee -a "$REPORT_DIR/summary.txt"
    exit 0
else
    echo "VERDICT: $FAIL/5 FAIL — regression or intermittent trap detected" | tee -a "$REPORT_DIR/summary.txt"
    exit 1
fi
