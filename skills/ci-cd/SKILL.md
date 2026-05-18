---
name: ci-cd
description: Use when working on CI/CD pipelines, GitHub Actions workflows, release automation, or artifact publishing for C&C Red Alert + Tiberian Dawn native and WASM builds. Trigger on symptoms like CI job failures, release workflow not attaching artifacts, gh-pages deploy not updating, WASM binary validation failing, ccache not hitting, or regression tiers regressing.
version: 0.2.0
---

# CI/CD Pipeline Skill

> **Tools available via `pi-battlecontrol-dev` extension:** `wasm_build`, `wasm_validate`,
> `native_build`, `toolchain_check`, `wine_capture`, `vqa_pixel_diff`, `run_e2e_test`.
> Ask the agent to run these instead of typing raw commands.

You are working on the CI/CD pipeline for the C&C native Linux and WASM builds. The
pipeline has three GitHub Actions workflows: `ci.yml` (push/PR), `gh-pages.yml`
(continuous deploy), and `release.yml` (semver tag trigger).

---

## Phase 0 — Check workflow status

```bash
# View recent CI runs (if gh CLI available):
gh run list --workflow ci.yml --limit 5
gh run list --workflow gh-pages.yml --limit 5
```

---

## §1 — Workflow overview

### `ci.yml` — Push/PR to master

| Job | What it does | Timeout |
|-----|-------------|---------|
| **build** (gcc + clang) | Builds RA + TD native Linux, ccache stats | 30 min |
| **vqa-pixel-diff** | Synthetic VQA regeneration + pixel-diff (always), game VQA (if data present) | 10 min |
| **wine-comparison** | Installs wine32, runs RA95.EXE under Wine, Tier 1+3 Playwright tests | 20 min |
| **build-wasm** | Emscripten 5.0.6, builds ra.wasm + td.wasm, validates magic+size, T1+T2 smoke | 20 min |

### `gh-pages.yml` — Push to master (source/tooling changes)

Builds both WASM targets, runs T1–T10 regression suite, validates binaries, deploys
to GitHub Pages with COI service worker injection.

### `release.yml` — Semver tag trigger (`v*.*.*`)

Four parallel build jobs (RA native, TD native, RA WASM, TD WASM) → single release
job that downloads all artifacts, generates SHA-256 checksums, and creates a GitHub
Release with auto-generated notes.

---

## §2 — Common failure modes

### §2.1 — Build job: compile errors

Check the compiler log for the first error. Native builds use `-fmax-errors=20` to
limit output. Common causes:

- New `#include` without regenerating include shim → run `generate-include-shim.py`
- Missing `-DWIN32=1` on TD target → check CMakeLists.txt
- SDL2 headers missing — ensure Nix dev shell is active
- Struct layout mismatch → run `lint-lp64.py`, fix E1–E4 errors

### §2.2 — VQA pixel-diff job: synthetic VQA mismatch

```
ERROR: committed test.vqa differs from generator output
```

Run `python3 scripts/gen_test_vqa.py e2e/goldens/vqa/test.vqa` and commit the result.
This happens when the generator script was changed but `test.vqa` was not regenerated.

### §2.3 — Wine job: RA95.EXE cache miss

The Wine job caches RA95.EXE by its SHA-256. If the cache key changed or the cache
was evicted, the job downloads from archive.org (2.2 MB). Transient network failures
can cause this step to fail — rerun the job.

### §2.4 — WASM build: Emscripten version mismatch

The workflow pins Emscripten 5.0.6 via `mymindstorm/setup-emsdk@v14`. If the version
is bumped, all WASM-compiled code must be re-verified.

### §2.5 — WASM smoke: pageerror crash

T1/T2 boot tests fail if `onRuntimeInitialized` never fires. Common causes:

- Missing COOP/COEP headers → check `serve-coop.py` is running
- WASM JIT cold-start timeout → increase `waitForFunction` timeout to 300s
- SharedArrayBuffer unavailable → check browser flags in `playwright.config.ts`
- PROXY_TO_PTHREAD boundary violation (EM_ASM in Worker) → see emscripten skill §2.1

### §2.6 — gh-pages: COI service worker not injected

GitHub Pages cannot set COOP/COEP response headers. The workflow injects
`coi-serviceworker.min.js` into the deployed HTML. If WASM fails on gh-pages
but works locally, check that the COI service worker injection step ran successfully.

---

## §3 — Release process

1. Ensure CI is green on master.
2. Create and push a semver tag:
   ```bash
   git tag v0.3.1
   git push origin v0.3.1
   ```
3. `release.yml` triggers automatically.
4. Four parallel builds produce:
   - `redalert-linux-x86_64` (native RA binary)
   - `tiberiandawn-linux-x86_64` (native TD binary)
   - `redalert-wasm.zip` (ra.html + ra.js + ra.wasm)
   - `tiberiandawn-wasm.zip` (td.html + td.js + td.wasm)
5. Release job generates `SHA256SUMS` and `manifest.json`.
6. GitHub Release is created with all artifacts attached.

**Post-release verification:** Run the full regression suite against the deployed
gh-pages URL and the downloaded artifacts.

---

## §4 — Running CI jobs locally

Use the `pi-battlecontrol-dev` extension tools instead of typing raw commands:

| CI Job | Tool | Notes |
|--------|------|-------|
| Native build | `native_build(target: "both")` | Builds RA + TD native Linux |
| WASM build | `wasm_build(target: "both")` | Builds ra.wasm + td.wasm |
| WASM validate | `wasm_validate(target: "both")` | Checks magic + size > 1 MB |
| VQA pixel-diff | `vqa_pixel_diff(mode: "synthetic")` | Synthetic VQA gate, no data needed |
| Cinematic VQA | `vqa_pixel_diff(mode: "cinematic")` | Full game VQA scan against ffmpeg |
| Wine OG capture | `wine_capture(game: "ra")` | Title + menu baseline screenshots |
| Wine + parity | `wine_capture` then `run_e2e_test` with `tim699` spec | Requires EXE + data |
| WASM smoke test | `run_e2e_test(spec: "e2e/regression/T1-ra-wasm-boot.spec.ts")` | T1 boot smoke |


---

## §5 — ccache configuration

The CI build jobs use ccache to accelerate recompiles. Cache is keyed by compiler
(gcc/clang) and commit SHA.

```bash
# Local ccache setup:
export CCACHE_DIR="$PWD/.ccache"
cmake --preset linux-native -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

# Check hit rate:
ccache --show-stats
```

On CI, first-run builds have 0% cache hit. Subsequent runs on the same branch with
similar code changes should see 50–80% hit rates.

---

## §6 — Concurrency and cancellation

`ci.yml` uses `cancel-in-progress: true` on the `ci-${{ github.ref }}` concurrency
group. Pushing a new commit to a PR cancels the in-flight CI run for that PR.
Master branch pushes also cancel in-flight master CI.

`gh-pages.yml` and `release.yml` do NOT use cancel-in-progress (they should complete
regardless of subsequent pushes).

---

## §7 — Designing new CI jobs

### When to use a matrix job vs a sequential step

| Scenario | Recommendation |
|----------|---------------|
| Same build with different compilers (gcc, clang) | Matrix job — parallel, independent |
| Build → test → deploy pipeline | Sequential steps in one job — cheaper than fan-out |
| Build for multiple targets (native, WASM) | Separate jobs — different runner requirements |
| Release with parallel builds + single aggregation | Fan-out jobs + `needs` fan-in job |

### Setting timeouts

Base timeouts on historical run durations (check `gh run view`):
```yaml
jobs:
  build:
    timeout-minutes: 30  # native build ~12 min on 4-core runner
```
| Job type | Typical duration | Recommended timeout |
|----------|-----------------|-------------------|
| Native build (gcc/clang) | 8–15 min | 30 min |
| WASM build | 5–10 min | 20 min |
| WASM smoke tests | 3–8 min | 20 min |
| Wine comparison | 5–12 min | 20 min |
| VQA pixel-diff | 1–3 min | 10 min |

### Cancellation strategy

`ci.yml` uses `cancel-in-progress: true` to save runner minutes on stacked PRs.
`gh-pages.yml` and `release.yml` do NOT — they must complete regardless of
subsequent pushes.

---

## §8 — Flaky-test triage

### Identifying flaky steps

```bash
# Re-run a specific job to check consistency
gh run rerun <run-id> --job <job-id>

# Or run a failing test with --repeat-each locally
playwright test --repeat-each 3 e2e/regression/T1-ra-wasm-boot.spec.ts
```

### Common flakiness patterns

| Pattern | Symptom | Fix |
|---------|---------|-----|
| WASM JIT cold-start | T1/T2 pass 50% of time | Increase `waitForFunction` timeout to 300s |
| Audio timing race | Audio pitch probe passes ~60% | Apply 5/5 cold-cache rule; add retry |
| Asset server race | Game loads blank if assets not ready | Add `waitForResponse` before interaction |
| Xvfb display collision | `xdpyinfo` fails intermittently | Use `xvfb-ensure.sh` (idempotent) |

### Mitigation techniques

```yaml
# In CI workflow: retry the flaky step once
- name: WASM smoke test
  uses: nick-fields/retry@v3
  with:
    timeout_minutes: 10
    max_attempts: 2
    command: bash scripts/run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
```

Before adding retries, try fixing the root cause. Retry should be a last resort.

---

## §9 — Artifact debugging

When CI fails but you can't reproduce locally, download the job artifacts:

```bash
# List artifacts for a run
gh run view <run-id> --json 'headBranch,status'

# Download specific artifact
gh run download <run-id> -n build-wasm -D /tmp/wasm-artifact

# Download all artifacts
gh run download <run-id>
```

### Inspecting CI screenshots

Screenshots are uploaded as `e2e/screenshots/tim{N}-{description}.png` on failure.
Download and inspect:
```bash
gh run download <run-id> -n t1-boot-screenshots
ls t1-boot-screenshots/
# Open PNG locally or upload to an image viewer
```

### CI runner debugging

For runner-level issues (disk space, Docker daemon):
```yaml
- name: Debug runner
  run: |
    df -h
    free -m
    nproc
    cat /proc/cpuinfo | grep 'model name' | head -1
```

---

## §10 — Adding a new regression tier

1. Write the test following `docs/smoke-test-design-rule.md`
2. Add it to `gh-pages.yml` as a new step under the "Playwright tests" section.
   Use the shared runner script so the full setup (Xvfb + server + test + cleanup)
   is a single step:
   ```yaml
   - name: WASM — T{N} {description}
     run: bash scripts/run-e2e.sh e2e/regression/T{N}-{name}.spec.ts
   ```
3. Upload screenshots on failure:
   ```yaml
   - name: Upload T{N} screenshots on failure
     if: failure()
     uses: actions/upload-artifact@v4
     with:
       name: t{N}-{name}-screenshots
       path: e2e/screenshots/t{N}-{name}.png
   ```

---

## §11 — Verification bar

| Gate | How | Expected |
|------|-----|----------|
| CI lint | `act -j build --matrix compiler:gcc` (if `act` installed) | All steps pass |
| Release dry-run | Check `release.yml` syntax | No errors |
| WASM binary | Run `wasm_validate` or `wasm_validate_both` | Both ra.wasm and td.wasm |
| T1 smoke | Run `run_e2e_test(spec: "e2e/regression/T1-ra-wasm-boot.spec.ts")` | Pass |

---

## Reference

- `.github/workflows/ci.yml` — Push/PR CI (300 lines)
- `.github/workflows/gh-pages.yml` — Continuous deploy to GitHub Pages
- `.github/workflows/release.yml` — Semver-tagged release automation
- `RELEASE.md` — Release checklist and artifact descriptions
- `WASM-SERVE.md` — WASM serving guide (COOP/COEP headers)
- `scripts/first-run-pass-94.sh` — Release-build smoke test (native RA)
- `scripts/run-td-cheat.sh` — Cheat-mode smoke test (native TD)
