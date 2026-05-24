# Parity Root-of-Trust Working Log

Date: 2026-05-21

Purpose: preserve the active debugging thread for Wine/native reproducibility and
frame alignment across context compaction.

## Goal

The immediate gold standard is:

1. Capture 100 reproducible frames from Wine.
2. Capture the corresponding reproducible frames from native.
3. Once each side is internally reproducible, diff them to find the real engine
   or renderer divergence.

## Current State

- Wine now has a cnc-ddraw root-of-trust capture path under active development.
- Native already has an internal frame trap and produces byte-identical output
  for repeated runs at a fixed requested frame.
- The old Wine process-memory frameprobe plus X11/BitBlt screenshot path could
  be stable on Allied L2, but Allied L1 still drifted across Wine runs. That
  made it unsuitable as the sole root of trust.
- As of the 23:47 UTC run, Wine can produce a reproducible 100-frame Allied L1
  sequence when captures are keyed to RA95's internal frame counter, captured
  through cnc-ddraw's GDI render loop, run at 60 FPS, and started after the
  initial mission-entry instability window.

## Files Touched In This Pass

- `tools/cnc-ddraw/tim780-capture-hook.patch`
  - Adds `ss_take_screenshot_file()`.
  - Adds env-gated capture hooks.
  - Primary `Flip` hook exists, but RA95 did not hit it in the current GDI path.
  - GDI render-loop hook does fire and dumps the actual displayed primary
    surface.
- `flake.nix`
  - Applies `tim780-capture-hook.patch` after `tim740-scanline-double.patch`.
- `scripts/drivers/wine.py`
  - Adds `WINE_CNCDDRAW_CAPTURE=1`.
  - Adds `WINE_CNCDDRAW_CAPTURE_FLIP=N`.
  - Writes `BC_CAPTURE_FLIP`, `BC_CAPTURE_FILE`, `BC_CAPTURE_HALT`, and
    `BC_CAPTURE_RA_FRAME_ADDR` into the Wine process environment.
  - Waits for `wine-cncddraw.png` and returns it as the Wine capture.
- `scripts/capture-checkpoint.py`
  - Wine mission data dir now falls back through `WINE_DATA_DIR`, `DATA_DIR`,
    then `RA_ASSETS`.
- `scripts/capture-wine-sequence.py`
  - Captures Wine render-loop sequences with cnc-ddraw.
  - Defaults to `--fps 60` and `--clock ra`.
  - Emits `wine-sequence-report.json` with byte and decoded-RGBA hashes.
- `scripts/test_cncddraw_capture_hook.py`
  - Contract test for the cnc-ddraw hook and driver wiring.
- `scripts/test_capture_checkpoint_seed.py`
  - Extended to cover Wine data-dir fallback behavior.
- `divergences.md`
  - Updated with the root-of-trust and frame-alignment observations.

## Verification So Far

Commands run successfully:

```bash
python3 scripts/test_capture_checkpoint_seed.py
python3 scripts/test_cncddraw_capture_hook.py
python3 -m py_compile scripts/drivers/wine.py scripts/capture-wine-sequence.py
nix build .#cnc-ddraw --impure --print-out-paths
```

The local cnc-ddraw patch is now zero-context enough to pass `git diff --check`
while still applying cleanly after `tim740-scanline-double.patch`.

## Important Artifacts

Wine render-frame 50, Allied L1, cnc-ddraw GDI render-loop capture:

- `/tmp/battlecontrol/2026-05-21T22-55-47-mission-allied-l1/wine.png`
- `/tmp/battlecontrol/2026-05-21T22-56-34-mission-allied-l1/wine.png`

These two are byte-identical:

- `sha256=f88994da288231728f9fba7fad2dc66d264d039ec60f62c4dbfb6bf47943d365`

Native Allied L1 frame 50:

- `/tmp/battlecontrol/2026-05-21T22-57-23-mission-allied-l1/native.png`
- `/tmp/battlecontrol/2026-05-21T22-57-40-mission-allied-l1/native.png`

These two are byte-identical:

- `sha256=b2f9f09e5c1519348011565b597a576372bca51264931516d695bf3d0371c4a6`

Wine render-frame 50 with RA95 frame-counter log:

- `/tmp/battlecontrol/2026-05-21T23-08-46-mission-allied-l1`
- Driver log line:
  `bc-capture: render_frame=50 ra_frame=91 file=... result=ok`

Native alignment sweep against that Wine PNG:

- `/tmp/battlecontrol/native-align-raframe91-20260521T230940Z`
- Native frames 88-92: about `SSIM=0.465`, `p99=228`.
- Native frame 93: best observed nearby match, `SSIM=0.9786`, `p99=112`.
- Native frames 94-96: still high, gradually lower.

Interpretation: Wine render-frame 50 corresponds visually to roughly native
presented frame 93, even though the Wine memory counter read at the render dump
is `91`. This is likely a counter/present boundary offset, not random drift.

Wine sequence experiments:

- Render-clock sequence, start 1, count 100, 10 FPS:
  `/tmp/battlecontrol/2026-05-21T23-22-58-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-23-44-wine-sequence-allied-l1`.
  Result: complete, but not a stable frame corpus. The 8-bit framebuffer index
  data was stable for all frames, but RGB palette/fade timing and logged RA
  frame values drifted. Render-loop ordinal is not the right multi-frame clock.
- RA-clock sequence, start 1, count 100, 60 FPS:
  `/tmp/battlecontrol/2026-05-21T23-35-16-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-35-57-wine-sequence-allied-l1`.
  Result: both captured RA frame IDs `1..100`; one visual mismatch at RA frame
  `31`, captured on render-loop frame `70` in one run and `71` in the other.
  This points at mission-entry/palette/present-boundary instability.
- RA-clock sequence, start 50, count 100, 60 FPS:
  `/tmp/battlecontrol/2026-05-21T23-36-58-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-47-13-wine-sequence-allied-l1`.
  Result: complete, identical RA frame IDs `50..149`, and all 100 PNGs are
  byte-identical. This is the current Wine root-of-trust corpus.

## Current Hypotheses

1. The prior Allied L1 Wine nondeterminism was at least partly a screenshot
   timing/root-of-trust issue. The cnc-ddraw render-loop PNGs are byte-stable.
2. The RA95 memory counter at `0x006544c8` is useful but not exactly identical
   to native's capture trap boundary. For Allied L1 render-frame 50 it reads
   `91`, while the closest native visual match is frame `93`.
3. Render-loop ordinal is not a good long-sequence clock. RA-clock capture at
   60 FPS is much more stable, and starting at RA frame 50 avoids mission-entry
   instability for Allied L1.
4. The remaining Wine/native mismatch after alignment is likely a real rendering
   or state divergence, but we should not chase it until we can compare stable
   frame sequences.

## Next Steps

1. Replace or supplement the native sequence wrapper with an in-process native
   sequence dumper. The initial wrapper works but boots once per frame, so 100
   frames would be unnecessarily slow.
2. Run native sequence twice and verify every frame is byte-identical.
3. Build an alignment/comparison report for Wine frame IDs `50..149` versus
   native frame IDs in the same range and nearby offsets.
4. Once both corpora are stable, resume D4/shroud and other visual divergence
   work against stable, aligned frame pairs.

## Useful Invocation

Single Wine cnc-ddraw capture:

```bash
WINE_CNCDDRAW_CAPTURE=1 \
WINE_CNCDDRAW_CAPTURE_FLIP=50 \
WINE_CNCDDRAW_CAPTURE_TIMEOUT=60 \
RA_CAPTURE_FPS=10 \
RA_RANDOM_SEED=0x1eed5eed \
python3 scripts/capture-checkpoint.py mission allied-l1 \
  --frame 50 --targets wine --threshold-ssim 0.90
```

Paired Wine/native capture, currently not aligned by itself:

```bash
WINE_CNCDDRAW_CAPTURE=1 \
WINE_CNCDDRAW_CAPTURE_FLIP=50 \
WINE_CNCDDRAW_CAPTURE_TIMEOUT=60 \
RA_CAPTURE_FPS=10 \
RA_RANDOM_SEED=0x1eed5eed \
python3 scripts/capture-checkpoint.py mission allied-l1 \
  --frame 50 --targets wine,native --threshold-ssim 0.90
```

Current Wine sequence root-of-trust invocation:

```bash
python3 scripts/capture-wine-sequence.py allied-l1 \
  --clock ra --start 50 --count 100 --timeout 180
```

Initial native sequence harness:

- Script: `scripts/capture-native-sequence.py`
- Default: Allied/native RA-clock frames start at 50, 60 FPS, fixed seed.
- Implementation note: this first version wraps the existing native frame trap
  and launches one native process per requested frame. It is good enough to
  prove semantics, but too slow as the final 100-frame loop.
- Smoke run A: `/tmp/battlecontrol/2026-05-21T23-55-09-native-sequence-allied-l1`
- Smoke run B: `/tmp/battlecontrol/2026-05-21T23-55-39-native-sequence-allied-l1`
- Result: frames `50..52` are complete and byte-identical across both runs.

In-process native sequence harness:

- Native source now supports `RA_CAPTURE_SEQUENCE_DIR`,
  `RA_CAPTURE_SEQUENCE_START`, `RA_CAPTURE_SEQUENCE_COUNT`, and
  `RA_CAPTURE_SEQUENCE_READY_FILE`. The driver launches one native process,
  dumps BMPs after `Map.Render()`, then converts the sequence to PNG.
- First 100-frame attempt exposed native-only nondeterminism: 22/100 frame
  hashes differed across two runs, but every mismatch was exactly 141 pixels
  in a small water/palette-cycling rectangle `(104,187)-(176,254)`.
- Root cause: `Color_Cycle()` uses `CDTimerClass<SystemTimerClass>`, so water
  palette rotation can land on adjacent game frames depending on scheduler
  timing even when the capture itself is frame-indexed.
- Capture-mode fix: sequence capture uses frame-derived palette cycling for
  pulse/ember/water colours. Normal gameplay remains on the original
  `SystemTimerClass` timers.
- Verified native root-of-trust:
  `/tmp/battlecontrol/2026-05-22T00-19-08-native-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-22T00-19-42-native-sequence-allied-l1`.
  Result: complete, 100/100 RGBA hashes match for frames `50..149`.
- Re-verified from a clean temporary worktree with only the staged patch:
  `/tmp/battlecontrol/2026-05-22T00-26-44-native-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-22T00-27-18-native-sequence-allied-l1`.
  Result: complete, 100/100 RGBA hashes match for frames `50..149`.
- First Wine/native corpus alignment check used Wine
  `/tmp/battlecontrol/2026-05-21T23-36-58-wine-sequence-allied-l1` and native
  `/tmp/battlecontrol/2026-05-22T00-27-18-native-sequence-allied-l1`.
  Comparing Wine frames `60..139` against native offsets `-10..+10` shows
  native `wine+2` is the best alignment (`avg_luma_delta=1.86`, down from
  `3.13` at offset `0`). Browse representative aligned pairs and amplified
  diffs at `/tmp/battlecontrol/sequence-compare-wine50-native52`.

Alignment blockers as of 2026-05-22:

- The capture root of trust is stable, but the Wine and native frame labels are
  still not exactly the same semantic boundary. Wine is captured at cnc-ddraw
  present/RA-clock territory; native is dumped after `Map.Render()`.
- A fixed seed only controls PRNG-derived gameplay state. It does not by itself
  force palette-cycle phase, callback count before mission entry, or any
  timer-derived UI/render state to match.
- Native sequence capture now removes the known native real-time
  `Color_Cycle()` nondeterminism. Wine may still have stable-but-different
  timer phase relative to native.
- Therefore the next goal is not "make offset zero"; it is to prove both sides
  represent the same simulation/render boundary and then treat residual aligned
  pixel clusters as real rendering/state divergences.

Incremental tooling improvement:

- Added `scripts/compare-frame-sequences.py` and
  `scripts/test_compare_frame_sequences.py`.
- The tool accepts sequence dirs or `*-sequence-report.json` files, sweeps frame
  offsets, writes `sequence-alignment-report.json`, and emits amplified sample
  diffs for the best offset.
- Current run:
  `python3 scripts/compare-frame-sequences.py --a /tmp/battlecontrol/2026-05-21T23-36-58-wine-sequence-allied-l1/wine-sequence-report.json --b /tmp/battlecontrol/2026-05-22T00-27-18-native-sequence-allied-l1/native-sequence-report.json --offset-min -10 --offset-max 10 --out /tmp/battlecontrol/sequence-align-wine-native-20260522 --sample-frames 50,60,70,90,120,140`
- Result: best offset remains native `wine+2`, now across all overlapping
  frames (`98` comparisons at offset `+2`). `avg_luma_delta=1.7666` and
  `avg_diff_pixels=7264.2`, versus offset `0` at `avg_luma_delta=2.8486` and
  `avg_diff_pixels=9149.4`.
- Runtime after caching/C-backed stats: about 5.7 seconds for offsets `-10..+10`
  over the 100-frame corpora.

MinGW-under-Wine probe update, 2026-05-22:

- Added `capture-checkpoint.py --targets mingw` as a classified probe for the
  ported Win32 executable (`build-mingw32/ra.exe`) running under Wine.
- Initial state after SDL3 runtime staging was fixed: `MAIN.MIX` decoded as the
  wrong header and `LOCAL.MIX` produced implausible metadata
  (`count=89 size=-1`) before `std::bad_alloc`.
- Root cause: the MinGW build uses the shared POSIX file-I/O substrate, and
  MinGW's `open()` defaults to text mode. Binary MIX reads stopped at `0x1A`
  bytes, so encrypted headers and cached MIX bodies were truncated.
- Fix: force `O_BINARY` in `linux/win32-stubs/posix_fileio.cpp` for all
  translated `CreateFileA` opens. This is a real portability fix, not a render
  workaround.
- Verification: `/tmp/battlecontrol/2026-05-22T20-59-35-mission-allied-l2`
  reached `Start_Scenario OK`, skipped Allied L2 VQAs under `RA_AUTOSTART`,
  decoded `LOCAL.MIX` as `count=66 size=3828933`, cached it fully, and advanced
  through main-loop frame 300.
- Frame-trap verification:
  `/tmp/battlecontrol/2026-05-22T21-03-22-mission-allied-l2` captured Allied L2
  frame 60 through `RA_CAPTURE_FRAME` / `RA_CAPTURE_BMP_FILE`, not through a
  root-window timing screenshot.
- The frame is currently grayscale/low-colour (`35c`). Treat that as a real
  MinGW/Wine port divergence to investigate, not as capture failure; the MinGW
  validator accepts lower colour count while preserving dimension/range checks.
- The MinGW target is now useful as a Wine-hosted ported-engine comparison
  point. The next step is repeated-frame reproducibility, then sequence capture.

MinGW palette/default-options root cause, 2026-05-22:

- Symptom: MinGW-under-Wine reached exact gameplay frame traps, but Allied L2
  frame 500 was almost entirely grayscale/low-colour while native was full
  colour. The internal SDL palette sample differed too, so this was not a PNG
  conversion or X screenshot artifact:
  - native: `pal[1]=168,0,164`, `pal[128]=236,236,236`;
  - MinGW before fix: `pal[1]=124,124,124`, `pal[128]=164,164,164`.
- Diagnostic assertion: temporary option logging showed MinGW loaded
  `Bright=0 Sat=0 Tint=0 Contrast=0`, while native loaded
  `Bright=128 Sat=128 Tint=128 Contrast=128`.
- Root cause: `OptionsClass` was a global object whose constructor initialized
  palette defaults from dynamically initialized `fixed::_1_2`. Under MinGW link
  order, `Options` was constructed before the `fixed` constants in
  `FIXED.CPP`, so those defaults were zero. The same static-initialization-order
  hazard existed in `RulesClass` defaults that used `fixed::_1_2`,
  `fixed::_1_4`, and `fixed::_3_4`.
- Fix: global constructors now use direct `fixed(n, d)` construction for those
  defaults instead of cross-translation-unit `fixed::` constants. Runtime uses
  of the constants remain fine because they occur after static initialization.
- Verification:
  `/tmp/battlecontrol/2026-05-22T21-35-54-mission-allied-l2` with diagnostics
  proved MinGW and native both load `Bright/Sat/Tint/Contrast=128` and both
  have matching frame-500 palette samples. Clean rerun without diagnostics:
  `/tmp/battlecontrol/2026-05-22T21-38-23-mission-allied-l2`, native vs MinGW
  `SSIM=1.0000`, `p99=0`, all reported regions pixel-exact.

Frame-500 root-of-trust tooling cleanup, 2026-05-22:

- Wine RA95 frameprobe failure at frame 500 was a tooling timeout, not a
  counter/proc-read failure. The log showed the proc frame counter advancing
  monotonically from the 90s to about 300 before the fixed poll budget expired.
- Fix: `scripts/drivers/wine.py` now derives the proc-frameprobe poll budget
  from target-frame delta and `RA_CAPTURE_FPS`, with
  `RA_FRAMEPROBE_MAX_POLLS` as a floor. It also logs the computed interval and
  budget so future failures are explainable.
- MinGW target failure in the first three-way frame-500 run was another fixed
  wait-budget problem. At high requested FPS values the native timeout helper
  could underbudget a Wine-hosted MinGW run, even though MinGW was healthy and
  eventually reached the frame trap.
- Fix: `scripts/drivers/mingw.py` now caps the timeout calculation at 10 FPS
  for MinGW-under-Wine and logs requested FPS, budget FPS, and timeout. An
  attempted per-run Wine prefix made Wine initialization slower and was removed;
  the useful fix is the budget/logging change.
- Verification: `/tmp/battlecontrol/2026-05-22T22-50-22-mission-allied-l2`
  captured Allied L2 frame 500 for Wine RA95, native Linux, and MinGW-under-Wine.
  Results: wine-vs-native `SSIM=0.9870 p99=48`, wine-vs-mingw
  `SSIM=0.9870 p99=48`, and native-vs-mingw `SSIM=1.0000 p99=0`.
  That proves the ported engine is pixel-exact across native Linux and
  Win32-under-Wine at this checkpoint; the remaining frame-500 delta is against
  original RA95 only.

Mouse-force divergence, 2026-05-22:

- A controlled pointer rerun exposed a real port/source divergence. Moving the
  X pointer to `(240,350)` made RA95/Wine show the expected hover text
  `Unrevealed Terrain`, but native/MinGW still showed the sidebar/build hover
  `Power Plant $300`.
- Root cause: `Get_Mouse_X()`/`Get_Mouse_Y()` in `WIN32LIB/MOUSEWW.CPP` return
  `DLLForceMouseX/Y` whenever those globals are non-negative. The Remastered
  source initialized both globals to `0`, so standalone ports were born with
  forced logical mouse coordinates instead of using the real mouse. This came
  from the initial source import, not from a recent local porting patch.
- Fix: initialize `DLLForceMouseX/Y` to `-1` in both RA and TD
  `DLLInterface.cpp`. DLL/GlyphX entry points that intentionally force mouse
  coordinates still assign non-negative values explicitly.
- Driver improvement: `scripts/drivers/common.py::center_mouse()` now accepts
  `BC_CAPTURE_MOUSE_X/Y`, so parity captures can put the pointer at a deliberate
  non-scroll location instead of always using screen center. Native/MinGW drivers
  also pass those coordinates through as `RA_CAPTURE_MOUSE_X/Y`, which forces
  logical mouse reads during capture runs without changing default gameplay.
- Verification after rebuild:
  `/tmp/battlecontrol/2026-05-22T23-03-47-mission-allied-l2` with
  `BC_CAPTURE_MOUSE_X=240 BC_CAPTURE_MOUSE_Y=350` removed the native/MinGW
  `Power Plant $300` hover. The frame-500 comparison improved from the pre-fix
  cursor-controlled run (`SSIM=0.9804 p99=108`) to `SSIM=0.9867 p99=32`, while
  native-vs-MinGW remained pixel-exact.
- Additional alignment check: comparing RA95 frame 500 against native frame 544
  after the mouse fix gives `SSIM=0.9883 p99=16`. Remaining visible differences
  are now dominated by RA95's cursor/tooltip final-present capture and moving
  unit animation phase. `RA_CAPTURE_MOUSE_X/Y` is applied (confirmed in logs),
  but the native internal BMP trap still captures before the same cursor/tooltip
  final-present phase that cnc-ddraw sees from RA95. The next reduction target is
  therefore capture phase/clock alignment rather than the fixed forced-mouse bug.

Phase-clock pass, 2026-05-23:

- Added native phase metadata to capture logs/reports:
  `[RA_CAPTURE_PRESENT]` now records `game_frame`, `present_before`, and
  `present_frame`; `capture-native-sequence.py` parses those fields into
  `native-sequence-report.json`.
- Found and fixed a real SDL port clock bug. `WWKeyboardClass::Check()` called
  `Fill_Buffer_From_System()`, and the Linux implementation had been changed to
  call `Wait_Vert_Blank()`. Since `Wait_Vert_Blank()` also presents the SDL
  framebuffer, normal gameplay input polling could present twice per game loop.
  Root cause history: this came from TIM-149/TIM-172 SDL input/menu bring-up,
  not the original Westwood code.
- Fix: split event pumping from presentation. `DDRAW.CPP` now exposes
  `SDL_Process_System_Events()` for keyboard polling; `KEY.CPP` calls that
  instead of `Wait_Vert_Blank()`. The real present call moved to
  `GScreenClass::Blit_Display()`, the HidPage-to-SeenBuff display boundary.
- Capture tooling adjustment: after-render native sequence capture is active
  again so game frames that do not redraw still write the last visible
  framebuffer. Present metadata remains sparse on purpose; it tells us which
  game frames actually presented.
- Verification: after the input/present split, native present-bearing frames in
  Allied L2 have stable `present_frame == Frame` in the 450-549 sequence.
  Native RA and MinGW RA both build with the change.

Message-list timer divergence, 2026-05-23:

- The phase-clock fix did not by itself collapse the visual offset: Wine frame
  500 still looked closer to native frame 544 than native frame 500. The clearest
  visible symptom was the mission instruction text lifetime.
- Root cause: `REDALERT/MSGLIST.CPP` had been changed on 2026-05-19
  (`7caa2174`, "fix ra allied mission parity rendering") so non-MSVC in-game
  message expiry used global `Frame`, while the original Win32 code uses
  `TickCount`. That made native message lifetime frame-based and diverged from
  RA95's wall/system tick behavior.
- Fix: keep the native message list enabled, but make `RA_Message_Timeout_Clock`
  return `TickCount` on all builds, matching the original code's expiry basis.
- Verification: using the existing Wine Allied L2 sequence
  `/tmp/battlecontrol/2026-05-23T04-29-45-wine-sequence-allied-l2`, native frame
  500 after the `TickCount` fix compares to Wine frame 500 at `SSIM=0.9883`,
  `p99=12`. Before this fix, same-frame native was `p99=52-56`, and the best
  visual match was native frame 544 at `p99=16`.
- Remaining lead: frame 475 still has a larger transient delta (`p99=60`), and
  the broad sequence offset metric still drifts toward later native frames due
  static terrain plus moving-unit noise. Treat that as evidence for at least one
  more timer/animation phase divergence, not as proof the global frame clock is
  wrong.

Wine frame-candidate tooling, 2026-05-23:

- `tools/wine-input/ra-frameprobe.c --state` now prints the candidate frame
  counter values listed in `scripts/drivers/wine.py`. A guarded
  `WINE_STATE_AFTER_CAPTURE_FRAME=1` mode in `scripts/drivers/wine.py` can dump
  that state after a successful screenshot without turning normal captures into
  failures.
- Diagnostic result near Allied L2 frame 500: `0x006544c8` remains the only
  plausible Wine frame counter among the current candidates. The post-capture
  sample advanced to ~532 because the state probe runs after screenshot capture;
  use it for candidate validation, not as the sampled image's exact frame.

Source-level unit drift, 2026-05-23:

- MinGW port under Wine matched Linux native pixel-for-pixel at Allied L2 frame
  400, while both differed from RA95. That rules out Linux/SDL capture timing as
  the main cause of the convoy/unit drift and points at source behavior that
  differs from the shipped RA95 binary.
- Native team tracing over frames 300-430 showed the active drifting Allied L2
  group is team `rnf2`, containing `JEEP` plus three `E1` infantry, with
  `formation=none`. That rules out the 2020 `TeamFormData`/formation-speed
  migration for this specific drift.
- Git history pointed to `fc5cd5a7751e` ("Command & Conquer Remastered
  post-launch patch"), which changed `DriveClass::AI()` so units attached to a
  mission-driven team skip the original zone-rejection check:
  `... land != LAND_RIVER && !Team`.
- A diagnostic `RA_LEGACY_TEAM_ZONE_CHECKS=1` switch restoring the retail
  behavior improved RA95-vs-native Allied L2 frame 400 from `SSIM=0.9890,
  p99=24` to `SSIM=0.9953, p99=0`. The diagnostic switch was then removed and
  the retail behavior made default by deleting the `&& !Team` bypass.
- Follow-up: the source now exposes this as a build-time compatibility mode.
  `RA_BEHAVIOR=retail` is the default and targets RA95 parity; `RA_BEHAVIOR=remaster`
  defines `RA_REMASTER_BEHAVIOR=1` and preserves the 2020 mission-driven-team
  zone-check bypass. Convenience presets exist for native and MinGW remaster
  builds.
- Verification artifacts:
  - fixed frame 400 native capture:
    `/tmp/battlecontrol/2026-05-23T06-37-16-native-sequence-allied-l2/native-sequence/frame_000400.png`
  - fixed frame 500 native capture:
    `/tmp/battlecontrol/2026-05-23T06-37-58-native-sequence-allied-l2/native-sequence/frame_000500.png`
  - comparison crop montage:
    `/tmp/battlecontrol/team-zone-fix-20260523/f400-wine-baseline-fixed-crop.png`
  - frame 400 result: `SSIM=0.9953 p99=0`
  - frame 500 result: `SSIM=0.9950 p99=0`
- Sequence check over frames 400-500 against the existing Wine RA-clock sequence
  reduced average mean channel delta from `1.3189` to `0.6509` and average
  changed pixels per frame from `2973` to `1659`. Best sequence offset is now
  `0`, which is the expected same-frame alignment.

Capture mouse artifact, 2026-05-24:

- Rechecked Allied L2 around frames 250-429 after the team-zone fix. The Wine
  RA-clock candidate `0x006544c8` still aligns same-frame with native over the
  250-339 sequence; candidate logging in cnc-ddraw was initially disabled due
  to a tooling env-var mismatch (`WINE_CNCDDRAW_CAPTURE_LOG_CANDIDATES` vs
  `WINE_CAPTURE_LOG_CANDIDATES`), now fixed in `scripts/drivers/wine.py`.
- A large native-only delta beginning at frame 254 was not simulation state:
  native was drawing a `POWER PLANT` help tooltip once the sidebar cameo became
  available. The source was already forcing `Get_Mouse_X/Y`, but the harness
  default `(320,200)` was vertically aligned with the cameo row. Because
  `GadgetClass::Clicked_On` lacks lower-bound checks on `mousex - X` and
  `mousey - Y`, a cursor left/above a gadget can still hit it if the upper-bound
  comparison passes.
- Tooling fix under test: keep the real X pointer in a non-scrolling position,
  but pass owned engines an off-window in-game mouse coordinate via
  `RA_CAPTURE_MOUSE_X/Y` (`BC_CAPTURE_GAME_MOUSE_*` overrides). This removes
  the tooltip artifact: Allied L2 frame 254 mean channel delta dropped from
  roughly `0.9244` to `0.1578`.
- After removing the tooltip artifact, the remaining 250-429 delta is localized
  to moving objects in the `rnf2` reinforcement cluster. Terrain, MCV deployment,
  sidebar, radar, and timer are closely aligned. Current lead is still source
  behavior versus RA95 binary for mission/team movement, not capture timing or
  rendering order.

Synthetic AI-production divergence, 2026-05-24:

- Allied L2 still had a native/source-only game-state divergence after the
  team-zone fix: by native frame 200, infantry slots 43/44 existed near cell
  8761, while Wine/RA95 process-memory scans of the infantry heap found only
  the original scenario infantry in that area.
- Temporary `InfantryClass::Unlimbo` caller probes traced the post-load spawn
  to `BuildingClass::Exit_Object()` from `BuildingClass::Factory_AI()`, not to
  reinforcements, transports, survivors, or trigger actions.
- Git history identified the cause as committed TIM-298 diagnostic code:
  `HouseClass::AI()` forced every non-human house into `IsBaseBuilding=1` at
  frame 10 so factory production probes could run. That enabled USSR barracks
  production in Allied L2 even though the retail scenario had not started base
  building.
- Fix: remove the synthetic `IsBaseBuilding` force and the always-on TIM-298
  factory logs. Clean verification at Allied L2 frame 200:
  `/tmp/battlecontrol/manual-native-a2-frame200-clean-20260524T094105` has
  `units=2`, `infantry=43`, no post-load TIM/RA_INF trace lines, and the MCV
  at `coord=0x32005a00`, matching the earlier native movement state without
  the extra produced infantry.
- Normal wine/native screenshot verification with the cleaned source:
  - frame 200: `/tmp/battlecontrol/2026-05-24T09-43-00-mission-allied-l2`,
    `SSIM=0.9984 p99=0`
  - frame 400: `/tmp/battlecontrol/2026-05-24T09-43-53-mission-allied-l2`,
    `SSIM=0.9951 p99=0`
  - frame 500: `/tmp/battlecontrol/2026-05-24T09-45-08-mission-allied-l2`,
    `SSIM=0.9944 p99=0`

Nearby-location frame phase, 2026-05-24:

- Remaining Allied L2 frame-500 delta was isolated to the `rnf2`
  reinforcement team parking one cell away from RA95. Native/source picked
  target cell `6361`; RA95/Wine picked `6487`.
- Source instrumentation showed native calls `Map.Nearby_Location()` at
  `Frame=270` with candidate list
  `6487, 6359, 6361, 6487`, so the 2020 source expression
  `topten[Frame % count]` chooses index 2 (`6361`).
- New Wine `/proc/<pid>/mem` probes stopped RA95 exactly at the frame probe and
  dumped both team target dwords and selected `CellClass` bytes. At frame 270
  and 271, Wine cells `6359`, `6361`, and `6487` all had clear occupancy bytes;
  the same team target dword `0x09328578` (`As_Target(6487)`) appeared when the
  RA95 frame counter reached 271.
- A diagnostic native run forcing only `rnf2` to cell `6487` raised Allied L2
  frame-500 parity to `SSIM=0.9978 p99=0`, proving the visual delta was this
  destination choice and not rendering.
- Fix under test: retail/original builds select
  `topten[(Frame + locationmod + 1) % count]`; `RA_REMASTER_BEHAVIOR` keeps the
  2020 source expression. Clean unforced verification:
  `/tmp/battlecontrol/2026-05-24T16-24-09-mission-allied-l2`,
  `SSIM=0.9965 p99=0`.
- Post-fix matrix pass:
  - Allied L1 frame 500:
    `/tmp/battlecontrol/2026-05-24T18-48-00-mission-allied-l1`,
    `SSIM=0.9851 p99=60` (passes current gate; known tactical timing noise).
  - Allied L2 frame 500:
    `/tmp/battlecontrol/2026-05-24T18-49-21-mission-allied-l2`,
    `SSIM=0.9965 p99=0`.
  - Allied L3 frame 500:
    `/tmp/battlecontrol/2026-05-24T18-50-43-mission-allied-l3`,
    `SSIM=0.9980 p99=0`.
- Matrix blockers: Soviet L1, Soviet L3, and Allied L5 currently stall before
  gameplay in the Wine entry path (`loading`, frame counter zero), and the
  menu-drive fallback is internally blocked because `_setup_staging()` calls
  the mission patch helper with `autostart=false`, which that helper rejects.
  Treat that as the next tooling bug, not evidence against the
  `Nearby_Location` phase fix.
