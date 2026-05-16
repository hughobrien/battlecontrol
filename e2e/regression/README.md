# Regression Suite — TIM-623 / TIM-773

Eleven Playwright specs and two shell scripts covering the critical rendering /
audio / gameplay path for Red Alert and Tiberian Dawn WASM builds.

## Test-point table

| ID                       | Name                                     | Engine | Surface | Assets?      | CI?     | Budget |
|--------------------------|------------------------------------------|--------|---------|--------------|---------|--------|
| T1                       | RA WASM boot smoke                       | RA     | WASM    | no           | yes     | 60 s   |
| T2                       | TD WASM boot smoke                       | TD     | WASM    | no           | yes     | 60 s   |
| T3-ra                    | RA WASM main menu renders                | RA     | WASM    | yes (RA MIX) | no\*    | 50 s   |
| T3-td                    | TD WASM main menu renders                | TD     | WASM    | yes (TD MIX) | yes\*\* | 50 s   |
| T4                       | RA WASM VQA playback (ENGLISH.VQA t=3 s) | RA     | WASM    | yes (RA MIX) | no\*    | 50 s   |
| T5-ra-menu-click         | RA WASM menu-click (TIM-683 gate)        | RA     | WASM    | yes (RA MIX) | no\*    | 420 s  |
| T6-td-wasm-mission-start | TD WASM real-click GDI L1                | TD     | WASM    | yes (TD MIX) | yes\*\* | 300 s  |
| T7-td-audio-pitch        | TD WASM game audio pitch probe           | TD     | WASM    | yes (TD MIX) | yes\*\* | 600 s  |
| T8-ra-audio-pitch        | RA WASM PROLOG.VQA pitch probe           | RA     | WASM    | yes (RA MIX) | yes\*\* | 600 s  |
| T9-ra-wasm-mission-start | RA WASM real-click Allied L1             | RA     | WASM    | yes (RA MIX) | yes\*\* | 600 s  |
| T10-ra-menu-bleed        | RA WASM post-game map-bleed regression   | RA     | WASM    | yes (RA MIX) | yes\*\* | 900 s  |
| T11-wasm-gameplay-ssim   | RA WASM gameplay SSIM golden gate        | RA     | WASM    | yes (RA MIX) | yes\*\* | 900 s  |
| (shell) T5-td-native-menu   | TD native main menu renders           | TD     | native  | yes          | no\*    | 30 s   |
| (shell) T6-ra-native-smoke  | RA native short-run smoke             | RA     | native  | yes          | no\*    | 45 s   |

\* `no` = requires licensed CnC Remastered MIX files not available in upstream
CI.  The same test passes on a developer machine with assets symlinked.

\*\* `yes` = wired in `.github/workflows/gh-pages.yml`.  Skips gracefully when
the corresponding asset URL secret (`RA_ASSETS_URL` / `TD_ASSETS_URL`) is
unset, so the CI job still passes on forks or branches that lack the secret.

## Pass / fail criteria

### T1 — RA WASM boot smoke (asset-free, CI)

- **Pass:** `ra.html` loads, observes for 30 s, **zero** `pageerror` events,
  `#status-line` text is not still `"Loading…"`.
- **Fails on:** WASM parse errors, null-function trap regressions
  (TIM-593 / TIM-620 class), Emscripten init crashes.

### T2 — TD WASM boot smoke (asset-free, CI)

Same shape as T1 but loads `td.html`.

### T3-ra — RA WASM main menu renders (with RA assets, local)

- **Pass:** preloader hides, `Init_Bulk_Data done`, canvas non-black fill ≥15 %.
- **Fails on:** palette regressions (TIM-141 class), TITLE.PCX load failure.

### T3-td — TD WASM main menu renders (with TD assets, CI when TD_ASSETS_URL set)

- **Pass:** preloader hides, `[TD] Main_Menu: gadgets up`, canvas changes.
- **Fails on:** TD menu boot regressions, TD palette issues.

### T4 — RA WASM VQA playback (ENGLISH.VQA t=3 s, with RA assets, local)

- **Pass:** wait for `[VQA] Playing 'ENGLISH.VQA'`, sample canvas at t=3 s,
  fill ≥25 %, `cyanCount = 0` (TIM-590), top-band fill = 0 (TIM-613).
- **Fails on:** codebook fill regressions (TIM-613), cyan-block scatter.

### T5-ra-menu-click — RA WASM menu-click / TIM-683 gate (with RA assets, local)

- **Pass:** preloader hides, Init_Bulk_Data done, VQA skip, menu up via
  `[TIM-616] menu_cs=`, real click at (322, 183), `[MENU] input=0x` logged,
  canvas pixel diff > 0.
- **Fails on:** SDL event pump regressions (TIM-683 / TIM-694 class).

### T6-td-wasm-mission-start — TD WASM real-click GDI L1 (CI when TD_ASSETS_URL set)

- **Pass:** click "Start New Game" at (321, 59), `Start_Scenario(SCG01EA)` fires,
  frame 200 canvas fill ≥20 %.
- **Fails on:** TD menu-click or mission-start regressions.

### T7-td-audio-pitch — TD WASM game audio pitch probe (CI when TD_ASSETS_URL set)

- **Pass:** mean spectral centroid (20–2000 Hz) across samples at t=5 s and
  t=20 s after frame 100 < 700 Hz.
- **Fails on:** TIM-555 class regression (22050 Hz PCM fed raw to AudioContext;
  causes 2× pitch).

### T8-ra-audio-pitch — RA WASM PROLOG.VQA pitch probe (CI when RA_ASSETS_URL set)

- **Pass:** ENGLISH.VQA plays to completion (~10 s), PROLOG.VQA starts (Hell
  March); **min** dominant peak (20–300 Hz) across samples at t=5 s and t=20 s
  after `[VQA] Playing 'PROLOG.VQA'` < 90 Hz.
- **Fails on:** TIM-602 class regression (VQA PCM fed raw to AudioContext without
  `vqa_audio_queue_s16` resample fix; correct pitch has sub-bass dominant at
  ~50–80 Hz, regression shifts it to ~100–160 Hz).
- **min (not max) per TIM-766:** a sustained regression keeps both samples above
  threshold; a percussion transient can push only one sample above threshold.
- **Runnable under 5×cold-cache wrapper:** `scripts/tim773-t8-5run-verify.sh`.

### T9-ra-wasm-mission-start — RA WASM real-click Allied L1 (CI when RA_ASSETS_URL set)

- **Pass:** VQA auto-skip, menu up via `[TIM-616] menu_cs=`, click (322, 183),
  difficulty + faction KN_RETURN injections fire, `Start_Scenario(SCG01EA)` OK,
  frame 100 canvas fill ≥5 %.
- **Fails on:** RA menu-click or mission-start regressions (analogous to T6 for TD).

### T10-ra-menu-bleed — RA WASM post-game map-bleed regression (CI when RA_ASSETS_URL set)

- **Pass:** loads `ra.html?autostart=1&mission_test=1`, runs gameplay until forced
  win at ~frame 1250, captures canvas after transition back to the main menu,
  parity-compare.py SSIM ≥ 0.90 vs `e2e/goldens/clean-ra-menu.png`.
- **Fails on:** TIM-777 class regression where stale game-frame pixels (HidPage)
  bleed through the menu background after returning from gameplay.

### T11-wasm-gameplay-ssim — RA WASM gameplay SSIM golden gate (CI when RA_ASSETS_URL set)

- **Pass:** loads `ra.html?src=...&autostart=1`, waits for `Start_Scenario OK`
  (SCG01EA), captures canvas at frames 100/300/500, compares each against
  committed golden via parity-compare.py (SSIM ≥ 0.95). If goldens are missing
  (first run or repo checkout), saves candidate goldens and passes without SSIM
  enforcement — goldens must be committed from a known-good build.
- **Fails on:** rendering regressions that shift pixel content beyond the SSIM
  threshold — palette corruption, missing sprites, layout shifts, or terrain
  changes. Pixel-stat checks (fill %, colour diversity) run first and also
  enforce non-black content at frames 300/500.
### (shell) T5-td-native-menu — TD native main menu (with TD assets, local)

Runs `build/td/td` under Xvfb :99 for 5 s, asserts non-black fill ≥10 %.
Shell: `scripts/regression/T5-td-native-menu.sh`.

### (shell) T6-ra-native-smoke — RA native short-run smoke (with RA assets, local)

Runs `build/first-run-pass-94/redalert.elf` for 30 s, asserts ≥100 frames and
no SIGSEGV / Aborted.  Shell: `scripts/regression/T6-ra-native-smoke.sh`.

## Implementation files

| ID                       | File                                                    | Type       |
|--------------------------|---------------------------------------------------------|------------|
| T1                       | `e2e/regression/T1-ra-wasm-boot.spec.ts`                | Playwright |
| T2                       | `e2e/regression/T2-td-wasm-boot.spec.ts`                | Playwright |
| T3-ra                    | `e2e/regression/T3-ra-wasm-menu.spec.ts`                | Playwright |
| T3-td                    | `e2e/regression/T3-td-wasm-menu.spec.ts`                | Playwright |
| T4                       | `e2e/regression/T4-ra-wasm-vqa.spec.ts`                 | Playwright |
| T5-ra-menu-click         | `e2e/regression/T5-ra-wasm-menu-click.spec.ts`          | Playwright |
| T6-td-wasm-mission-start | `e2e/regression/T6-td-wasm-mission-start.spec.ts`       | Playwright |
| T7-td-audio-pitch        | `e2e/regression/T7-td-audio-pitch.spec.ts`              | Playwright |
| T8-ra-audio-pitch        | `e2e/regression/T8-ra-audio-pitch.spec.ts`              | Playwright |
| T9-ra-wasm-mission-start | `e2e/regression/T9-ra-wasm-mission-start.spec.ts`       | Playwright |
| T10-ra-menu-bleed        | `e2e/regression/T10-ra-menu-bleed.spec.ts`            | Playwright |
| T11-wasm-gameplay-ssim   | `e2e/wasm-gameplay.spec.ts` (test 6)                  | Playwright |
| (shell) T5-td-native-menu   | `scripts/regression/T5-td-native-menu.sh`            | Shell      |
| (shell) T6-ra-native-smoke  | `scripts/regression/T6-ra-native-smoke.sh`           | Shell      |

## Running

```bash
# CI tier: T1 + T2 (asset-free, always green).
REGRESSION_TIER=ci  bash scripts/regression-suite.sh

# Local tier: all (requires CnCRemastered assets at CD1/).
REGRESSION_TIER=full bash scripts/regression-suite.sh
```

## How to add a new test-point

1. Decide if it can run in CI (asset-free or with a CDN URL secret) or only
   locally (needs local MIX files).
2. Pick the next `T<N>` slot.  Use a descriptive suffix when there is an RA/TD
   pair at the same number (e.g. `T3-ra` / `T3-td`).
3. Write a focused spec asserting **one or two** observable signals.
4. Keep the spec within its budget — audio probe specs at 600 s, boot/menu
   specs at 60–420 s.
5. Drop Playwright specs under `e2e/regression/` and shell scripts under
   `scripts/regression/`.
6. Update this README's table and pass/fail section.
7. If CI-runnable, add a step to `.github/workflows/gh-pages.yml`.
   Asset-gated steps must use a bash `if [ -z "$ASSET_URL" ]; then exit 0; fi`
   guard — not a YAML `if:` condition (secrets in `if:` cause "0 jobs created"
   validation failures).

## Design notes

- Each test is a tripwire, not a microscope.  When one fails, reach for the
  relevant audit spec (e.g. `tim603-audio-pitch-probe.spec.ts`) to diagnose.
- Asset-gated steps skip gracefully in forks/branches without the secret, so
  the workflow always exits 0 on code-only changes.
- Use **min** (not max) for multi-sample assertions: a sustained pitch regression
  keeps ALL samples above threshold; a percussion transient can push one sample
  above threshold without indicating a regression (TIM-766).
