#!/usr/bin/env bash
# ra-native-smoke.sh — RA native Linux smoke test (three modes).
#
# Runs the RA native ELF under Xvfb with RA_AUTOSTART=1 and optional
# RA_SCENE for mission-specific testing.  Acceptance criteria vary by mode.
#
# Modes:
#   boot    (default) — 30 s, >=100 frames, no crash (dev-loop quick check)
#   release           — 120 s, >=1 win, >=1000 frames, no crash, FPS (CI gate)
#   m2                — 120 s, RA_SCENE=SCG02EA.INI, >=200 frames, no crash
#
# Usage:
#   bash scripts/ra/ra-native-smoke.sh          # boot (default)
#   bash scripts/ra/ra-native-smoke.sh release
#   bash scripts/ra/ra-native-smoke.sh m2
#   bash scripts/ra/ra-native-smoke.sh --help   # print usage
#
# Prerequisites:
#   build/ra (or build/first-run-pass-94/redalert.elf) -- RA native binary
#   build/run-172/                                      -- RA assets staged
#
# Exit codes:
#   0   -- all criteria met
#   1   -- one or more criteria failed
#   77  -- skipped (missing binary or assets)
#
# Visual rendering intentionally not covered (see docs/smoke-test-design-rule.md
# for rationale -- WASM smoke tests cover the same C++ renderer).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-boot}"

# ---- Help -------------------------------------------------------------------

if [ "$MODE" = "--help" ]; then
	cat <<EOF
Usage: $(basename "$0") [MODE]

Modes:
  boot     (default)  30s, RA_AUTOSTART=1,  >=100 frames, no crash
  release             120s, RA_AUTOSTART=1,  >=1 win, >=1000 frames, no crash, FPS
  m2                  120s, RA_SCENE=SCG02EA.INI, >=200 frames, no crash
  --help              print this message

Exit codes: 0=pass, 1=fail, 77=skip
EOF
	exit 0
fi

# ---- Mode config ------------------------------------------------------------

case "$MODE" in
boot)
	TIMEOUT=30
	MIN_FRAMES=100
	MIN_WINS=0
	SCENE=""
	;;
release)
	TIMEOUT=120
	MIN_FRAMES=1000
	MIN_WINS=1
	SCENE=""
	;;
m2)
	TIMEOUT=120
	MIN_FRAMES=200
	MIN_WINS=0
	SCENE="SCG02EA.INI"
	;;
*)
	echo "ERROR: unknown mode '$MODE' (valid: boot, release, m2, --help)" >&2
	exit 1
	;;
esac

# ---- ELF resolution ---------------------------------------------------------

ELF="$REPO_ROOT/build/ra"
if [ ! -x "$ELF" ]; then
	ELF="$REPO_ROOT/build/first-run-pass-94/redalert.elf"
fi
if [ ! -x "$ELF" ]; then
	echo "SKIP: no RA native binary found (try: bash scripts/build-native.sh ra)"
	exit 77
fi

RUN_DIR="$REPO_ROOT/build/run-172"
if [ ! -d "$RUN_DIR" ]; then
	echo "SKIP: $RUN_DIR not staged"
	exit 77
fi

OUT_DIR="$REPO_ROOT/e2e/screenshots"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/ra-native-smoke-$MODE.log"

# ---- Xvfb lifecycle --------------------------------------------------------

xvfb_start() {
	pkill -f "Xvfb :99" 2>/dev/null || true
	Xvfb :99 -screen 0 640x480x24 -ac &
	XVFB_PID=$!
	sleep 1
}

xvfb_stop() {
	kill -9 "$XVFB_PID" 2>/dev/null || true
}

# ---- Run --------------------------------------------------------------------

xvfb_start
trap xvfb_stop EXIT

ENV_VARS="DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1"
[ -n "$SCENE" ] && ENV_VARS="$ENV_VARS RA_SCENE=$SCENE"

# shellcheck disable=SC2086 # $ENV_VARS intentionally unquoted for word splitting
(cd "$RUN_DIR" && env $ENV_VARS timeout "$TIMEOUT" "$ELF") >"$LOG" 2>&1
RC=$?

xvfb_stop
trap - EXIT

echo "MODE=$MODE rc=$RC (124=timeout=alive, 0=clean exit)"

# ---- Analysis: common -------------------------------------------------------

CRASHES=$(grep -c -E "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" || true)
MAX_FRAME=$(grep -aE "frame=[0-9]+" "$LOG" | sed -E 's/.*frame=([0-9]+).*/\1/' | sort -n | tail -1)
MAX_FRAME=${MAX_FRAME:-0}
WINS=$(grep -c "\[PLAYER-WINS\]" "$LOG" || true)

PASS=true

if [ "$CRASHES" -gt 0 ]; then
	echo "FAIL: $CRASHES crash signals detected"
	grep -aE "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" | head -3
	PASS=false
fi

if [ "$MAX_FRAME" -lt "$MIN_FRAMES" ]; then
	echo "FAIL: only reached frame=$MAX_FRAME (need >= $MIN_FRAMES)"
	tail -10 "$LOG"
	PASS=false
fi

if [ "$WINS" -lt "$MIN_WINS" ]; then
	echo "FAIL: only $WINS win cycles (need >= $MIN_WINS)"
	PASS=false
fi

# ---- Release-mode extra analysis (FPS diagnostics) -------------------------

if [ "$MODE" = "release" ]; then
	python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

fps_probes = [l for l in lines if '[TIM-316] fps_probe' in l]
wins      = [l for l in lines if '[PLAYER-WINS]' in l]

frame_nums = []
for l in lines:
    m = re.search(r'frame=(\d+)', l)
    if m:
        frame_nums.append(int(m.group(1)))
max_frame = max(frame_nums) if frame_nums else 0

avg_fps = None
last_fps_elapsed_ms = None
last_fps_frames = None
for l in reversed(fps_probes):
    mf = re.search(r'frame=(\d+)', l)
    me = re.search(r'elapsed_ms=(\d+)', l)
    mfps = re.search(r'fps=([\d.]+)', l)
    if mf and me and mfps:
        last_fps_frames = int(mf.group(1))
        last_fps_elapsed_ms = int(me.group(1))
        avg_fps = float(mfps.group(1))
        break

print(f"Win cycles completed:              {len(wins)}")
print(f"Max frame seen in any log line:    {max_frame}")
print(f"FPS probe lines:                   {len(fps_probes)}")
if avg_fps is not None:
    print(f"Last FPS reading:                  {avg_fps:.2f} fps at frame {last_fps_frames} (elapsed {last_fps_elapsed_ms}ms)")

frames_reached_1000 = any(
    int(m.group(1)) >= 1000
    for l in fps_probes
    for m in [re.search(r'frame=(\d+)', l)] if m
)

c1 = len(wins) >= 1
c2 = frames_reached_1000 or max_frame >= 1000
c3 = avg_fps is not None

print(f"Criterion 1 (>=1 win cycle):           {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 (1000+ frames stable):    {'PASS' if c2 else 'FAIL'} (max_frame={max_frame}, fps_probes={len(fps_probes)})")
print(f"Criterion 3 (FPS measured):           {'PASS' if c3 else 'WARN -- no fps_probe lines found'}")

if c1 and c2:
    print("=== ALL CRITERIA MET: PASS ===")
elif not c2:
    print(f"=== FRAME COUNT TOO LOW: only reached max_frame={max_frame} ===")
elif not c1:
    print("=== NO WIN CYCLE: game loop may be stalled ===")
PYEOF
fi

# ---- Result ----------------------------------------------------------------

if [ "$PASS" = true ]; then
	echo "=== PASS ($MODE) ==="
	exit 0
else
	echo "=== FAIL ($MODE) ==="
	exit 1
fi
