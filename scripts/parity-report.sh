#!/usr/bin/env bash
# Three-way parity report — compare golden frames against captures from
# each target (wine, native, wasm) using parity-compare.py.
#
# Two modes:
#   vqa      (default) — reads manifest.json from e2e/goldens/vqa/<scene>/
#              with multi-frame numbering (frame_0001.png … frame_000N.png).
#   gameplay — reads manifest.json from e2e/goldens/gameplay/<scene>/
#              with a single golden.png frame.
#
# Usage:
#   bash scripts/parity-report.sh <scene> [--mode vqa|gameplay] [--targets wine,wasm,native] [--threshold SSIM]
#
#   bash scripts/parity-report.sh ENGLISH
#   bash scripts/parity-report.sh ENGLISH --targets wine
#   bash scripts/parity-report.sh PROLOG --targets wine,wasm
#   bash scripts/parity-report.sh allied-l1 --mode gameplay --targets wine,wasm,native
#   bash scripts/parity-report.sh soviet-l1 --mode gameplay --targets wine,wasm,native
#
# Exit: 0 = all comparisons passed, 1 = one or more failed, 2 = SKIP (manifest missing).

set -euo pipefail

SCENE="${1:?usage: $0 <SCENE> [--mode vqa|gameplay] [--targets TARGETS] [--threshold SSIM]}"
shift

MODE="vqa"
TARGETS="wine,wasm,native"
THRESHOLD="0.90"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       MODE="$2"; shift 2 ;;
        --targets)    TARGETS="$2"; shift 2 ;;
        --threshold)  THRESHOLD="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$MODE" != "vqa" && "$MODE" != "gameplay" ]]; then
    echo "FAIL: mode must be 'vqa' or 'gameplay', got '$MODE'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

IFS=',' read -ra TARGET_LIST <<< "$TARGETS"

# --- Paths based on mode --------------------------------------------------

if [[ "$MODE" == "gameplay" ]]; then
    GOLDEN_DIR="e2e/goldens/gameplay/$SCENE"
    MANIFEST="$GOLDEN_DIR/manifest.json"
    WINE_DIR="e2e/screenshots/wine-gameplay/$SCENE"
    NATIVE_DIR="e2e/screenshots/native-gameplay/$SCENE"
    WASM_DIR="e2e/screenshots/wasm-gameplay/$SCENE"
else
    GOLDEN_DIR="e2e/goldens/vqa/$SCENE"
    MANIFEST="$GOLDEN_DIR/manifest.json"
    WINE_DIR="e2e/screenshots/wine-vqa"
    NATIVE_DIR="e2e/screenshots/native-vqa"
    WASM_DIR="e2e/screenshots/wasm-vqa"
fi
DIFF_DIR="e2e/screenshots/diffs"
mkdir -p "$DIFF_DIR"

# --- Read manifest --------------------------------------------------------

if [[ ! -f "$MANIFEST" ]]; then
    echo "FAIL: manifest not found at $MANIFEST"
    if [[ "$MODE" == "vqa" ]]; then
        echo "  Run: bash scripts/gen-all-vqa-goldens.sh"
    else
        echo "  Run: bash scripts/gen-gameplay-goldens.sh $SCENE"
    fi
    exit 2
fi

TOTAL_FRAMES=$(python3 -c "import json; d=json.load(open('$MANIFEST')); print(d.get('total_frames',1))" 2>/dev/null || echo "0")
FRAME_COUNT=$(python3 -c "import json; d=json.load(open('$MANIFEST')); print(len(d.get('extracted',[{}])))" 2>/dev/null || echo "0")

echo "=== Parity Report: $SCENE (mode=$MODE) ==="
echo "  total frames: $TOTAL_FRAMES"
echo "  golden frames: $FRAME_COUNT"
echo "  targets:      $TARGETS"
echo "  threshold SSIM: $THRESHOLD"
echo ""

# --- Determine golden and capture file paths per frame --------------------

# For VQA: golden is frame_0001.png, captures are vqa-<scene>-0000.png etc.
# For gameplay: golden is golden.png, captures are capture.png
declare -A GOLDEN_PATHS
declare -A CAPTURE_PATHS

if [[ "$MODE" == "gameplay" ]]; then
    # Single frame.
    GOLDEN_PATHS[0]="$GOLDEN_DIR/golden.png"
    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs)
        case "$target" in
            wine)   CAPTURE_PATHS["0-$target"]="$WINE_DIR/capture.png" ;;
            native) CAPTURE_PATHS["0-$target"]="$NATIVE_DIR/capture.png" ;;
            wasm)   CAPTURE_PATHS["0-$target"]="$WASM_DIR/capture.png" ;;
            *)      ;;
        esac
    done
else
    # VQA multi-frame.
    for i in $(seq 0 $((FRAME_COUNT - 1))); do
        GOLDEN_PATHS[$i]="$GOLDEN_DIR/frame_$(printf '%04d' $((i+1))).png"
        for target in "${TARGET_LIST[@]}"; do
            target=$(echo "$target" | xargs)
            case "$target" in
                wine)   CAPTURE_PATHS["$i-$target"]="$WINE_DIR/vqa-${SCENE}-$(printf '%04d' "$i").png" ;;
                native) CAPTURE_PATHS["$i-$target"]="$NATIVE_DIR/vqa-${SCENE}-$(printf '%04d' "$i").png" ;;
                wasm)   CAPTURE_PATHS["$i-$target"]="$WASM_DIR/vqa-${SCENE}-$(printf '%04d' "$i").png" ;;
                *)      ;;
            esac
        done
    done
fi

# --- Compare each frame against each target --------------------------------

declare -A RESULTS
PASS=0
FAIL=0
SKIP=0

MAX_I=$((FRAME_COUNT - 1))
if [[ "$MODE" == "gameplay" ]]; then
    MAX_I=0
fi

for i in $(seq 0 $MAX_I); do
    if [[ "$MODE" == "gameplay" ]]; then
        FRAME_LABEL="golden"
    else
        FRAME_LABEL="frame-$((i+1))"
    fi
    GOLDEN="${GOLDEN_PATHS[$i]}"

    if [[ ! -f "$GOLDEN" ]]; then
        echo "  MISS golden: $GOLDEN"
        continue
    fi

    echo "--- $FRAME_LABEL ---"

    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs)

        CAPTURE="${CAPTURE_PATHS["$i-$target"]:-}"
        if [[ -z "$CAPTURE" ]]; then
            echo "  SKIP ${SCENE}-${FRAME_LABEL}-${target} — unknown target"
            SKIP=$((SKIP + 1))
            RESULTS["${SCENE}-${i}-${target}"]="SKIP"
            continue
        fi

        LABEL="${SCENE}-${FRAME_LABEL}-${target}"

        if [[ "$MODE" == "gameplay" ]]; then
            DIFF_OUT="$DIFF_DIR/diff-${SCENE}-${target}.png"
        else
            DIFF_OUT="$DIFF_DIR/diff-${SCENE}-f$((i+1))-${target}.png"
        fi

        if [[ ! -f "$CAPTURE" ]]; then
            echo "  SKIP $LABEL — capture missing: $CAPTURE"
            SKIP=$((SKIP + 1))
            RESULTS["${SCENE}-${i}-${target}"]="SKIP"
            continue
        fi

        RESULT=$(python3 scripts/parity-compare.py \
            "$GOLDEN" "$CAPTURE" \
            --label "$LABEL" \
            --threshold-ssim "$THRESHOLD" \
            --diff-out "$DIFF_OUT" \
            --json 2>/dev/null || echo '{"status":"FAIL","ssim":0,"p99_diff":999}')

        STATUS=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','FAIL'))" 2>/dev/null || echo "FAIL")
        SSIM=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(round(d.get('ssim',0),4))" 2>/dev/null || echo "0")
        P99=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('p99_diff','?'))" 2>/dev/null || echo "?")
        FILLA=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('fill_a','?'))" 2>/dev/null || echo "?")
        FILLB=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('fill_b','?'))" 2>/dev/null || echo "?")

        if [[ "$STATUS" == "PASS" ]]; then
            echo "  PASS $LABEL  ssim=$SSIM  p99_diff=${P99}  fill=(${FILLA}%,${FILLB}%)"
            PASS=$((PASS + 1))
        elif [[ "$STATUS" == "SKIP" ]]; then
            echo "  SKIP $LABEL"
            SKIP=$((SKIP + 1))
        else
            echo "  FAIL $LABEL  ssim=$SSIM  p99_diff=${P99}  fill=(${FILLA}%,${FILLB}%)  diff=$DIFF_OUT"
            FAIL=$((FAIL + 1))
        fi
        RESULTS["${SCENE}-${i}-${target}"]="$STATUS"
    done
    echo ""
done

# --- Summary table ---------------------------------------------------------

echo "=== Summary ==="
echo ""

if [[ "$MODE" == "gameplay" ]]; then
    printf "%-12s" "Scene"
    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs)
        printf " %-10s" "$target"
    done
    echo ""
    printf "%-12s" "------------"
    for target in "${TARGET_LIST[@]}"; do
        printf " %-10s" "----------"
    done
    echo ""

    printf "%-12s" "$SCENE"
    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs)
        status="${RESULTS["${SCENE}-0-${target}"]:-MISS}"
        printf " %-10s" "$status"
    done
    echo ""
else
    printf "%-12s" "Frame"
    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs)
        printf " %-10s" "$target"
    done
    echo ""
    printf "%-12s" "------------"
    for target in "${TARGET_LIST[@]}"; do
        printf " %-10s" "----------"
    done
    echo ""

    for i in $(seq 0 $MAX_I); do
        printf "%-12s" "frame-$((i+1))"
        for target in "${TARGET_LIST[@]}"; do
            target=$(echo "$target" | xargs)
            status="${RESULTS["${SCENE}-${i}-${target}"]:-MISS}"
            printf " %-10s" "$status"
        done
        echo ""
    done
fi

echo ""
echo "  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
echo ""

[[ $FAIL -gt 0 ]] && exit 1
exit 0
