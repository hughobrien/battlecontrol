#!/usr/bin/env bash
# Parity — capture + compare for a scene/VQA in one command.
# Usage: bash scripts/parity.sh check <scene> [--mode vqa|gameplay] [--targets wine,wasm,native]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC2034
ACTION="${1:?Usage: parity.sh check <scene> [--mode vqa|gameplay] [--targets ...]}"
shift
SCENE="${1:?Usage: parity.sh check <scene>}"
shift

MODE="vqa"
TARGETS="wine,wasm,native"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--mode)
		MODE="$2"
		shift 2
		;;
	--targets)
		TARGETS="$2"
		shift 2
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 1
		;;
	esac
done

echo "=== Parity check: $SCENE (mode=$MODE, targets=$TARGETS) ==="
echo ""

# Ensure goldens exist for VQA mode
if [[ "$MODE" == "vqa" ]]; then
	MANIFEST="e2e/goldens/vqa/$SCENE/manifest.json"
	if [[ ! -f "$MANIFEST" ]]; then
		echo "Missing golden frames for $SCENE."
		echo "  Decode first: python3 scripts/vqa-decode.py --vqa $SCENE.VQA --mix MAIN.MIX --out e2e/goldens/vqa/$SCENE"
		echo "  Or:           python3 scripts/vqa-decode.py --vqa $SCENE.VQA --mix MAIN.MIX --out e2e/goldens/vqa/$SCENE"
		echo ""
	fi
fi

# Step 1: Capture from all targets
echo "--- Capturing: $SCENE (mode=$MODE) ---"
python3 scripts/capture-checkpoint.py "$MODE" "$SCENE" --targets "$TARGETS"
echo ""

# Step 2: Compare and report
echo "--- Comparing: $SCENE (mode=$MODE) ---"
bash scripts/parity-report.sh "$SCENE" --mode "$MODE" --targets "$TARGETS"
