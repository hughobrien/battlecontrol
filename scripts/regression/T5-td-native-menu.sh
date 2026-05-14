#!/usr/bin/env bash
# T5 — TD native main menu regression (TIM-623).
#
# Runs the TD native ELF for 5 s under Xvfb :99, captures a screenshot via
# ImageMagick `import` (or ffmpeg x11grab fallback), and asserts the frame
# has non-trivial colour content. Catches native palette regressions and
# TD WIN32-define regressions (TIM-343 class).
#
# Prerequisites:
#   build/td/td               — TD native binary (build with `bash scripts/build-td.sh`)
#   build/run-td/             — staged via `bash scripts/setup-run-td.sh`
#   xvfb, ImageMagick (`import`) or ffmpeg, python3-numpy or python3-PIL
#
# Budget: 30 s. Hard timeout: 60 s.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELF="$REPO_ROOT/build/td/td"
RUN_DIR="$REPO_ROOT/build/run-td"
OUT_DIR="$REPO_ROOT/e2e/screenshots"
SHOT="$OUT_DIR/t5-td-native-menu.png"
LOG="$OUT_DIR/t5-td-native-menu.log"
mkdir -p "$OUT_DIR"

if [ ! -x "$ELF" ]; then
    echo "T5 SKIP: $ELF not built (run \`bash scripts/build-td.sh\`)"
    exit 77
fi
if [ ! -d "$RUN_DIR" ]; then
    echo "T5 SKIP: $RUN_DIR not staged (run \`bash scripts/setup-run-td.sh\`)"
    exit 77
fi

pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

cleanup() {
    pkill -P "$GAME_PID" 2>/dev/null || true
    kill -9 "$GAME_PID"  2>/dev/null || true
    kill -9 "$XVFB_PID"  2>/dev/null || true
}
trap cleanup EXIT

# Boot TD, no autostart. Give the menu 5 s to render.
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 8 "$ELF") > "$LOG" 2>&1 &
GAME_PID=$!
sleep 5

# Capture the X display.
if command -v import >/dev/null 2>&1; then
    DISPLAY=:99 import -window root "$SHOT" 2>>"$LOG"
elif command -v ffmpeg >/dev/null 2>&1; then
    DISPLAY=:99 ffmpeg -loglevel error -y -f x11grab -video_size 640x480 -i :99 -frames:v 1 "$SHOT" 2>>"$LOG"
else
    echo "T5 SKIP: need ImageMagick (\`import\`) or ffmpeg installed"
    exit 77
fi

wait "$GAME_PID" 2>/dev/null
RC=$?
echo "T5 game rc=$RC (124=timeout=alive, 0=clean exit)"

if [ ! -s "$SHOT" ]; then
    echo "T5 FAIL: no screenshot captured"
    exit 1
fi

# Pixel check: non-trivial colour content.
python3 - "$SHOT" <<'PYEOF'
import sys
from pathlib import Path
try:
    from PIL import Image
except ImportError:
    print("T5 SKIP: PIL not installed (apt-get install python3-pil)")
    sys.exit(77)

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
pixels = img.load()
non_black = 0
colors = set()
for y in range(0, h, 4):
    for x in range(0, w, 4):
        r, g, b = pixels[x, y]
        if r > 15 or g > 15 or b > 15:
            non_black += 1
        colors.add(((r >> 3), (g >> 3), (b >> 3)))
total = (h // 4) * (w // 4)
fill = round(non_black / total * 100)
print(f"T5 canvas: {w}x{h} fill={fill}% unique_colors={len(colors)}")
if fill < 10:
    print(f"T5 FAIL: canvas fill {fill}% < 10% — TD native main menu did not render")
    sys.exit(1)
if len(colors) < 8:
    print(f"T5 FAIL: only {len(colors)} unique colours — palette likely broken")
    sys.exit(1)
print("T5 PASS")
PYEOF
RC=$?
exit $RC
