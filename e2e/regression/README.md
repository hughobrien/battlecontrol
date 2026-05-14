# Regression Suite — TIM-623

Six small, fast test-points covering the critical rendering / audio / gameplay
path for Red Alert and Tiberian Dawn.

The goal is to keep round-trip CI under a few minutes by replacing the long
one-off audit specs (TIM-538/542/591/600/601/603) with focused regression
checks that each finish in **under 60 s**.

## The 6 test-points

| ID  | Name                                      | Engine | Surface | Assets? | CI?  | Budget |
|-----|-------------------------------------------|--------|---------|---------|------|--------|
| T1  | RA WASM boot smoke                        | RA     | WASM    | no      | yes  | 45 s   |
| T2  | TD WASM boot smoke                        | TD     | WASM    | no      | yes  | 45 s   |
| T3  | RA WASM main menu renders                 | RA     | WASM    | yes     | no\* | 50 s   |
| T4  | RA WASM VQA playback (ENGLISH.VQA t=3 s)  | RA     | WASM    | yes     | no\* | 50 s   |
| T5  | TD native main menu renders               | TD     | native  | yes     | no\* | 30 s   |
| T6  | RA native short-run smoke                 | RA     | native  | yes     | no\* | 45 s   |

\* "no" = the test cannot run in upstream CI because it needs the licensed
CnC Remastered MIX files. The same test passes on a developer machine that
has the assets symlinked. T1 / T2 cover the CI path; T3–T6 cover the local
regression path that an engineer runs before pushing.

## Pass / fail criteria (concrete)

Each test asserts exactly one or two observable signals — no full-game runs.

### T1 — RA WASM boot smoke (asset-free, CI)

- **Pass:** `ra.html` loads, observes for 30 s, **zero** `pageerror` events,
  `#status-line` text is not still `"Loading…"` at end of window.
- **Fails on:** WASM parse errors, null-function trap regressions
  (TIM-593 / TIM-620), Emscripten init crashes, JIT-only failures.
- **Cost:** 35 s (30 s observe + 5 s navigate).

### T2 — TD WASM boot smoke (asset-free, CI)

Same shape as T1 but loads `td.html`. Catches TD-only WASM build
regressions (struct layout, init order, etc.).

### T3 — RA WASM main menu renders (with assets, local)

- **Pass:** boot RA WASM with the asset CDN, preloader hides, status line
  reports `Init_Bulk_Data done`, canvas non-black fill `≥ 15 %` within
  45 s, zero `pageerror`.
- **Fails on:** palette regressions (CPL0 6→8-bit shift, TIM-141 class),
  TITLE.PCX load failure, blank-canvas regressions (TIM-250 class).
- **Cost:** ~50 s including preloader.

### T4 — RA WASM VQA playback (ENGLISH.VQA t=3 s, with assets, local)

- **Pass:** boot RA WASM with no `autostart`, wait for
  `[VQA] Playing 'ENGLISH.VQA'`, sample canvas at t = 3 s, assert
  `fill ≥ 25 %`, `cyanCount = 0` (TIM-590 signature), top-band fill = 0
  (letterbox not corrupted, TIM-613 signature).
- **Fails on:** codebook fill regressions (TIM-613), cyan-block scatter
  (TIM-587 / TIM-590), VQA divide-by-zero (TIM-602).
- **Cost:** ~50 s. Only samples one frame — not a full playback.

### T5 — TD native main menu (with assets, local)

- **Pass:** `build/td/td` runs in `build/run-td/` under `Xvfb :99` for 5 s
  with `TD_AUTOSTART=0`, captures a screenshot via Playwright connecting
  to a Datacard-style helper page, verifies non-black fill `≥ 10 %`,
  exit-code 0 or 124 (timeout = alive).
- **Fails on:** native palette regressions, TD WIN32-define regressions
  (TIM-343 class), SDL init failures.
- **Cost:** ~25 s. Implemented as a shell script because the native build
  doesn't run in a browser.

### T6 — RA native short-run smoke (with assets, local)

- **Pass:** `build/first-run-pass-94/redalert.elf` runs in `build/run-172/`
  under `Xvfb :99` for 30 s with `RA_AUTOSTART=1 SDL_AUDIODRIVER=dummy`,
  log shows at least 100 frames (`[TIM-316]` probe or `frame=` markers),
  zero `SIGSEGV` / `Aborted` / `CRASH signal` lines.
- **Fails on:** game-loop regressions (TIM-231 class), in-game crash
  regressions (TIM-218/222 class), VQA-in-game crashes.
- **Cost:** ~45 s. Lighter version of `first-run-pass-94.sh` (which uses
  120 s and demands a full win cycle).

## Implementation files

| ID  | File                                              | Type       |
|-----|---------------------------------------------------|------------|
| T1  | `e2e/regression/T1-ra-wasm-boot.spec.ts`          | Playwright |
| T2  | `e2e/regression/T2-td-wasm-boot.spec.ts`          | Playwright |
| T3  | `e2e/regression/T3-ra-wasm-menu.spec.ts`          | Playwright |
| T4  | `e2e/regression/T4-ra-wasm-vqa.spec.ts`           | Playwright |
| T5  | `scripts/regression/T5-td-native-menu.sh`         | Shell      |
| T6  | `scripts/regression/T6-ra-native-smoke.sh`        | Shell      |

The runner script `scripts/regression-suite.sh` orchestrates servers,
Xvfb, and runs the right subset based on the `REGRESSION_TIER` env var:

```bash
# CI tier: T1 + T2 (asset-free).
REGRESSION_TIER=ci  bash scripts/regression-suite.sh

# Local tier: all six (requires CnCRemastered assets).
REGRESSION_TIER=full bash scripts/regression-suite.sh
```

Default tier is `ci`.

## How to add a new test-point

1. Decide if it can run in CI (asset-free) or only locally (needs MIX).
2. Pick the next available `T<N>` slot. Bump the table above.
3. Write a focused test that asserts **one** observable signal. Avoid
   long playback / many sample points — that turns into another audit
   spec, not a regression check.
4. Keep the test under 60 s, including any preloader / asset cache
   warmup.
5. For Playwright tests, drop the spec under `e2e/regression/` so the
   suite runner picks it up via `--grep` or path. For shell tests,
   add it under `scripts/regression/` and wire it into
   `scripts/regression-suite.sh`.
6. Update this README's table and pass/fail section.
7. If the test is CI-runnable, also add a step to `.github/workflows/ci.yml`
   or `.github/workflows/gh-pages.yml` so it runs on every push.

## Why this shape

- Each test asserts a small set of observables. They're a tripwire, not
  a microscope — when one fails, the engineer reaches for the relevant
  one-off audit spec (`tim600-english-vqa-verify.spec.ts`, etc.) to
  diagnose.
- The 60 s budget is enforced by `test.setTimeout(60_000)` in Playwright
  and `timeout 60` in shell. Tests that creep past it get rejected at
  review.
- Splitting CI vs local lets us run T1 + T2 on every commit (cheap,
  hermetic) and run T3–T6 in a developer's pre-push hook or a nightly
  build that mounts the assets directory.
