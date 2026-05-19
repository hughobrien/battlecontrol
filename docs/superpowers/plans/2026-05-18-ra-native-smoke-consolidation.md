# RA Native Smoke Test Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate `first-run-pass-94.sh`, `T6-ra-native-smoke.sh`, and `T11-ra-native-m2-smoke.sh` into a single `scripts/ra/ra-native-smoke.sh` with three modes (boot/release/m2), remove the stale build step, and clean up references.

**Architecture:** One bash script with mode dispatch via `$1`. Xvfb lifecycle and crash/frame-scan logic are inline functions. The Python analysis block from `first-run-pass-94.sh` runs only in `release` mode for diagnostics. Boot/m2 modes use simple grep analysis.

**Tech Stack:** bash, cmake/nix (build), Xvfb, SDL2

---

### Task 1: Write `scripts/ra/ra-native-smoke.sh`

**Files:**
- Create: `scripts/ra/ra-native-smoke.sh`
- Source material (for extraction): `scripts/first-run-pass-94.sh`, `scripts/ra/regression/T6-ra-native-smoke.sh`, `scripts/ra/regression/T11-ra-native-m2-smoke.sh`

- [ ] **Step 1: Write the consolidated script**

```bash
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
```

**Design notes:**
- The Python block is **diagnostic only** in release mode — pass/fail is decided by the earlier bash-level checks (CRASHES, MAX_FRAME, WINS). This avoids running Python twice and keeps the control flow linear.
- This matches the original first-run-pass-94.sh behavior (which also decided pass/fail in bash before Python, and used Python purely for display).
- The T6-style trap-based Xvfb cleanup is used (cleaner than the original first-run-pass-94.sh manual pkill).

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/ra/ra-native-smoke.sh
```

- [ ] **Step 3: Verify the script is syntactically valid**

```bash
bash -n scripts/ra/ra-native-smoke.sh
```

Expected: no output (exit 0).

---

### Task 2: Remove old scripts and empty directory

**Files:**
- Delete: `scripts/first-run-pass-94.sh`
- Delete: `scripts/ra/regression/T6-ra-native-smoke.sh`
- Delete: `scripts/ra/regression/T11-ra-native-m2-smoke.sh`
- Delete: `scripts/ra/regression/` (empty directory)

- [ ] **Step 1: Delete the three old scripts**

```bash
git rm scripts/first-run-pass-94.sh
git rm scripts/ra/regression/T6-ra-native-smoke.sh
git rm scripts/ra/regression/T11-ra-native-m2-smoke.sh
```

- [ ] **Step 2: Delete the empty regression directory**

```bash
git rm -r scripts/ra/regression/
```

---

### Task 3: Update `scripts/test-runner.sh`

**Files:**
- Modify: `scripts/test-runner.sh` (ra-native dispatch section, lines ~110-116)

- [ ] **Step 1: Replace the ra-native dispatch block**

Change from:

```bash
ra-native)
    run_script scripts/first-run-pass-94.sh
    if [ "$FULL" = true ]; then
        run_script scripts/ra/regression/T6-ra-native-smoke.sh
        run_script scripts/ra/regression/T11-ra-native-m2-smoke.sh
    fi
    ;;
```

To:

```bash
ra-native)
    run_script scripts/ra/ra-native-smoke.sh release
    if [ "$FULL" = true ]; then
        run_script scripts/ra/ra-native-smoke.sh m2
    fi
    ;;
```

---

### Task 4: Update documentation references

**Files (8 files, one step each):**

- [ ] **Step 1: Update `scripts.md`**

Three changes:
1. **Cross-Reference Matrix** (line 18): `scripts/first-run-pass-94.sh` → `scripts/ra/ra-native-smoke.sh`
2. **Flat Alphabetical Index** (line 148): Replace `first-run-pass-94.sh` entry with:
```
| `ra-native-smoke.sh` | script | Test | RA native smoke test (boot/release/m2 modes). |
```
3. **Flat Alphabetical Index**: Remove entries for `T6-ra-native-smoke` and `T11-ra-native-m2-smoke` (they aren't in this index currently, so check first — they may be listed under their full paths or not at all. The current index lists only `first-run-pass-94.sh` under Test, so only that one entry needs replacing.)

Let me recheck: looking at the current alphabetical index, it lists `first-run-pass-94.sh` on line 148. T6/T11 don't appear there (they're under `scripts/ra/regression/` and not in this flat index). So only one entry changes.

- [ ] **Step 2: Update `RELEASE.md`** (line 9)

Change:
```bash
bash scripts/first-run-pass-94.sh
```
To:
```bash
bash scripts/ra/ra-native-smoke.sh release
```

- [ ] **Step 3: Update `README.md`** (line 256)

Change:
```bash
bash scripts/first-run-pass-94.sh
```
To:
```bash
bash scripts/ra/ra-native-smoke.sh release
```

- [ ] **Step 4: Update `CMakeLists.txt`** (line 220)

Change:
```
# Source composition mirrors flake.nix / first-run-pass-94.sh:
```
To:
```
# Source composition mirrors flake.nix / ra-native-smoke.sh:
```

- [ ] **Step 5: Update `docs/smoke-test-design-rule.md`** (audit table, line 77)

The table has one row referencing `scripts/first-run-pass-94.sh (CI)`. Change to `scripts/ra/ra-native-smoke.sh (CI release mode)`.

- [ ] **Step 6: Update `e2e/regression/README.md`**

Three changes:
1. **Test-point table** (shell entries, lines 21-22): Replace the T6-ra-native-smoke row and add an entry for the new consolidated script.
2. **Pass/fail criteria section** (lines 124-127): Replace the T6 native shell text with a description of ra-native-smoke.sh.
3. **Implementation files table** (line 145): Replace the T6 file reference.

Specifically:

In the test-point table, the last two rows change from:
```
| (shell) T5-td-native-menu   | TD native main menu renders           | TD     | native  | yes          | no\*    | 30 s   |
| (shell) T6-ra-native-smoke  | RA native short-run smoke             | RA     | native  | yes          | no\*    | 45 s   |
```
To:
```
| (shell) T5-td-native-menu    | TD native main menu renders          | TD     | native  | yes          | no\*    | 30 s   |
| (shell) ra-native-smoke boot | RA native short-run smoke            | RA     | native  | yes          | no\*    | 45 s   |
```

In the pass/fail criteria section, replace lines 124-127:
```
### (shell) T6-ra-native-smoke — RA native short-run smoke (with RA assets, local)

Runs `build/first-run-pass-94/redalert.elf` for 30 s, asserts ≥100 frames and
no SIGSEGV / Aborted.  Shell: `scripts/ra/regression/T6-ra-native-smoke.sh`.
```
With:
```
### (shell) ra-native-smoke — RA native smoke tests (with RA assets, local)

Consolidated script with three modes (`boot`, `release`, `m2`). CI gate runs
`release` mode: 120 s, ≥1 win, ≥1000 frames, no crash. Script:
`scripts/ra/ra-native-smoke.sh`.
```

In the implementation files table, change the last row from:
```
| (shell) T6-ra-native-smoke  | `scripts/ra/regression/T6-ra-native-smoke.sh`           | Shell      |
```
To:
```
| (shell) ra-native-smoke     | `scripts/ra/ra-native-smoke.sh`           | Shell      |
```

- [ ] **Step 7: Update `skills/ci-cd/SKILL.md`** (reference section, line 317)

Change:
```
- `scripts/first-run-pass-94.sh` — Release-build smoke test (native RA)
```
To:
```
- `scripts/ra/ra-native-smoke.sh` — Release-build smoke test (native RA, release mode)
```

- [ ] **Step 8: Update `docs/superpowers/plans/2026-05-18-dev-cycle-simplification.md`**

Three occurrences to replace (lines 446, 721, 949). Each instance of:
```
scripts/first-run-pass-94.sh
```
Changes to:
```
scripts/ra/ra-native-smoke.sh
```

- [ ] **Step 9: Update `docs/superpowers/specs/2026-05-18-scripts-reorg-design.md`** (line 53)

Change:
```
├── first-run-pass-94.sh         (shared — release smoke test)
```
To:
```
├── ra/ra-native-smoke.sh        (ra — release smoke test)
```

---

### Task 5: Verify

- [ ] **Step 1: Run the script's help output**

```bash
bash scripts/ra/ra-native-smoke.sh --help
```

Expected: prints mode descriptions and exits 0.

- [ ] **Step 2: Run the script in boot mode (if binary is built)**

```bash
bash scripts/ra/ra-native-smoke.sh boot
```

Expected: exit 0 (pass) or exit 77 (skip if no binary/assets). Should not crash or error.

- [ ] **Step 3: Verify old paths are gone**

```bash
ls scripts/first-run-pass-94.sh 2>&1 && echo "FAIL: still exists" || echo "OK: removed"
ls scripts/ra/regression/ 2>&1 && echo "FAIL: still exists" || echo "OK: removed"
```

Expected: both print "No such file or directory" → "OK: removed".

- [ ] **Step 4: Verify no remaining references to old paths in active code**

```bash
grep -r "first-run-pass-94" scripts/ --include="*.sh" --include="*.py" || echo "No remaining references in scripts/"
grep -r "first-run-pass-94" .github/ --include="*.yml" --include="*.yaml" 2>/dev/null || echo "No references in CI configs"
```

Expected: no references in scripts/ or .github/. (The old path `build/first-run-pass-94/` is still referenced as a fallback ELF path in the new script — that's intentional backward compat, not a script reference.)

- [ ] **Step 5: Verify cross-reference matrix in test-runner.sh**

```bash
grep -n "ra-native-smoke" scripts/test-runner.sh
```

Expected: shows two lines (release mode and m2 mode).

---

### Commit

- [ ] **Step: Commit all changes**

```bash
git add \
  scripts/ra/ra-native-smoke.sh \
  scripts/first-run-pass-94.sh \
  scripts/ra/regression/T6-ra-native-smoke.sh \
  scripts/ra/regression/T11-ra-native-m2-smoke.sh \
  scripts/ra/regression/ \
  scripts/test-runner.sh \
  scripts.md \
  RELEASE.md \
  README.md \
  CMakeLists.txt \
  docs/smoke-test-design-rule.md \
  e2e/regression/README.md \
  skills/ci-cd/SKILL.md \
  docs/superpowers/plans/2026-05-18-dev-cycle-simplification.md \
  docs/superpowers/specs/2026-05-18-scripts-reorg-design.md

git commit -m "$(cat <<'EOF'
Consolidate RA native smoke tests into single script with modes

Replace first-run-pass-94.sh, T6-ra-native-smoke.sh, and
T11-ra-native-m2-smoke.sh with scripts/ra/ra-native-smoke.sh
supporting boot/release/m2 modes. Remove the stale manual clang++
build step (handled by build-native.sh/cmake) and clean up regression/
directory. Update all documentation references.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```
