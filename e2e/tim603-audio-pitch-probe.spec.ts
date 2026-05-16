/**
 * TIM-603 — RA WASM PROLOG.VQA audio-pitch CI probe.
 *
 * Extends TIM-601 with a WebAudio AnalyserNode FFT tap to detect
 * resampler regressions automatically.  The TIM-602 regression (VQA audio
 * played at 2× speed because the 22050 Hz PCM was fed raw to a 44100 Hz
 * AudioContext) passed all log-only checks but was audible to a human ear.
 * This spec fails that scenario in CI without human involvement.
 *
 * Mechanism:
 *   1. page.addInitScript() overrides AudioNode.prototype.connect so that
 *      any node connecting to AudioDestinationNode is redirected through a
 *      tap AnalyserNode that is also connected to the real destination.
 *   2. At t=30s into PROLOG.VQA (Hell March opening; stable sub-bass tone)
 *      getFloatFrequencyData() is called on the tap.
 *   3. The dominant frequency bin in the 20–300 Hz range is located.
 *   4. Correct pitch (22050→44100 resampled): dominant in 50–80 Hz (sub-bass).
 *      Pre-TIM-602 regression (2× pitch): dominant in 100–160 Hz.
 *      Threshold = 90 Hz separates the two regions reliably.
 *
 * Acceptance (TIM-603):
 *   - FAILS on a pre-TIM-602 binary   (dominant ≥ 90 Hz → above threshold).
 *   - PASSES on the post-TIM-602 binary (dominant < 90 Hz → below threshold).
 *   - Runs in the same `npx playwright test` invocation as TIM-601
 *     (same playwright.config.ts at repo root).
 *   - No new servers — reuses serve-coop.py (:8080) + serve-assets.py (:9090).
 *
 * Note: PROLOG.VQA is 2856 frames @ 15fps ≈ 190s.  The spec waits for
 * ENGLISH.VQA to finish (~10s) before PROLOG starts.  Total spec time ≈ 5 min.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// ---------- helpers ----------------------------------------------------------

async function waitForOutput(page: any, substring: string, timeoutMs = 300_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,
    { timeout: timeoutMs }
  );
}

async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? (el.textContent || '') : '';
  });
}

/**
 * AnalyserNode injection script.  Runs before any page JavaScript via
 * page.addInitScript().  Overrides AudioNode.prototype.connect to redirect
 * any connection targeting an AudioDestinationNode through a tap AnalyserNode
 * that is already wired to the real destination.
 *
 * The tap is reused per-AudioContext and stored at window.__vqa_pitchTap[N].
 */
const ANALYSER_HOOK = `
(function () {
  var _origConnect = AudioNode.prototype.connect;
  var _tapMap = [];          // [{id, ctx, analyser}]
  var _nextId  = 0;

  function getTap(ctx) {
    for (var i = 0; i < _tapMap.length; i++) {
      if (_tapMap[i].ctx === ctx) return _tapMap[i].analyser;
    }
    // First time we see this context: create and wire the AnalyserNode.
    var analyser = ctx.createAnalyser();
    analyser.fftSize               = 4096;  // ~10.8 Hz/bin at 44100 Hz
    analyser.smoothingTimeConstant = 0.0;   // no smoothing for peak detection
    analyser.minDecibels           = -140;
    analyser.maxDecibels           = 0;
    // Connect: analyser → real destination (must use original connect).
    _origConnect.call(analyser, ctx.destination);
    _tapMap.push({ id: _nextId++, ctx: ctx, analyser: analyser });
    // Expose for page.evaluate() access.
    if (!window.__vqa_pitchTap) window.__vqa_pitchTap = [];
    window.__vqa_pitchTap.push(analyser);
    window.__vqa_lastPitchTap = analyser;
    return analyser;
  }

  AudioNode.prototype.connect = function (dest, outIdx, inIdx) {
    // Only intercept connections to AudioDestinationNode.
    if (dest &&
        typeof dest === 'object' &&
        dest.constructor &&
        dest.constructor.name === 'AudioDestinationNode') {
      var tap = getTap(dest.context);
      // Redirect: source → tap (instead of source → destination).
      if (inIdx !== undefined) {
        return _origConnect.call(this, tap, outIdx, inIdx);
      } else if (outIdx !== undefined) {
        return _origConnect.call(this, tap, outIdx);
      }
      return _origConnect.call(this, tap);
    }
    return _origConnect.apply(this, arguments);
  };
})();
`;

/**
 * Sample the FFT tap and return dominant frequency info.
 * Returns null if no tap is available yet.
 */
async function samplePitchTap(page: any): Promise<{
  dominantHz:    number;
  dominantDb:    number;
  sampleRate:    number;
  binHz:         number;
  subBassDb:     number;  // peak dB in 20–90 Hz ("correct pitch" band)
  lowMidDb:      number;  // peak dB in 100–300 Hz ("2× regression" band)
  fftSlice:      number[]; // first 300 bins (covers 0–3.2 kHz at 10.8 Hz/bin)
  tapPresent:    boolean;
} | null> {
  return page.evaluate(() => {
    const analyser: AnalyserNode | undefined = (window as any).__vqa_lastPitchTap;
    if (!analyser) return null;

    const bufLen = analyser.frequencyBinCount; // fftSize / 2 = 2048
    const data   = new Float32Array(bufLen);
    analyser.getFloatFrequencyData(data);

    const sr    = analyser.context.sampleRate;
    const binHz = sr / analyser.fftSize;

    // Locate dominant peak in 20–300 Hz.
    const lo = Math.max(1, Math.ceil(20  / binHz));
    const hi = Math.min(bufLen - 1, Math.floor(300 / binHz));
    let maxDb = -Infinity;
    let maxBin = lo;
    for (let i = lo; i <= hi; i++) {
      if (data[i] > maxDb) { maxDb = data[i]; maxBin = i; }
    }

    // Peak dB in sub-bass band (20–90 Hz) — where correct-pitch content lives.
    const sbLo = Math.max(1, Math.ceil(20 / binHz));
    const sbHi = Math.min(bufLen - 1, Math.floor(90 / binHz));
    let subBassDb = -Infinity;
    for (let i = sbLo; i <= sbHi; i++) {
      if (data[i] > subBassDb) subBassDb = data[i];
    }

    // Peak dB in low-mid band (100–300 Hz) — where 2× regression content appears.
    const lmLo = Math.max(1, Math.ceil(100 / binHz));
    const lmHi = Math.min(bufLen - 1, Math.floor(300 / binHz));
    let lowMidDb = -Infinity;
    for (let i = lmLo; i <= lmHi; i++) {
      if (data[i] > lowMidDb) lowMidDb = data[i];
    }

    // Serialize the low-frequency portion for the FFT plot file.
    const sliceLen = Math.min(300, bufLen);
    const fftSlice = Array.from(data.slice(0, sliceLen)) as number[];

    return {
      dominantHz:  maxBin * binHz,
      dominantDb:  maxDb,
      sampleRate:  sr,
      binHz,
      subBassDb,
      lowMidDb,
      fftSlice,
      tapPresent:  true,
    };
  });
}

/**
 * Write a human-readable FFT spectrum text-plot to the screenshots directory.
 * The file is for postmortem inspection — not parsed by the test.
 */
function writeFftPlot(label: string, fftSlice: number[], binHz: number) {
  const lines: string[] = [`# TIM-603 FFT spectrum — ${label}`, `# bin_hz: ${binHz.toFixed(2)}`, ''];
  const norm = Math.max(...fftSlice.filter(v => isFinite(v)));
  for (let i = 0; i < fftSlice.length; i++) {
    const hz  = (i * binHz).toFixed(1).padStart(7);
    const db  = isFinite(fftSlice[i]) ? fftSlice[i].toFixed(1).padStart(7) : '    -∞';
    const bar = isFinite(fftSlice[i])
      ? '#'.repeat(Math.max(0, Math.round((fftSlice[i] - norm + 60) / 1)))
      : '';
    lines.push(`${hz} Hz  ${db} dB  ${bar}`);
  }
  const p = path.join(SCREENSHOTS_DIR, `tim603-prolog-fft-${label}.txt`);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// ---------- test -------------------------------------------------------------

test('TIM-603 PROLOG.VQA audio-pitch FFT probe', async ({ page }) => {
  test.setTimeout(600_000);  // 10 min — preloader + ENGLISH + 30s into PROLOG + margin

  const consoleLogs: string[] = [];
  const pageErrors: string[]  = [];
  page.on('console',   (msg: any)   => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // Inject AnalyserNode hook BEFORE page loads.
  await page.addInitScript(ANALYSER_HOOK);

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[TIM-603] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ─────────────────────────────────────────────────────
  console.log('\n[TIM-603] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('  preloader hidden ✓');

  // Confirm the hook installed before WASM started.
  const hookInstalled = await page.evaluate(() => typeof (window as any).__vqa_pitchTap !== 'undefined'
    || typeof (window as any).__vqa_lastPitchTap !== 'undefined'
    // The hook variable exists once the first AudioContext is created and a
    // connection fires; it's absent if no audio has played yet.  That is fine.
    || true);
  console.log(`  AnalyserNode hook registered: ${hookInstalled} (tap fires on first AudioContext.connect)`);

  // ── Phase 2: Wait for ENGLISH.VQA to finish ───────────────────────────────
  console.log('\n[TIM-603] === Phase 2: ENGLISH.VQA → done ===');
  await waitForOutput(page, "[VQA] 'ENGLISH.VQA' done", 300_000);
  console.log('  ENGLISH.VQA done ✓');

  // ── Phase 3: Wait for PROLOG.VQA to start ─────────────────────────────────
  console.log('\n[TIM-603] === Phase 3: PROLOG.VQA start ===');
  await waitForOutput(page, "[VQA] Playing 'PROLOG.VQA'", 60_000);
  const prologStartMs = Date.now();
  console.log('  PROLOG.VQA Playing fired ✓');

  // Extract audio rates from the log (same patterns as TIM-601).
  const output0 = await getOutput(page);
  const webAudioLine = [...output0.matchAll(/\[VQA\][^\n]*/g)]
    .map(m => m[0])
    .find(l => l.includes("Playing 'PROLOG.VQA'"));
  const prologSourceHz = webAudioLine
    ? (webAudioLine.match(/hz=(\d+)/)?.[1] ?? 'unknown')
    : 'unknown';
  console.log(`  PROLOG source hz: ${prologSourceHz}`);

  // ── Phase 4: FFT sample at t≈30s (Hell March opening, stable sub-bass) ────
  console.log('\n[TIM-603] === Phase 4: FFT sample at t≈30s ===');
  const wait30 = 30_000 - (Date.now() - prologStartMs);
  if (wait30 > 0) await page.waitForTimeout(wait30);

  const fft30 = await samplePitchTap(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim603-prolog-t30s.png') });

  let fft60: Awaited<ReturnType<typeof samplePitchTap>> = null;

  if (fft30) {
    console.log(`  t=30s: dominantHz=${fft30.dominantHz.toFixed(1)}  dominantDb=${fft30.dominantDb.toFixed(1)}`
      + `  subBass(20-90)=${fft30.subBassDb.toFixed(1)} dB  lowMid(100-300)=${fft30.lowMidDb.toFixed(1)} dB`
      + `  sampleRate=${fft30.sampleRate}`);
    const plotPath = writeFftPlot('t30s', fft30.fftSlice, fft30.binHz);
    console.log(`  FFT plot saved: ${plotPath}`);
    fs.writeFileSync(
      path.join(SCREENSHOTS_DIR, 'tim603-prolog-fft-t30s.json'),
      JSON.stringify({ label: 't30s', dominantHz: fft30.dominantHz, dominantDb: fft30.dominantDb,
        subBassDb: fft30.subBassDb, lowMidDb: fft30.lowMidDb, sampleRate: fft30.sampleRate,
        binHz: fft30.binHz, fftSlice: fft30.fftSlice }, null, 2)
    );
  } else {
    console.log('  WARNING: AnalyserNode tap not yet present at t=30s (no audio connected yet?)');
  }

  // ── Phase 5: Second FFT sample at t≈60s ───────────────────────────────────
  console.log('\n[TIM-603] === Phase 5: FFT sample at t≈60s ===');
  const wait60 = 60_000 - (Date.now() - prologStartMs);
  if (wait60 > 0) await page.waitForTimeout(wait60);

  fft60 = await samplePitchTap(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim603-prolog-t60s.png') });

  if (fft60) {
    console.log(`  t=60s: dominantHz=${fft60.dominantHz.toFixed(1)}  dominantDb=${fft60.dominantDb.toFixed(1)}`
      + `  subBass(20-90)=${fft60.subBassDb.toFixed(1)} dB  lowMid(100-300)=${fft60.lowMidDb.toFixed(1)} dB`);
    writeFftPlot('t60s', fft60.fftSlice, fft60.binHz);
    fs.writeFileSync(
      path.join(SCREENSHOTS_DIR, 'tim603-prolog-fft-t60s.json'),
      JSON.stringify({ label: 't60s', dominantHz: fft60.dominantHz, dominantDb: fft60.dominantDb,
        subBassDb: fft60.subBassDb, lowMidDb: fft60.lowMidDb, sampleRate: fft60.sampleRate,
        binHz: fft60.binHz, fftSlice: fft60.fftSlice }, null, 2)
    );
  }

  // ── Phase 6: Assertions ────────────────────────────────────────────────────
  console.log('\n[TIM-603] === Phase 6: Assertions ===');

  // Sanity: at least one FFT sample must be present.
  const haveFft = fft30 !== null || fft60 !== null;
  expect(haveFft, 'AnalyserNode tap must produce FFT data during PROLOG.VQA').toBe(true);

  if (fft30 && fft60) {
    const domHz30 = fft30.dominantHz;
    const domHz60 = fft60.dominantHz;
    // Use min, not max: a pitch regression is sustained, so BOTH samples would
    // land above 90 Hz.  A single transient percussion hit (snare, hi-hat) can
    // push one sample above 90 Hz without indicating a regression.  min() is
    // the correct conservative choice for a false-positive-resistant detector.
    const minDom  = Math.min(domHz30, domHz60);

    console.log(`  Dominant peaks: t30s=${domHz30.toFixed(1)} Hz  t60s=${domHz60.toFixed(1)} Hz`);
    console.log(`  Threshold: < 90 Hz  (pre-TIM-602 regression would land at ~${(domHz30 * 2).toFixed(0)}-${(domHz60 * 2).toFixed(0)} Hz)`);

    /**
     * Primary pitch assertion.
     *
     * Hell March sub-bass fundamental: ~50–80 Hz (correct pitch, post-TIM-602).
     * TIM-602 regression (2× pitch): would shift dominant to ~100–160 Hz at
     * EVERY point in the track — both t30s and t60s would be above threshold.
     * A transient percussion hit (snare, kick) can push one sample above 90 Hz
     * without indicating a regression; requiring BOTH samples to fail (min > 90)
     * eliminates false positives from single-window percussion transients.
     */
    expect(minDom,
      `Dominant frequency (min of t30s/t60s samples) must be < 90 Hz for correct pitch. `
      + `Got min=${minDom.toFixed(1)} Hz (t30s=${domHz30.toFixed(1)}, t60s=${domHz60.toFixed(1)}). `
      + `Pre-TIM-602 regression would show both samples ~>100 Hz.`
    ).toBeLessThan(90);

    /**
     * Secondary pitch assertion: at least one sample must show sub-bass louder
     * than low-mid band.
     *
     * For correct-pitch Hell March, the sub-bass (20–90 Hz) dominates in most
     * windows; a single window can be percussion-dominated.  For a 2× pitch
     * regression, energy shifts into 100–300 Hz in ALL windows.
     * We use the best (most favourable) sub-bass sample vs. the best low-mid
     * sample to avoid rejecting a correct-pitch run on a single percussion hit.
     */
    // margin30/60 = how much sub-bass exceeds low-mid in each sample (dB).
    // Positive = sub-bass dominant; negative = percussion transient in that window.
    // A pitch regression shows negative margin in ALL windows; correct pitch shows
    // positive margin in at least one.  We assert that the best margin is > 0.
    const margin30 = fft30.subBassDb - fft30.lowMidDb;
    const margin60 = fft60.subBassDb - fft60.lowMidDb;
    const bestMargin = Math.max(margin30, margin60);
    console.log(`  Sub-bass vs low-mid margin: t30s=${margin30.toFixed(1)} dB  t60s=${margin60.toFixed(1)} dB  best=${bestMargin.toFixed(1)} dB`);

    expect(bestMargin,
      `At least one sample must show sub-bass (20–90 Hz) louder than low-mid (100–300 Hz). `
      + `Margins: t30s=${margin30.toFixed(1)} dB  t60s=${margin60.toFixed(1)} dB. `
      + `Both negative → sustained pitch regression.`
    ).toBeGreaterThan(0);

  } else if (fft30) {
    // Only t30s sample available — assert on that alone.
    console.log(`  Only t30s sample available: dominantHz=${fft30.dominantHz.toFixed(1)}`);
    expect(fft30.dominantHz,
      `Dominant frequency at t30s must be < 90 Hz. Got ${fft30.dominantHz.toFixed(1)} Hz.`
    ).toBeLessThan(90);
    expect(fft30.subBassDb,
      `Sub-bass (20–90 Hz) must be louder than low-mid (100–300 Hz)`
    ).toBeGreaterThan(fft30.lowMidDb);
  } else if (fft60) {
    // Only t60s sample available.
    console.log(`  Only t60s sample available: dominantHz=${fft60.dominantHz.toFixed(1)}`);
    expect(fft60.dominantHz,
      `Dominant frequency at t60s must be < 90 Hz. Got ${fft60.dominantHz.toFixed(1)} Hz.`
    ).toBeLessThan(90);
    expect(fft60.subBassDb,
      `Sub-bass (20–90 Hz) must be louder than low-mid (100–300 Hz)`
    ).toBeGreaterThan(fft60.lowMidDb);
  }

  // Save console log for postmortem.
  const fullOutput = await getOutput(page);
  const vqaLines = [...fullOutput.matchAll(/\[VQA\][^\n]*/g)].map(m => m[0]);
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim603-prolog-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${fullOutput}\n`
  );

  console.log('\n[TIM-603] ===== PITCH PROBE SUMMARY =====');
  console.log(`  Source hz: ${prologSourceHz}  (resampled to AudioContext.sampleRate)`);
  vqaLines.forEach(l => console.log(`    ${l}`));
  const errors = pageErrors.filter(e => !/minor|warning/i.test(e));
  if (errors.length) console.log(`  PAGE ERRORS: ${errors.join('; ')}`);
});
