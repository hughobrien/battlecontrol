# Parity Tooling Iteration Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking. Commit coherent tooling improvements separately from diagnostic-only
> probes.

**Goal:** Make RA Wine/native parity debugging faster and more trustworthy by
failing earlier on bad capture state, exposing more comparison points per run,
and collecting enough Wine/native state to explain immediate score/menu failures
instead of treating them as screenshot mysteries.

**Primary blocker:** Later missions such as Allied L3 and several Soviet
missions can route to main-menu/top-scores/score paths before the requested
gameplay frame. The harness must prove whether Wine entered gameplay, whether a
win/loss trigger fired, and what state differed from native.

**Architecture:** Extend the existing `scripts/capture-checkpoint.py` +
`scripts/drivers/*` pipeline. Keep all changes usable from the current one-shot
capture command, then add batch/matrix wrappers once the single-run root of trust
is stronger.

**Tech Stack:** Python 3 standard library, Wine process memory probe
(`tools/wine-input/ra-frameprobe.c`), ImageMagick/Xvfb, existing native
`RA_CAPTURE_*` frame trap.

---

## Task 1: Add Early Screen-State Timeline Classification

**Purpose:** Stop discovering "did not enter gameplay" only after frameprobe
timeout or final screenshot validation.

**Files:**
- Modify: `scripts/drivers/common.py`
- Modify: `scripts/drivers/wine.py`
- Modify: `scripts/capture-checkpoint.py`

- [x] **Step 1: Promote screen classification to a reusable timeline API**

Extend the current `classify_ra_screen(path)` helper with a small structured
state model:

```text
main-menu
briefing-or-dialog
loading
gameplay
score
top-scores
black
unknown
```

Keep the implementation image-based and cheap. It should tolerate screenshots
from `capture_root()` and return metrics already useful in failure reports.

- [x] **Step 2: Poll Wine screen state during mission entry**

In `WineCapture.capture_mission()`, after the RA window appears and before
waiting for the target frame, capture a small timeline:

```text
t=0.0s state=main-menu
t=2.0s state=loading
t=5.0s state=gameplay
```

Write this to `wine-screen-timeline.json` in the session directory. Do not add
expensive polling after gameplay has been confirmed unless an env var enables
it.

- [x] **Step 3: Fail early on impossible states**

If the timeline reaches `top-scores`, `score`, or stable `main-menu` while
strict frameprobe is enabled, fail immediately with the classified state and the
timeline path.

**Done when:**
- Allied L2 records a short `main-menu/loading/gameplay` or direct `gameplay`
  timeline and still captures successfully.
- Allied L3 failure reports whether it ever reached `gameplay` before
  `top-scores`.

**Validation:**

```bash
python3 -m py_compile scripts/drivers/common.py scripts/drivers/wine.py scripts/capture-checkpoint.py
RA_CAPTURE_FPS=10 WINE_FRAMEPROBE=1 WINE_FRAMEPROBE_STRICT=1 \
  python3 scripts/capture-checkpoint.py mission allied-l2 --frame 60 --targets wine --keep 5
RA_CAPTURE_FPS=10 WINE_FRAMEPROBE=1 WINE_FRAMEPROBE_STRICT=1 \
  python3 scripts/capture-checkpoint.py mission allied-l3 --frame 60 --targets wine --keep 5
```

---

## Task 2: Extend Wine State Probe Beyond Frame Counter

**Purpose:** Convert "Wine is at top scores" into actionable state: scenario,
session type, win/loss flags, player house, and player defeat state.

**Files:**
- Modify: `tools/wine-input/ra-frameprobe.c`
- Modify: `scripts/drivers/wine.py`

- [x] **Step 1: Add a `--state`/negative-target mode to `ra-frameprobe`**

Dump a compact JSON-ish line to stderr with known or discovered addresses:

```text
state scenario=SCG03EA.INI frame=1 player_wins=0 player_loses=1 session=GAME_NORMAL player=Greece defeated=1
```

Start with addresses already used by source/disassembly when known. If an
address is unknown, emit `unknown` rather than guessing.

- [x] **Step 2: Call the state probe on every frameprobe failure**

When Wine strict frameprobe fails, run the state probe before teardown and write:

```text
wine-state.txt
```

Include state in the manifest failure object.

- [x] **Step 3: Add a state-only command path**

Allow:

```bash
python3 scripts/capture-checkpoint.py mission allied-l3 --targets wine --state-only
```

This should launch Wine, wait for first non-loading state, dump Wine state, and
exit without native capture or comparison.

**Done when:**
- Allied L3 failure includes at least `scenario`, `frame`, `PlayerWins`,
  `PlayerLoses`, and `Session.Type` or explicitly marks each missing value
  unknown.
- The state dump runs in under 20 seconds for a failing mission.

---

## Task 3: Add Native/Wine Trigger and Outcome Trace

**Purpose:** Identify the exact trigger/action that sends a mission to win/loss
or score.

**Files:**
- Modify: native source around trigger evaluation and win/loss handling
  (`REDALERT/TRIGGER*.CPP`, `REDALERT/CONQUER.CPP`, `REDALERT/SCENARIO.CPP`;
  exact files to confirm with `rg "PlayerWins|PlayerLoses|Trigger"`).
- Modify: `tools/wine-input/ra-frameprobe.c` only if comparable Wine state can
  be read safely.

- [ ] **Step 1: Add native trigger trace behind env var**

Add `RA_TRACE_TRIGGERS=1` logging:

```text
[RA_TRIGGER] frame=1 name=lose event=... action=LOSE source=...
```

Keep this diagnostic-only unless it proves broadly useful; do not commit noisy
trace code unless gated and low-risk.

- [ ] **Step 2: Add native outcome trace**

Log transitions of `PlayerWins`, `PlayerLoses`, and `PlayerPtr->IsDefeated`
with frame and scenario.

- [ ] **Step 3: Correlate with Wine**

Use Wine state probe plus screenshots first. If needed, add a Wine memory scan
for trigger arrays only after native tells us what to look for.

**Done when:**
- Native Allied L3 shows whether any loss trigger fires in the first 10 frames.
- Wine Allied L3 state indicates whether the same outcome flag has fired.

---

## Task 4: Implement First-N-Frames Capture Strips

**Purpose:** Expose instant vs progressive divergence without manually running
many commands.

**Files:**
- Add: `scripts/capture-strip.py`
- Modify only if needed: `scripts/capture-checkpoint.py`

- [ ] **Step 1: Add wrapper command**

Support:

```bash
python3 scripts/capture-strip.py mission allied-l2 --frames 1,2,5,10,20,30,60 --targets wine,native
```

Each frame should call `capture-checkpoint.py` with `--keep` and collect child
session paths.

- [ ] **Step 2: Produce summary JSON**

Write `strip-report.json` containing:

```json
{
  "mission": "allied-l2",
  "frames": [
    {"requested": 1, "wine_actual": 1, "native_actual": 1, "ssim": 0.99, "state": "gameplay"}
  ]
}
```

- [ ] **Step 3: Produce contact sheet**

Create one PNG contact sheet per target and one diff contact sheet if image
tools are available. If not, emit paths and keep JSON mandatory.

**Done when:**
- Allied L2 strip completes and shows high SSIM at several frames.
- Allied L3 strip stops at the first bad state and still writes a useful report.

---

## Task 5: Implement Mission Matrix Runner

**Purpose:** Make campaign-wide pattern finding cheap.

**Files:**
- Add: `scripts/capture-matrix.py`

- [ ] **Step 1: Add mission/frame/target expansion**

Support forms:

```bash
python3 scripts/capture-matrix.py --missions allied-l1..l5,soviet-l1..l5 --frames 1,10,60 --targets wine,native
```

- [ ] **Step 2: Sort failures by reason**

Group results by:

```text
pass
wine-main-menu
wine-top-scores
wine-score
wine-frame-timeout
native-failed
comparison-failed
```

- [ ] **Step 3: Emit human and machine reports**

Write `matrix-report.md` and `matrix-report.json` into a timestamped
`/tmp/battlecontrol/<timestamp>-matrix/` directory.

**Done when:**
- L1-L5 Allied/Soviet can be sampled without manual command editing.
- The report immediately shows which missions fail before gameplay vs renderer
  divergence.

---

## Task 6: Prefer Native Internal BMP/PNG Capture

**Purpose:** Remove X root/ImageMagick flakiness from native captures.

**Files:**
- Modify: `scripts/drivers/native.py`
- Inspect first: `REDALERT/WIN32LIB/DDRAW.CPP`, `REDALERT/CONQUER.CPP`
- Modify only if needed: native capture trap implementation in the file found
  by `rg "RA_CAPTURE_BMP_FILE|native-ready|RA_CAPTURE_FRAME"`

- [ ] **Step 1: Verify `RA_CAPTURE_BMP_FILE` content**

The native driver currently waits for `native-ready.txt` but still captures the
X root. Make the driver prefer `capture.bmp` when it is non-empty and valid.

- [ ] **Step 2: Convert BMP to PNG deterministically**

Use ImageMagick only for file conversion, not screen capture:

```bash
convert capture.bmp capture.png
```

If conversion is unavailable or BMP is empty, fall back to root capture with a
warning.

- [ ] **Step 3: Assert dimensions and pixel range**

Reject empty/blank internal captures with the same smoke-test design rule as
screenshots.

**Done when:**
- Native captures no longer need `import -window root` on successful internal
  frame-trap runs.
- A full Allied L2 Wine/native comparison still passes.

---

## Task 7: Add Disk and Environment Guardrails

**Purpose:** Prevent repeated loss of time to stale X locks, orphan capture
processes, and `/tmp/wine-audio.raw` filling the filesystem.

**Files:**
- Modify: `scripts/drivers/common.py`
- Modify: `scripts/capture-checkpoint.py`
- Modify: `scripts/sweep-state.py`

- [x] **Step 1: Preflight free-space check**

Before capture starts, check `/tmp` free space. Default minimum: 1 GiB.
Override with `RA_MIN_TMP_FREE_MB`.

- [x] **Step 2: Sweep known artifacts safely**

For single checkpoint captures, only remove known safe single-file artifacts
such as `/tmp/wine-audio.raw` before launch. Keep broad `sweep_state()` cleanup
manual via `scripts/sweep-state.py`; future matrix/strip batch commands should
call it before long runs.

- [x] **Step 3: Make Nix env issues explicit**

If `Xvfb`, `openbox`, `import`, `xdpyinfo`, `xdotool`, or Wine setup is
missing, report the missing tool or `WINE_BIN` problem and whether
`$IN_NIX_SHELL` is set.

**Done when:**
- Filling `/tmp/wine-audio.raw` cannot cause a misleading ImageMagick write
  failure.
- Missing Nix PATH reports an actionable preflight failure.

---

## Task 8: Write Per-Run Patch Manifest

**Purpose:** Make Wine patch state auditable from the session directory.

**Files:**
- Modify: `scripts/drivers/wine.py`
- Modify: RA patch scripts as needed to support machine-readable output

- [ ] **Step 1: Capture patch stdout/stderr into manifest data**

For each patch script record:

```json
{
  "script": "ra-autostart-patch.py",
  "rc": 0,
  "applied": ["0x004FD4FE", "0x004FDC67"],
  "sha256_after": "..."
}
```

- [ ] **Step 2: Record side/CD/scenario decisions**

Write `wine-patches.json` with:

```json
{
  "scenario": "SCG03EA",
  "side": "allied",
  "cd_label_mode": "cd1",
  "boot_dismiss": false
}
```

- [ ] **Step 3: Include patch manifest link in failure output**

When capture fails, print the session path and mention `wine-patches.json`.

**Done when:**
- A failed Allied L3 session can prove exactly which RA95 bytes were patched.

---

## Task 9: Add Region-Level Comparison Reports

**Purpose:** Replace one global SSIM with targeted signals for UI/map/shroud.

**Files:**
- Modify: `scripts/drivers/compare.py` or add a helper used by it

- [ ] **Step 1: Define stable regions**

At minimum:

```text
top_message_bar
timer_credit_tab
tactical_viewport
sidebar_buttons
radar_panel
full_frame
```

- [ ] **Step 2: Report per-region SSIM/p99**

Add a `regions` object to `report.json` and print the worst regions in CLI
output.

- [ ] **Step 3: Save region diffs on failure**

Crop and save `diff-region-<name>-wine-vs-native.png` for the worst N regions.

**Done when:**
- Allied L2 reports that remaining differences are localized and not hidden by
  the full-frame score.

---

## Task 10: Add Source-History Helper for Porting Regressions

**Purpose:** Quickly surface suspect porting commits for files touched during an
investigation.

**Files:**
- Add: `scripts/port-history.py`

- [ ] **Step 1: Show concise file history**

For each path:

```bash
python3 scripts/port-history.py REDALERT/MAP.CPP REDALERT/SCENARIO.CPP
```

Run `git log --follow --stat -- <file>` and show commit subjects, dates, and
changed function hints if available.

- [ ] **Step 2: Highlight likely porting commits**

Flag commits whose subject/body includes:

```text
LP64
port
stub
Linux
WASM
timing
render
portable
```

- [ ] **Step 3: Keep it read-only**

This helper must not mutate the worktree.

**Done when:**
- An investigator can ask for history on a suspect file without manually
  scanning the full log.

---

## Recommended Execution Order

1. **Task 7:** Disk/env guardrails. This prevents wasted runs immediately.
2. **Task 1:** Screen-state timeline. This makes every failure more legible.
3. **Task 2:** Wine state probe. This attacks the Allied L3/Soviet score path.
4. **Task 3:** Trigger/outcome trace. This identifies the actual loss/win cause.
5. **Task 6:** Native internal capture. This removes one flaky dependency.
6. **Task 4:** First-N-frame strips. This exposes more comparison points.
7. **Task 5:** Mission matrix. This scales the investigation.
8. **Task 8:** Patch manifest. This improves auditability for all Wine runs.
9. **Task 9:** Region reports. This improves renderer-diff triage.
10. **Task 10:** Port history helper. This speeds code archaeology.

## Commit Strategy

- Commit durable tooling improvements.
- Do not commit noisy one-off instrumentation unless it is gated by an env var
  and useful beyond the current bug.
- Keep unrelated dirty RA source diagnostics out of tooling commits.
- Stage explicit files only; never use `git add -A`.

## Regression Gate

Run before committing each coherent tooling change:

```bash
python3 -m py_compile scripts/capture-checkpoint.py scripts/drivers/*.py
python3 scripts/sweep-state.py
RA_CAPTURE_FPS=10 WINE_FRAMEPROBE=1 WINE_FRAMEPROBE_STRICT=1 \
  python3 scripts/capture-checkpoint.py mission allied-l2 --frame 60 --targets wine,native --keep 5
```

Run before pushing a tooling batch:

```bash
nix run .#test
```
