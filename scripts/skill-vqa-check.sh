#!/usr/bin/env bash
# Single-command VQA codec CI check: regenerate, diff, pixel-diff.
# Used by: ci-cd, vqa-codec skills.
#
# Usage:
#   bash scripts/skill-vqa-check.sh
#
# Steps:
#   1. Regenerate synthetic test VQA to /tmp, diff against committed file
#   2. Run pixel-diff (frames 0,1,2, threshold 5)
#
# Exit code: 0 = all pass, 1 = regeneration mismatch or pixel-diff failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "=== VQA codec CI check ==="

# Step 1: Regenerate and diff
echo ""
echo "--- Step 1: Synthetic VQA regeneration ---"
python3 scripts/gen_test_vqa.py /tmp/test.vqa.new
if diff -q e2e/goldens/vqa/test.vqa /tmp/test.vqa.new >/dev/null 2>&1; then
	echo "PASS: committed test.vqa matches generator output"
	rm /tmp/test.vqa.new
else
	echo "FAIL: committed test.vqa differs from generator output"
	echo "Run: python3 scripts/gen_test_vqa.py e2e/goldens/vqa/test.vqa"
	rm /tmp/test.vqa.new
	exit 1
fi

# Step 2: Pixel-diff
echo ""
echo "--- Step 2: Pixel-diff (frames 0,1,2, threshold 5) ---"
python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2 --threshold 5
VQA_RC=$?

if [[ $VQA_RC -eq 0 ]]; then
	echo ""
	echo "=== All VQA checks PASS ==="
else
	echo ""
	echo "=== VQA pixel-diff FAILED ==="
fi

exit $VQA_RC
