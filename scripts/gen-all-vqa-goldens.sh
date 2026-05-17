#!/usr/bin/env bash
# Generate golden frames for all intro VQA files for three-way parity comparison.
#
# Scenes covered:
#   ENGLISH.VQA  — Tank/Heli intro (Westwood + VIE logos)
#   PROLOG.VQA   — Einstein time-travel prologue
#   ALLY1.VQA    — Allied Mission 1 briefing
#   ALLY1CGI.VQA — Allied Mission 1 CGI load (if present in MIX)
#   SOVIET1.VQA  — Soviet Mission 1 briefing
#   SOVIET2.VQA  — Soviet Mission 2 CGI load
#
# Output: e2e/goldens/vqa/<stem>/frame_0001.png .. frame_0004.png + manifest.json
#
# Usage:
#   bash scripts/gen-all-vqa-goldens.sh [DATA_DIR] [OUT_DIR] [FRAMES]
#
#   DATA_DIR  path to RA CD1 data              (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
#   OUT_DIR   golden output root               (default: e2e/goldens/vqa)
#   FRAMES    frames per VQA                   (default: 4)

set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
OUT_DIR="${2:-e2e/goldens/vqa}"
FRAMES="${3:-4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# VQA files to extract (order matches boot sequence)
VQA_FILES=(
    "ENGLISH.VQA"   # Tank/Heli intro — Westwood + VIE logos
    "PROLOG.VQA"    # Einstein time-travel prologue
    "ALLY1.VQA"     # Allied Mission 1 briefing
    "SOVIET1.VQA"   # Soviet Mission 1 briefing
    "SOVIET2.VQA"   # Soviet Mission 2 CGI load
)

# ALLY1CGI.VQA may not exist (depends on MIX version); warn but don't fail
VQA_OPTIONAL=(
    "ALLY1CGI.VQA"
)

echo "=== Generating VQA goldens ==="
echo "  data:   $DATA_DIR"
echo "  output: $OUT_DIR"
echo "  frames: $FRAMES per VQA"
echo ""

errors=0
generated=0

for vqa in "${VQA_FILES[@]}"; do
    stem="${vqa%.VQA}"
    target_dir="$OUT_DIR/$stem"
    vqa_path="$DATA_DIR/$vqa"

    if [[ ! -f "$vqa_path" ]]; then
        echo "MISSING: $vqa_path — skipping $stem"
        errors=$((errors + 1))
        continue
    fi

    echo "--- $stem ---"
    if python3 "$SCRIPT_DIR/gen-vqa-golden.py" "$vqa_path" "$target_dir" "$FRAMES"; then
        generated=$((generated + 1))
    else
        echo "  FAIL: $stem"
        errors=$((errors + 1))
    fi
    echo ""
done

# Optional VQA files
for vqa in "${VQA_OPTIONAL[@]}"; do
    stem="${vqa%.VQA}"
    target_dir="$OUT_DIR/$stem"
    vqa_path="$DATA_DIR/$vqa"

    if [[ ! -f "$vqa_path" ]]; then
        echo "OPT: $vqa_path not found — skipping $stem"
        continue
    fi

    echo "--- $stem ---"
    if python3 "$SCRIPT_DIR/gen-vqa-golden.py" "$vqa_path" "$target_dir" "$FRAMES"; then
        generated=$((generated + 1))
    else
        echo "  FAIL: $stem (optional)"
    fi
    echo ""
done

echo "=== Done ==="
echo "  generated: $generated"
echo "  errors:    $errors"

if [[ $errors -gt 0 ]]; then
    exit 1
fi
exit 0
