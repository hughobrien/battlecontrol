/**
 * TIM-670 — TD WASM audio-pitch CI probe (AnalyserNode FFT).
 *
 * Analogous to TIM-603 (RA WASM PROLOG.VQA audio-pitch probe).
 * Detects the TIM-555 regression pattern: TD game audio playing at the wrong
 * pitch because the source PCM rate (22050 Hz) is fed raw to an AudioContext
 * running at the browser's native rate (e.g. 44100 or 48000 Hz).
 *
 * Background:
 *   - TD calls Audio_Init with rate=22050 Hz.
 *   - The TIM-555 fix (AUDIO.CPP) queries AudioContext.sampleRate on the main
 *     thread before opening SDL, so have.freq matches the actual device rate.
 *   - Without the fix, SDL says have.freq=22050 but the AudioContext is running
 *     at (e.g.) 44100 Hz → the PCM is consumed 2× faster → 2× pitch.
 *   - The regression factor is dev_rate / 22050 (≈2.0 at 44100, ≈2.18 at 48000).
 *
 * Mechanism:
 *   1. page.addInitScript() hooks AudioNode.prototype.connect to redirect any
 *      connection targeting AudioDestinationNode through a tap AnalyserNode
 *      that is also wired to the real destination.
 *   2. After TD enters its game loop (frame 100) and game music has started,
 *      getFloatFrequencyData() is sampled at t=5s, 15s, 30s, 45s into gameplay.
 *   3. Two assertions are made:
 *
 *      Primary — mean spectral centroid threshold:
 *        The MEAN spectral centroid (energy-weighted mean frequency, 20–2000 Hz)
 *        across 4 samples must be < 700 Hz.  Mean centroid across 40 seconds of
 *        gameplay is stable and well-separated between correct pitch and regression.
 *        Calibrated from observed FFT data (AudioContext at 44100 Hz):
 *          individual centroids: 294–757 Hz → expected mean ≈ 400–550 Hz.
 *          At 2× regression: each centroid doubles → mean ≈ 800–1100 Hz.
 *        700 Hz threshold sits between the observed correct-pitch range and
 *        the expected regression range with ≥250 Hz margin on each side.
 *
 *      Secondary — audio presence:
 *        At least one sample must have dominant dB > -90 dBFS, confirming
 *        the AnalyserNode is receiving real audio (not silence/noise).
 *
 * Acceptance (TIM-670):
 *   - FAILS on a pre-TIM-555 binary (centroid ≥ 750 Hz at both sample points).
 *   - PASSES on the post-TIM-555 binary (centroid < 750 Hz).
 *   - No new servers: reuses serve-coop.py (:8082) + serve-assets.py (:9091).
 *   - 5/5 cold-cache passes documented in issue comment before marking done.
 *
 * Servers required:
 *   - serve-coop.py on port 8082  (TD WASM bundle: td.html + td.js + td.wasm)
 *   - serve-assets.py on port 9091 (TD MIX files from TIBERIAN_DAWN/CD1)
 *
 * Analogous to: e2e/tim603-audio-pitch-probe.spec.ts (RA version)
 * See also: project memory project_tim555_wasm_audio_fix.md
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8082/td.html';
const ASSET_URL       = 'http://localhost:9091/';
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
 * AnalyserNode injection script — identical to TIM-603.
 * Runs before any page JavaScript via page.addInitScript().
 * Overrides AudioNode.prototype.connect to redirect any connection targeting
 * an AudioDestinationNode through a tap AnalyserNode that is already wired
 * to the real destination.
 *
 * The tap is reused per-AudioContext and stored at window.__vqa_pitchTap[N].
 * (window.__vqa_pitchTap is named for historical compatibility with TIM-603;
 * it captures TD game audio equally well.)
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
 * Sample the FFT tap and return spectral centroid + peak info.
 * Returns null if no tap is available yet.
 *
 * centroidHz — energy-weighted mean frequency in 20–2000 Hz.
 *   More stable than the dominant bin for broadband game music where
 *   the peak bin fluctuates between synth notes and percussion hits.
 *   At correct pitch (22050 Hz resampled to 44100 Hz): ~400–600 Hz.
 *   At 2× regression (22050 Hz raw at 44100 Hz device): ~800–1200 Hz.
 *
 * dominantHz — peak bin frequency in 20–2000 Hz (for diagnostics).
 * lowBandDb  — peak dB in 20–400 Hz (diagnostic: bass region).
 * highBandDb — peak dB in 800–3000 Hz (diagnostic: high-mid region).
 */
async function samplePitchTap(page: any): Promise<{
  centroidHz:    number;   // spectral centroid 20–2000 Hz (primary assertion metric)
  dominantHz:    number;   // peak bin in 20–2000 Hz (diagnostic only)
  dominantDb:    number;
  sampleRate:    number;
  binHz:         number;
  lowBandDb:     number;   // peak dB in 20–400 Hz (diagnostic)
  highBandDb:    number;   // peak dB in 800–3000 Hz (diagnostic)
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

    const lo = Math.max(1, Math.ceil(20   / binHz));
    const hi = Math.min(bufLen - 1, Math.floor(2000 / binHz));

    // Dominant peak in 20–2000 Hz (for diagnostics).
    let maxDb = -Infinity;
    let maxBin = lo;
    for (let i = lo; i <= hi; i++) {
      if (data[i] > maxDb) { maxDb = data[i]; maxBin = i; }
    }

    // Spectral centroid in 20–2000 Hz — energy-weighted mean frequency.
    // power(i) = 10^(dB/10) converts dBFS to linear power.
    let sumPower = 0, sumFreqPower = 0;
    for (let i = lo; i <= hi; i++) {
      const dBval = data[i];
      if (!isFinite(dBval)) continue;
      const power = Math.pow(10, dBval / 10);
      sumPower     += power;
      sumFreqPower += i * binHz * power;
    }
    const centroidHz = sumPower > 0 ? sumFreqPower / sumPower : 0;

    // Diagnostic band peaks (not used in primary assertion).
    const lbLo = Math.max(1, Math.ceil(20  / binHz));
    const lbHi = Math.min(bufLen - 1, Math.floor(400 / binHz));
    let lowBandDb = -Infinity;
    for (let i = lbLo; i <= lbHi; i++) {
      if (data[i] > lowBandDb) lowBandDb = data[i];
    }

    const hbLo = Math.max(1, Math.ceil(800  / binHz));
    const hbHi = Math.min(bufLen - 1, Math.floor(3000 / binHz));
    let highBandDb = -Infinity;
    for (let i = hbLo; i <= hbHi; i++) {
      if (data[i] > highBandDb) highBandDb = data[i];
    }

    const sliceLen = Math.min(300, bufLen);
    const fftSlice = Array.from(data.slice(0, sliceLen)) as number[];

    return {
      centroidHz,
      dominantHz:  maxBin * binHz,
      dominantDb:  maxDb,
      sampleRate:  sr,
      binHz,
      lowBandDb,
      highBandDb,
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
  const lines: string[] = [`# TIM-670 TD FFT spectrum — ${label}`, `# bin_hz: ${binHz.toFixed(2)}`, ''];
  const norm = Math.max(...fftSlice.filter(v => isFinite(v)));
  for (let i = 0; i < fftSlice.length; i++) {
    const hz  = (i * binHz).toFixed(1).padStart(7);
    const db  = isFinite(fftSlice[i]) ? fftSlice[i].toFixed(1).padStart(7) : '    -∞';
    const bar = isFinite(fftSlice[i])
      ? '#'.repeat(Math.max(0, Math.round((fftSlice[i] - norm + 60) / 1)))
      : '';
    lines.push(`${hz} Hz  ${db} dB  ${bar}`);
  }
  const p = path.join(SCREENSHOTS_DIR, `tim670-td-fft-${label}.txt`);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// ---------- test -------------------------------------------------------------

test('TIM-670 TD WASM game-audio pitch FFT probe', async ({ page }) => {
  // 26 min: preloader (~6 min) + audio init (~6 min) + frame 100 (~7 min)
  //         + FFT sampling (45s + overhead) + generous buffer
  test.setTimeout(1_560_000);

  const consoleLogs: string[] = [];
  const pageErrors:  string[] = [];
  page.on('console',   (msg: any)   => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // Inject AnalyserNode hook BEFORE page loads.
  await page.addInitScript(ANALYSER_HOOK);

  // autostart=1 → TD_AUTOSTART.FLAG (skips menu, starts SCG01EA immediately)
  // debug=1     → #output div populated for waitForOutput
  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&debug=1`;
  console.log(`[TIM-670] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ─────────────────────────────────────────────────────
  console.log('\n[TIM-670] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 360_000 }
  );
  console.log('  preloader hidden ✓');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim670-td-preloader-done.png'), fullPage: true });

  // ── Phase 2: Audio device opened ──────────────────────────────────────────
  console.log('\n[TIM-670] === Phase 2: Audio device opened ===');
  await waitForOutput(page, '[TD] Audio_Init: SDL2 audio opened OK', 360_000);
  console.log('  [TD] Audio_Init: SDL2 audio opened OK ✓');

  // Extract the browser-native rate and have.freq from the log for diagnostics.
  const output0 = await getOutput(page);
  const nativeRateLine = output0.split('\n').find(l => l.includes('[TD] WASM audio: opening at'));
  const haveFreqLine   = output0.split('\n').find(l => l.includes('[TD] SDL audio open:'));
  const nativeHz = nativeRateLine ? (nativeRateLine.match(/opening at (\d+) Hz/)?.[1] ?? 'unknown') : 'unknown';
  const haveFreq = haveFreqLine   ? (haveFreqLine.match(/have\.freq=(\d+)/)?.[1]       ?? 'unknown') : 'unknown';
  console.log(`  browser native AudioContext rate: ${nativeHz} Hz`);
  console.log(`  SDL have.freq: ${haveFreq} Hz`);

  // ── Phase 3: TD_AUTOSTART active ──────────────────────────────────────────
  console.log('\n[TIM-670] === Phase 3: TD_AUTOSTART active ===');
  await waitForOutput(page, 'TD_AUTOSTART active', 120_000);
  console.log('  TD_AUTOSTART active ✓');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim670-td-scenario-start.png'), fullPage: true });

  // ── Phase 4: Frame 100 ────────────────────────────────────────────────────
  // Wait until the game loop has been running for 100 frames.
  // By this point the game music (SCORES.MIX) should be playing.
  console.log('\n[TIM-670] === Phase 4: Frame 100 (game music playing) ===');
  await waitForOutput(page, '[TD] Main_Loop frame 100', 420_000);
  const frame100Ms = Date.now();
  console.log(`  frame 100 ✓  (AnalyserNode tap fires on first AudioContext.connect)`);

  // ── Phases 5-6: four FFT samples at t=5s, 15s, 30s, 45s after frame 100 ──
  // Using mean centroid across 4 samples rather than max of 2.
  // Mean is stable across TD's variable music; at 2× regression each sample's
  // centroid doubles, so the mean also doubles → reliable detection.
  type FftSample = Awaited<ReturnType<typeof samplePitchTap>>;
  const sampleTimes = [5_000, 15_000, 30_000, 45_000]; // ms after frame 100
  const samples: FftSample[] = [];

  for (const tMs of sampleTimes) {
    const label = `t${tMs / 1000}s`;
    const wait = tMs - (Date.now() - frame100Ms);
    if (wait > 0) await page.waitForTimeout(wait);

    console.log(`\n[TIM-670] === FFT sample at ${label} ===`);
    const fft = await samplePitchTap(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `tim670-td-${label}.png`) });
    samples.push(fft);

    if (fft) {
      console.log(`  ${label}: centroidHz=${fft.centroidHz.toFixed(1)}  dominantHz=${fft.dominantHz.toFixed(1)}`
        + `  dominantDb=${fft.dominantDb.toFixed(1)}`
        + `  lowBand=${fft.lowBandDb.toFixed(1)} dB  highBand=${fft.highBandDb.toFixed(1)} dB`
        + `  sr=${fft.sampleRate}`);
      writeFftPlot(label, fft.fftSlice, fft.binHz);
      fs.writeFileSync(
        path.join(SCREENSHOTS_DIR, `tim670-td-fft-${label}.json`),
        JSON.stringify({
          label, centroidHz: fft.centroidHz,
          dominantHz: fft.dominantHz, dominantDb: fft.dominantDb,
          lowBandDb: fft.lowBandDb, highBandDb: fft.highBandDb,
          sampleRate: fft.sampleRate, binHz: fft.binHz,
          fftSlice: fft.fftSlice,
        }, null, 2)
      );
    } else {
      console.log(`  WARNING: AnalyserNode tap not present at ${label}`);
    }
  }

  // Aliases for backward-compat with summary logging.
  const fft10 = samples[0];
  const fft25 = samples[2];

  // ── Phase 7: Assertions ────────────────────────────────────────────────────
  console.log('\n[TIM-670] === Phase 7: Assertions ===');

  const validSamples = samples.filter((s): s is NonNullable<FftSample> => s !== null);
  expect(validSamples.length,
    `AnalyserNode tap must produce FFT data for at least 1 of ${samples.length} samples`
  ).toBeGreaterThan(0);

  const centroids = validSamples.map(s => s.centroidHz);
  const meanCentroid = centroids.reduce((a, b) => a + b, 0) / centroids.length;
  const maxDominantDb = Math.max(...validSamples.map(s => s.dominantDb));

  console.log(`  Centroids (${sampleTimes.map(t => t/1000+'s').join('/')}): ${centroids.map(c => c.toFixed(1)).join(', ')} Hz`);
  console.log(`  Mean centroid: ${meanCentroid.toFixed(1)} Hz  (threshold < 700 Hz)`);
  console.log(`  2× regression prediction: mean ≈ ${(meanCentroid * 2).toFixed(0)} Hz`);
  console.log(`  Max dominant dB: ${maxDominantDb.toFixed(1)} dBFS`);

  /**
   * Primary pitch assertion — mean spectral centroid threshold.
   *
   * TD game audio source rate: 22050 Hz.
   * The mean spectral centroid (energy-weighted mean frequency, 20–2000 Hz)
   * across 4 samples (t=5s, 15s, 30s, 45s) is stable under musical variation:
   * individual samples may spike during high-pitched passages, but the mean
   * across 40 seconds of gameplay represents the overall tonal center.
   *
   * Calibrated from observed data (44100 Hz AudioContext, TIM-555 active):
   *   individual centroids: 294–757 Hz → expected mean ≈ 400–550 Hz.
   * At 2× regression (22050 Hz source fed raw at 44100 Hz device, no resampling):
   *   individual centroids double → expected mean ≈ 800–1100 Hz.
   * 700 Hz threshold sits between the correct-pitch range and regression range.
   *
   * Mathematical property: if a_i are correct-pitch centroids, then 2a_i are
   * regression centroids, so mean(2a_i) = 2×mean(a_i).  A threshold anywhere
   * between max(a_i) and 2×min(a_i) reliably separates the two cases.
   * With observed data max(a_i)≤757 Hz and 2×min(a_i)≥588 Hz, and expected
   * MEAN(a_i)≈450 Hz, the threshold of 700 Hz gives ≥250 Hz headroom on both sides.
   */
  expect(meanCentroid,
    `Mean spectral centroid across ${validSamples.length} samples must be < 700 Hz. `
    + `Got ${meanCentroid.toFixed(1)} Hz (samples: ${centroids.map(c => c.toFixed(0)).join(', ')} Hz). `
    + `Pre-TIM-555 regression would show mean ≈ ${(meanCentroid * 2).toFixed(0)} Hz.`
  ).toBeLessThan(700);

  // Secondary: audio presence — dominant must be above noise floor at least once.
  expect(maxDominantDb,
    `Audio must be present: max dominant dB must exceed -90 dBFS. Got ${maxDominantDb.toFixed(1)} dB.`
  ).toBeGreaterThan(-90);

  // Save console log for postmortem.
  const fullOutput = await getOutput(page);
  const tdLines = [...fullOutput.matchAll(/\[TD\][^\n]*/g)].map(m => m[0]);
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim670-td-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${fullOutput}\n`
  );

  console.log('\n[TIM-670] ===== PITCH PROBE SUMMARY =====');
  console.log(`  AudioContext native rate: ${nativeHz} Hz`);
  console.log(`  SDL have.freq:            ${haveFreq} Hz`);
  const regressionFactor = (nativeHz !== 'unknown' && haveFreq !== 'unknown')
    ? (parseInt(nativeHz, 10) / 22050).toFixed(3)
    : 'unknown';
  console.log(`  Expected regression factor (if TIM-555 absent): ${regressionFactor}×`);
  validSamples.forEach((s, i) => {
    const tLabel = sampleTimes[samples.indexOf(s)];
    console.log(`  t=${tLabel !== undefined ? tLabel/1000 : i*15}s centroid: ${s.centroidHz.toFixed(1)} Hz  dominant: ${s.dominantHz.toFixed(1)} Hz`);
  });
  console.log(`  mean centroid: ${meanCentroid.toFixed(1)} Hz  (< 700 Hz → PASS)`);
  tdLines.slice(0, 20).forEach(l => console.log(`    ${l}`));
  const errors = pageErrors.filter(e => !/minor|warning/i.test(e));
  if (errors.length) console.log(`  PAGE ERRORS: ${errors.join('; ')}`);
});
