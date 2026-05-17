#!/usr/bin/env bash
# Generate gameplay golden references from Wine captures.
#
# Runs the appropriate wine-*.sh capture script, then stages the canonical
# frame as the golden reference at e2e/goldens/gameplay/<mission>/golden.png
# plus a single-frame manifest.json.
#
# For gameplay, the Wine OG (ra95/Wine) IS the reference — 1996 binary running
# under Wine produces the authoritative frame.  The native and WASM ports are
# compared against that golden.
#
# Usage:
#   bash scripts/gen-gameplay-goldens.sh allied-l1
#   bash scripts/gen-gameplay-goldens.sh soviet-l1
#
# Prerequisites:
#   - bash scripts/wine-allied-l1.sh or scripts/wine-soviet-l1.sh must work
#   - python3 available for manifest generation
#
# Output:
#   e2e/goldens/gameplay/<mission>/golden.png
#   e2e/goldens/gameplay/<mission>/manifest.json
#
# Exit: 0 if golden staged, 1 if capture failed, 2 if prerequisites missing.

set -euo pipefail

MISSION="${1:?usage: $0 <allied-l1|soviet-l1>}"

case "$MISSION" in
    allied-l1)
        CAPTURE_SCRIPT="wine-allied-l1.sh"
        ARTIFACT_DIR="e2e/report/data/wine-ra-allied-l1"
        SOURCE_FRAME="$ARTIFACT_DIR/frame-0.png"
        ;;
    soviet-l1)
        CAPTURE_SCRIPT="wine-soviet-l1.sh"
        ARTIFACT_DIR="e2e/report/data/wine-ra-soviet-l1"
        SOURCE_FRAME="$ARTIFACT_DIR/frame-0.png"
        ;;
    *)
        echo "FAIL: unknown mission '$MISSION' — expected allied-l1 or soviet-l1" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

GOLDEN_DIR="e2e/goldens/gameplay/$MISSION"
GOLDEN_PNG="$GOLDEN_DIR/golden.png"
MANIFEST="$GOLDEN_DIR/manifest.json"

echo "=== gen-gameplay-goldens: $MISSION ==="
echo "  capture script: $CAPTURE_SCRIPT"
echo "  golden dir:     $GOLDEN_DIR"

# --- Run Wine capture if golden doesn't exist yet --------------------------

if [[ -f "$GOLDEN_PNG" ]]; then
    echo "  golden already exists: $GOLDEN_PNG"
    sz=$(stat -c%s "$GOLDEN_PNG" 2>/dev/null || echo "0")
    if [[ "$sz" -ge 5000 ]]; then
        echo "  golden is valid ($sz bytes >= 5KB) — skipping Wine capture"
    else
        echo "  golden is too small ($sz bytes) — re-capturing..."
        rm -f "$GOLDEN_PNG"
    fi
fi

if [[ ! -f "$GOLDEN_PNG" ]]; then
    echo "  running: bash scripts/$CAPTURE_SCRIPT"
    if ! bash "$SCRIPT_DIR/$CAPTURE_SCRIPT"; then
        echo "FAIL: Wine capture script $CAPTURE_SCRIPT exited non-zero" >&2
        exit 1
    fi

    # Verify the Wine capture produced frame-0.png.
    if [[ ! -f "$SOURCE_FRAME" ]]; then
        echo "FAIL: $CAPTURE_SCRIPT did not produce $SOURCE_FRAME" >&2
        exit 1
    fi
    sz=$(stat -c%s "$SOURCE_FRAME" 2>/dev/null || echo "0")
    if [[ "$sz" -lt 5000 ]]; then
        echo "FAIL: $SOURCE_FRAME too small ($sz bytes, need >=5KB)" >&2
        exit 1
    fi

    # Stage the golden.
    mkdir -p "$GOLDEN_DIR"
    cp "$SOURCE_FRAME" "$GOLDEN_PNG"
    echo "  staged golden: $GOLDEN_PNG ($sz bytes)"
fi

# --- Write manifest.json (single frame) ------------------------------------

cat > "$MANIFEST" <<MANIFEST_EOF
{
  "scene": "$MISSION",
  "mode": "gameplay",
  "total_frames": 1,
  "extracted": [
    {
      "frame_index": 0,
      "frame_label": "frame-0",
      "file": "golden.png"
    }
  ],
  "source": "wine-og",
  "capture_script": "$CAPTURE_SCRIPT"
}
MANIFEST_EOF

echo "  wrote manifest: $MANIFEST"

# Also copy the Wine capture to the wine-gameplay target dir so
# parity-report.sh can find it.
WINE_TARGET_DIR="e2e/screenshots/wine-gameplay/$MISSION"
mkdir -p "$WINE_TARGET_DIR"
cp "$GOLDEN_PNG" "$WINE_TARGET_DIR/capture.png"
echo "  staged wine target: $WINE_TARGET_DIR/capture.png"

echo
echo "PASS: gameplay golden staged for $MISSION"
echo "  golden: $GOLDEN_PNG"
echo "  manifest: $MANIFEST"
exit 0
