---
name: e2e-testing
description: Use when writing or debugging Playwright e2e tests for C&C WASM builds. Trigger on symptoms like WASM pageerror crashes, `__wasmReady` never set, COOP/COEP header failures, blank Xvfb screenshots, audio pitch detection failures, pixel-range assertions that pass while visual output is broken, or CI timing out waiting for WASM to initialize.
version: 0.1.0
---

# Playwright E2E Testing Skill

You are writing or debugging Playwright end-to-end tests for the C&C WASM builds
(Red Alert and Tiberian Dawn). Tests run against a local dev server serving the
Emscripten-built `.html`/`.js`/`.wasm` bundle with COOP/COEP headers.

Read `docs/smoke-test-design-rule.md` for assertion design rules before writing
any new test.

---

## Phase 0 — Serve the WASM bundle

The WASM build requires COOP + COEP headers for SharedArrayBuffer (used by pthreads).

### One-command serve (with auto-cleanup)

```bash
source scripts/skill-wasm-serve.sh
# Serves build-wasm/ on :8080 with COOP/COEP headers.
# WASM_SERVER_PID and WASM_SERVER_PORT are exported.
# Server is auto-killed on shell exit via EXIT trap.
```

### Manual serve options

### Nginx (for CI or production-like)

```bash
# Or use nix:
nix run .#wasm-server

# Manual nginx:
cp wasm/nginx.conf /etc/nginx/sites-enabled/wasm.conf
nginx -s reload
```

**Critical:** Without COOP/COEP headers, SharedArrayBuffer is unavailable and
Emscripten pthreads initialization fails silently.

---

## Phase 1 — Classify the symptom

| Symptom | Lens | Go to |
|---|---|---|
| `pageerror` with "null function or signature mismatch" | Missing or outdated WASM binary | §2.1 |
| `__wasmReady` never set; 300s timeout | Emscripten runtime init failure | §2.1 |
| Blur or black canvas despite game loop running | OffscreenCanvas or renderer in Worker | §2.2 |
| Audio pitch wrong — FFT spectral centroid off | AudioContext.sampleRate mismatch | §2.3 |
| Pixel-range assertion passes but visual output is broken | Assertion too weak — fill% only | §2.4 |
| `--grep` filter selects no tests | Test name or server not running | §2.5 |
| Xvfb display not available; `xdpyinfo` fails | Xvfb died or :99 already in use | §2.6 |

---

## §2.1 — WASM readiness gate (the `__wasmReady` pattern)

The preloader sets `window.__wasmReady = true` after Emscripten `onRuntimeInitialized`
fires. All WASM tests must wait for this gate with a generous timeout.

```ts
// Correct — gate on onRuntimeInitialized:
await page.waitForFunction(() => (window as any).__wasmReady === true, {
  timeout: 300_000  // 5 minutes for -O2 JIT cold-start
});

// Wrong — waitForTimeout alone (doesn't know if WASM loaded):
await page.waitForTimeout(30_000);  // may pass before WASM is ready
```

The `preloader.js` sets `__wasmReady` after file I/O and WASM module init are complete.
This is the canonical readiness signal. Do not invent alternative gates.

**WASM binary validation** (CI-only):
```python
import os, struct
MIN_SIZE = 1_000_000
for name in ('build-wasm/ra.wasm', 'build-wasm/td.wasm'):
    with open(name, 'rb') as f:
        magic = f.read(4)
    assert magic == b'\x00asm', f'{name}: invalid WASM magic'
    size = os.path.getsize(name)
    assert size > MIN_SIZE, f'{name}: suspiciously small ({size} bytes)'
```

---

## §2.2 — Headed Chrome on Xvfb (NOT headless shell)

The WASM build uses PROXY_TO_PTHREAD with OffscreenCanvas. Chromium's headless
shell mode (`--headless=new` or `headless: true` in Playwright config) does not
support OffscreenCanvas → black screen.

**One-command E2E runner (Xvfb + server + test):**

```bash
bash scripts/skill-run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
bash scripts/skill-run-e2e.sh e2e/tim710-wasm-parity.spec.ts --grep "Tier 1"
```

This starts Xvfb :99, starts the WASM dev server on :8080, runs the Playwright
test with `DISPLAY=:99`, and cleans up both on exit. All arguments after the spec
file are forwarded to `npx playwright test`.

**Manual Xvfb setup:**
```ts
// playwright.config.ts
use: {
  headless: false,
  channel: 'chromium',
  args: [
    '--enable-unsafe-swiftshader',
    '--use-gl=swiftshader',
    '--disable-gpu-sandbox',
  ],
}
```

```bash
# Start Xvfb before tests:
Xvfb :99 -screen 0 1280x1024x24 &
sleep 2
DISPLAY=:99 npx playwright test ...
```

**Chrome args for SharedArrayBuffer:**
```
--disable-web-security
--allow-running-insecure-content
--autoplay-policy=no-user-gesture-required
```

These are set in `playwright.config.ts`.

---

## §2.3 — Audio pitch probes (FFT spectral analysis)

Audio correctness requires frequency-domain assertions, not just log-line grepping.

Pattern from `e2e/tim603-audio-pitch-probe.spec.ts`:

```ts
// Inject audio probe script that captures a frame of PCM:
await page.evaluate(() => {
  // ... capture audio buffer from Web Audio graph ...
  window.__audioProbe = { sampleRate, pcm };
});

// Retrieve and analyze:
const probe = await page.evaluate(() => (window as any).__audioProbe);
// FFT spectral centroid should match expected pitch
// RA: dominant peak < 90 Hz (menu music bass)
// TD: spectral centroid < 700 Hz (menu music)
```

**5/5 rule for audio verification:** WASM audio timing races are non-deterministic.
Require 5/5 cold-cache passes before marking audio verified. Clear browser profile
between runs. Never accept one green run as sufficient evidence.

---

## §2.4 — Pixel-range assertions (not fill% alone)

The smoke-test design rule requires visual assertions for rendering tests. Fill%
alone passes even when frames show block-aligned corruption.

**Good assertion patterns:**

```ts
// Pixel-range check (guards against cyan-block regression)
const stats = await page.evaluate(() => {
  const canvas = document.querySelector('canvas')!;
  const ctx = canvas.getContext('2d')!;
  const imageData = ctx.getImageData(0, 0, 640, 480);
  let cyanPixels = 0, warmPixels = 0;
  for (let i = 0; i < imageData.data.length; i += 4) {
    const [r, g, b] = [imageData.data[i], imageData.data[i+1], imageData.data[i+2]];
    if (g > 200 && b > 200 && r < 50) cyanPixels++;
    if (r > 100 || g > 100) warmPixels++;
  }
  return { cyanPct: cyanPixels / total, warmPct: warmPixels / total };
});
expect(stats.cyanPct).toBeLessThan(0.01);   // TIM-587: no cyan-block scatter
expect(stats.warmPct).toBeGreaterThan(0.01); // Game is rendering something
```

**Block-edge heuristic** (for codec tests): Check horizontal pixel-pair delta at
4-pixel grid lines to detect block-aligned corruption patterns.

**Screenshots:** Save a screenshot for every rendering test. Name it after the ticket:
`e2e/screenshots/tim{N}-{description}.png`. Upload as CI artifact on failure.

---

## §2.5 — Test discovery and grep filters

Tests are in `e2e/` with naming convention `tim{N}-{description}.spec.ts`.
Regression tests live in `e2e/regression/`.

**Running specific tiers:**
```bash
# All e2e tests:
npx playwright test

# Specific test file:
npx playwright test e2e/regression/T1-ra-wasm-boot.spec.ts

# Specific test by name pattern:
npx playwright test --grep "Tier 1"

# TD gameplay only:
npm run test:e2e:td

# RA WASM only:
npm run test:e2e:ra
```

**Test timeout:** 300,000ms (5 min) for full tests, 60,000ms for expect.
Set in `playwright.config.ts`.

---

## §2.6 — Xvfb display management

```bash
# Idempotent Xvfb start (reuses existing, kills stale, wait loop + EXIT trap):
source scripts/skill-xvfb-ensure.sh :99 1280x1024x24
```

Multiple Xvfb instances can coexist (use different display numbers: :98, :99).

---

## §3 — Regression tier structure

| Tier | Test | What it proves |
|------|------|---------------|
| T1 | `T1-ra-wasm-boot.spec.ts` | RA WASM boots without pageerror (30s observation) |
| T2 | `T2-td-wasm-boot.spec.ts` | TD WASM boots without pageerror |
| T3 | `T3-td-wasm-menu.spec.ts` | TD menu navigation works (real clicks) |
| T6 | `T6-td-wasm-mission-start.spec.ts` | TD GDI L1 mission starts via menu |
| T7 | `T7-td-audio-pitch.spec.ts` | TD audio pitch correct (FFT < 700 Hz) |
| T8 | `T8-ra-audio-pitch.spec.ts` | RA audio pitch correct (dominant < 90 Hz) |
| T9 | `T9-ra-wasm-mission-start.spec.ts` | RA Allied L1 mission starts |
| T10 | `T10-ra-menu-bleed.spec.ts` | RA post-game menu bleed (SSIM >= 0.90) |

T1–T2 are asset-free (no game data needed). T3–T10 require game data loaded via the
preloader's `showDirectoryPicker`.

---

## §4 — Writing a new test (checklist)

Before writing any test harness, follow `docs/smoke-test-design-rule.md`:

1. **Write assertions first.** Can you state `expect(...)` for every criterion?
2. **Header comment** lists numbered acceptance criteria.
3. **Each criterion maps to an `expect()`** with a named regression comment.
4. **Rendering tests** include at least one pixel-range or pixel-diff assertion.
5. **Audio tests** include at least one frequency-domain check.
6. **Save screenshot** on failure, named after the ticket.
7. **Name the failure mode** in each assertion comment.
   `// TIM-587: no cyan-block scatter` is correct. `// check frame` is not.

---

## §5 — Verification bar

| Gate | Command | Expected |
|------|---------|----------|
| Server starts | `python3 wasm/serve-coop.py &` | Serves on :8080 |
| T1 smoke | `npx playwright test e2e/regression/T1-ra-wasm-boot.spec.ts` | Pass |
| T2 smoke | `npx playwright test e2e/regression/T2-td-wasm-boot.spec.ts` | Pass |
| Full suite | `npx playwright test` | All passing or correctly skipping |

---

## Reference

- `playwright.config.ts` — Browser config, timeouts, baseURL
- `package.json` — npm scripts for test variants
- `docs/smoke-test-design-rule.md` — Assertion-first design rules
- `wasm/serve-coop.py` — Python dev server with COOP/COEP headers
- `wasm/nginx.conf` — Nginx config for WASM serving
- `e2e/` — Test files organized by TIM number and tier
- `docs/emscripten-playbook.md` — WASM-specific pitfalls affecting tests
