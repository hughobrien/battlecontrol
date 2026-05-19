# Smoke-Test Design Rule: Assertion Before Harness

**Rule:** Define explicit pass/fail assertions *before* writing the test harness.
For any test that covers rendering output, assertions must be visually verifiable
(screenshot + pixel-diff or colour-range check), not just quantitative fill%.

---

## Origin

[TIM-635](https://github.com/hughobrien/battlecontrol/issues) (expert analysis item 6)
identified the root cause of TIM-587: CI smoke tests were written as execution harnesses
without explicit assertions. The old `vqa-pixel-diff` job passed on fill% while frames
showed block-aligned cyan corruption — quantitative metrics passed while the visual
output was broken.

---

## The Rule

### For all smoke tests

1. **Write the assertion first.** Before writing `await page.goto(...)` or `subprocess.run(...)`,
   write the `expect(...)` or `assert` that must pass. If you cannot write that assertion yet,
   you are not ready to write the harness.

2. **State acceptance criteria in the test file header.** Every new spec must have a header
   comment listing numbered acceptance criteria that map 1-to-1 to `expect()` calls in the body.
   If a criterion has no corresponding `expect()`, it is not tested.

3. **Name the failure mode explicitly.** Each assertion comment must name the regression it guards.
   `// TIM-587: no cyan-block scatter` is correct. `// check the frame` is not.

### For rendering / graphics tests

4. **Visual output requires visual assertions.** Fill percentage alone is insufficient.
   Use one or more of:
   - Per-pixel colour-range checks (e.g., cyan% < 1%, warm% ≥ 1%)
   - ffmpeg pixel-diff against a committed golden frame (`--threshold N`)
   - Screenshot saved as artefact + explicit non-black pixel minimum
   - Block-edge heuristic (for codec tests: horizontal pixel-pair delta at 4-pixel grid lines)

5. **Save a screenshot for every rendering test.** Name it after the ticket
   (`e2e/screenshots/tim{N}-{description}.png`). Upload it as a CI artefact on failure.
   Screenshots are evidence; they are not a substitute for `expect()`.

6. **The "no crash" gate is insufficient for rendering tests.** A test that only asserts
   `pageErrors.toHaveLength(0)` for a rendering path is incomplete. Add at least one
   pixel-level check that would have caught the last known visual regression.

### For audio tests

7. **Audio correctness requires a frequency-domain assertion.** Log lines saying "opened at N Hz"
   are necessary but not sufficient. Add a tone-detection or spectral-energy assertion
   (see `scripts/audio-pitch-probe.py` pattern from TIM-603).

---

## Checklist for PR reviewers

When reviewing a PR that adds or modifies a smoke test, verify:

- [ ] The test file header lists numbered acceptance criteria
- [ ] Every criterion maps to an `expect()` / `assert` in the body
- [ ] Rendering tests include at least one pixel-range or pixel-diff assertion
- [ ] Audio tests include at least one frequency-domain check (not just log-line grep)
- [ ] Screenshots are saved and uploaded as artefacts on failure
- [ ] Each assertion comment names the regression it guards

---

## Existing tests — audit status

| Test | Assertions | Visual? | Audit status |
|------|-----------|---------|--------------|
| `e2e/wasm-smoke.spec.ts` | no crash + status line | None | **TIM-645** — needs pixel assertion |
| `scripts/ra/ra-native-smoke.sh` (CI release mode) | 1000 frames, 1 win, no crash, FPS | None | Visual rendering **not covered** by this test — rendering gap covered by WASM smoke test (`e2e/tim600-english-vqa-verify.spec.ts`, `e2e/tim590-ghpages-cyan-verify.spec.ts`). Adding a pixel gate here would require ffmpeg or ImageMagick (not in the CI image); the WASM path exercises the same C++ renderer compiled to a different target and already has fill%, cyan%, warm%, blockEdge, and colour-range assertions. |
| `ci.yml: vqa-decode/compare` | ffmpeg vs native decoder comparison | Yes | OK |
| `e2e/tim590-ghpages-cyan-verify.spec.ts` | fill%, cyan%, warm% pixel ranges | Yes | OK |
| `e2e/tim600-english-vqa-verify.spec.ts` | fill%, cyanCount, blockEdges, audio log | Yes | OK |

---

## Reference implementations

Good examples of assertion-first smoke tests in this repo:

- **`e2e/tim600-english-vqa-verify.spec.ts`** — header lists 6 criteria; each maps to an
  `expect()` with a named regression comment; pixel stats checked at multiple timestamps.
- **`scripts/vqa-compare.py`** — compares two VQA decode output directories,
  detects any video or audio frame differences.
- **`e2e/tim590-ghpages-cyan-verify.spec.ts`** — introduced after TIM-587; colour-range
  checks explicitly named after the regression they guard.

See also: [`docs/emscripten-playbook.md`](emscripten-playbook.md) for WASM-specific pitfalls.
