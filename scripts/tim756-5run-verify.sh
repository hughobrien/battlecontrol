#!/usr/bin/env bash
# TIM-756: Run TIM-603 AnalyserNode FFT probe 5× from cold cache.
# Each Playwright test run creates a fresh browser context (no shared state),
# which satisfies the "cold-cache" requirement per TIM-600 feedback rule.
#
# Usage: bash scripts/tim756-5run-verify.sh
# Output: e2e/report/tim756/run-N.log  (N=1..5), e2e/report/tim756/summary.txt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$REPO_ROOT/e2e/report/tim756"
SPEC="$REPO_ROOT/e2e/tim603-audio-pitch-probe.spec.ts"

mkdir -p "$REPORT_DIR"

echo "=== TIM-756: 5× cold-cache run of TIM-603 ===" | tee "$REPORT_DIR/summary.txt"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee -a "$REPORT_DIR/summary.txt"
echo "Spec: $SPEC" | tee -a "$REPORT_DIR/summary.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

PASS=0
FAIL=0
declare -a RESULTS

cd "$REPO_ROOT"

for RUN in 1 2 3 4 5; do
    echo "--- Run $RUN/5 started at $(date -u '+%H:%M:%SZ') ---" | tee -a "$REPORT_DIR/summary.txt"
    LOG="$REPORT_DIR/run-$RUN.log"
    START_TS=$(date +%s)

    # Run with DISPLAY=:99 (Xvfb), capturing full output.
    # --reporter=line gives concise per-test output.
    # --workers=1 ensures a single browser instance (avoids resource contention).
    if DISPLAY=:99 npx playwright test "$SPEC" \
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

    # Copy FFT JSON artifacts per run (they get overwritten by each test).
    for F in e2e/screenshots/tim603-prolog-fft-t30s.json e2e/screenshots/tim603-prolog-fft-t60s.json; do
        [ -f "$F" ] && cp "$F" "$REPORT_DIR/run-${RUN}-$(basename "$F")" || true
    done
    for PNG in e2e/screenshots/tim603-prolog-t30s.png e2e/screenshots/tim603-prolog-t60s.png; do
        [ -f "$PNG" ] && cp "$PNG" "$REPORT_DIR/run-${RUN}-$(basename "$PNG")" || true
    done
    [ -f e2e/screenshots/tim603-prolog-console.log ] && \
        cp e2e/screenshots/tim603-prolog-console.log "$REPORT_DIR/run-${RUN}-console.log" || true
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
    echo "VERDICT: ALL 5 PASS — TIM-604 VQA audio fix verified 5× cold-cache" | tee -a "$REPORT_DIR/summary.txt"
    exit 0
else
    echo "VERDICT: $FAIL/5 FAIL — regression or intermittent trap detected" | tee -a "$REPORT_DIR/summary.txt"
    exit 1
fi
