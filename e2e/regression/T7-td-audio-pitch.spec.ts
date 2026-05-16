/**
 * T7 — TD WASM audio pitch probe (TIM-767).
 *
 * Regression gate: detects the TIM-555 class of pitch regression where the
 * TD game audio plays at the wrong pitch because the 22050 Hz PCM source rate
 * is fed raw to an AudioContext running at the browser's native rate
 * (44100 or 48000 Hz), causing audio to play 2–2.18× too fast.
 *
 * Mechanism (identical to TIM-670 / TIM-603 RA WASM counterpart):
 *   1. page.addInitScript() overrides AudioNode.prototype.connect to redirect
 *      any connection targeting AudioDestinationNode through a tap AnalyserNode
 *      wired to the real destination.
 *   2. After the TD game loop reaches frame 100 (game music from SCORES.MIX
 *      is playing), getFloatFrequencyData() is sampled twice: t=5 s and t=20 s
 *      after frame 100.
 *   3. Two assertions:
 *
 *      Primary — mean spectral centroid threshold:
 *        Mean energy-weighted centroid (20–2000 Hz) across both samples < 700 Hz.
 *        Calibrated from TIM-670 observations (44100 Hz AudioContext, TIM-555 fix):
 *          individual centroids: 294–757 Hz → mean ≈ 400–550 Hz.
 *        At 2× regression: centroids double → mean ≈ 800–1100 Hz.
 *        700 Hz threshold sits halfway between correct-pitch and regression ranges.
 *
 *      Secondary — audio presence:
 *        At least one sample must have dominant dB > −90 dBFS (real audio, not silence).
 *
 * CI characteristics:
 *   - Skipped when TD_ASSETS_URL is not set (asset-gated, same as T3/T6).
 *   - Budget: 600 s.  With CDN assets T3 shows ~120 s to main menu;
 *     autostart=1 reaches frame 100 in ~180 s, then +25 s sampling = ~205 s total.
 *   - Servers required: serve-coop.py on :8080 (started by CI workflow).
 *     Assets come from TD_ASSETS_URL (CDN) or fallback to local :9091.
 *
 * Analogous to:
 *   e2e/tim670-td-audio-pitch.spec.ts   — full dev spec (TIM-670), 26 min budget
 *   e2e/regression/T4-ra-wasm-vqa.spec.ts — RA VQA CI gate pattern
 *   e2e/tim603-audio-pitch-probe.spec.ts  — RA VQA audio pitch spec (TIM-603)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/td.html';
const ASSET_URL       = process.env['TD_ASSETS_URL'] || 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// ---------- helpers ----------------------------------------------------------

async function waitForOutput(page: any, substring: string, timeoutMs: number) {
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
 * AnalyserNode injection script — identical to TIM-670 / TIM-603.
 * Runs before any page JS via page.addInitScript().  Overrides
 * AudioNode.prototype.connect to redirect any connection targeting
 * AudioDestinationNode through a tap AnalyserNode wired to the real destination.
 */
const ANALYSER_HOOK = `
(function () {
  var _origConnect = AudioNode.prototype.connect;
  var _tapMap = [];
  var _nextId  = 0;

  function getTap(ctx) {
    for (var i = 0; i < _tapMap.length; i++) {
      if (_tapMap[i].ctx === ctx) return _tapMap[i].analyser;
    }
    var analyser = ctx.createAnalyser();
    analyser.fftSize               = 4096;
    analyser.smoothingTimeConstant = 0.0;
    analyser.minDecibels           = -140;
    analyser.maxDecibels           = 0;
    _origConnect.call(analyser, ctx.destination);
    _tapMap.push({ id: _nextId++, ctx: ctx, analyser: analyser });
    if (!window.__vqa_pitchTap) window.__vqa_pitchTap = [];
    window.__vqa_pitchTap.push(analyser);
    window.__vqa_lastPitchTap = analyser;
    return analyser;
  }

  AudioNode.prototype.connect = function (dest, outIdx, inIdx) {
    if (dest &&
        typeof dest === 'object' &&
        dest.constructor &&
        dest.constructor.name === 'AudioDestinationNode') {
      var tap = getTap(dest.context);
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
 * Returns null if no tap is present yet.
 *
 * centroidHz — energy-weighted mean frequency in 20–2000 Hz.
 *   More stable than the dominant bin for broadband game music.
 *   Correct pitch (TIM-555 fix active): ~400–600 Hz mean.
 *   2× regression (no fix): ~800–1200 Hz mean.
 */
async function samplePitchTap(page: any): Promise<{
  centroidHz:  number;
  dominantHz:  number;
  dominantDb:  number;
  sampleRate:  number;
  binHz:       number;
  lowBandDb:   number;  // peak dB in 20–400 Hz (diagnostic)
  highBandDb:  number;  // peak dB in 800–3000 Hz (diagnostic)
  fftSlice:    number[]; // first 300 bins (~0–3.2 kHz at 10.8 Hz/bin)
  tapPresent:  boolean;
} | null> {
  return page.evaluate(() => {
    const analyser: AnalyserNode | undefined = (window as any).__vqa_lastPitchTap;
    if (!analyser) return null;

    const bufLen = analyser.frequencyBinCount;
    const data   = new Float32Array(bufLen);
    analyser.getFloatFrequencyData(data);

    const sr    = analyser.context.sampleRate;
    const binHz = sr / analyser.fftSize;

    const lo = Math.max(1, Math.ceil(20   / binHz));
    const hi = Math.min(bufLen - 1, Math.floor(2000 / binHz));

    let maxDb = -Infinity, maxBin = lo;
    for (let i = lo; i <= hi; i++) {
      if (data[i] > maxDb) { maxDb = data[i]; maxBin = i; }
    }

    let sumPower = 0, sumFreqPower = 0;
    for (let i = lo; i <= hi; i++) {
      const dBval = data[i];
      if (!isFinite(dBval)) continue;
      const power = Math.pow(10, dBval / 10);
      sumPower     += power;
      sumFreqPower += i * binHz * power;
    }
    const centroidHz = sumPower > 0 ? sumFreqPower / sumPower : 0;

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

    const fftSlice = Array.from(data.slice(0, Math.min(300, bufLen))) as number[];

    return {
      centroidHz,
      dominantHz: maxBin * binHz,
      dominantDb: maxDb,
      sampleRate: sr,
      binHz,
      lowBandDb,
      highBandDb,
      fftSlice,
      tapPresent: true,
    };
  });
}

function writeFftPlot(label: string, fftSlice: number[], binHz: number) {
  const lines: string[] = [`# T7 TD WASM audio pitch — ${label}`, `# bin_hz: ${binHz.toFixed(2)}`, ''];
  const norm = Math.max(...fftSlice.filter(v => isFinite(v)));
  for (let i = 0; i < fftSlice.length; i++) {
    const hz  = (i * binHz).toFixed(1).padStart(7);
    const db  = isFinite(fftSlice[i]) ? fftSlice[i].toFixed(1).padStart(7) : '    -∞';
    const bar = isFinite(fftSlice[i])
      ? '#'.repeat(Math.max(0, Math.round((fftSlice[i] - norm + 60) / 1)))
      : '';
    lines.push(`${hz} Hz  ${db} dB  ${bar}`);
  }
  const p = path.join(SCREENSHOTS_DIR, `t7-td-audio-fft-${label}.txt`);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// ---------- test -------------------------------------------------------------

test('T7 — TD WASM game audio pitch probe (centroid < 700 Hz → correct pitch)', async ({ page }) => {
  // 600 s: ~120 s asset load + ~60 s boot + autostart to frame 100 (~180 s) +
  // 25 s FFT sampling + buffer.  CDN assets (TD_ASSETS_URL) are required.
  test.setTimeout(600_000);

  if (!process.env['TD_ASSETS_URL']) {
    test.skip(true, 'T7 skipped — TD_ASSETS_URL not set');
    return;
  }

  const consoleLogs: string[] = [];
  const pageErrors:  string[] = [];
  page.on('console',   (msg: any)   => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // Inject AnalyserNode hook BEFORE page loads.
  await page.addInitScript(ANALYSER_HOOK);

  // autostart=1 → TD_AUTOSTART.FLAG (skips menu, starts SCG01EA immediately).
  // debug=1 → populates #output div for waitForOutput().
  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&debug=1`;
  console.log(`[T7] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── 1. Preloader ─────────────────────────────────────────────────────────
  console.log('\n[T7] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[T7] preloader hidden ✓');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't7-td-01-preloader.png') });

  // ── 2. Audio device opened ──────────────────────────────────────────────
  console.log('\n[T7] === Phase 2: Audio device ===');
  await waitForOutput(page, '[TD] Audio_Init: SDL2 audio opened OK', 120_000);
  console.log('[T7] SDL2 audio opened ✓');

  const output0 = await getOutput(page);
  const nativeRateLine = output0.split('\n').find(l => l.includes('[TD] WASM audio: opening at'));
  const haveFreqLine   = output0.split('\n').find(l => l.includes('[TD] SDL audio open:'));
  const nativeHz = nativeRateLine ? (nativeRateLine.match(/opening at (\d+) Hz/)?.[1] ?? 'unknown') : 'unknown';
  const haveFreq = haveFreqLine   ? (haveFreqLine.match(/have\.freq=(\d+)/)?.[1]       ?? 'unknown') : 'unknown';
  console.log(`[T7] browser native AudioContext rate: ${nativeHz} Hz`);
  console.log(`[T7] SDL have.freq: ${haveFreq} Hz`);

  // ── 3. Frame 100 (game music playing) ──────────────────────────────────
  console.log('\n[T7] === Phase 3: Frame 100 ===');
  await waitForOutput(page, '[TD] Main_Loop frame 100', 300_000);
  const frame100Ms = Date.now();
  console.log('[T7] frame 100 ✓');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't7-td-02-frame100.png') });

  // ── 4–5. FFT samples at t=5 s and t=20 s after frame 100 ──────────────
  type FftSample = Awaited<ReturnType<typeof samplePitchTap>>;
  const sampleTimes = [5_000, 20_000]; // ms after frame 100
  const samples: FftSample[] = [];

  for (const tMs of sampleTimes) {
    const label = `t${tMs / 1000}s`;
    const wait  = tMs - (Date.now() - frame100Ms);
    if (wait > 0) await page.waitForTimeout(wait);

    console.log(`\n[T7] === FFT sample at ${label} ===`);
    const fft = await samplePitchTap(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `t7-td-03-${label}.png`) });
    samples.push(fft);

    if (fft) {
      console.log(`[T7] ${label}: centroid=${fft.centroidHz.toFixed(1)} Hz  dominant=${fft.dominantHz.toFixed(1)} Hz  dominantDb=${fft.dominantDb.toFixed(1)} dBFS  sr=${fft.sampleRate}`);
      writeFftPlot(label, fft.fftSlice, fft.binHz);
      fs.writeFileSync(
        path.join(SCREENSHOTS_DIR, `t7-td-fft-${label}.json`),
        JSON.stringify({
          label, centroidHz: fft.centroidHz,
          dominantHz: fft.dominantHz, dominantDb: fft.dominantDb,
          lowBandDb: fft.lowBandDb, highBandDb: fft.highBandDb,
          sampleRate: fft.sampleRate, binHz: fft.binHz,
          fftSlice: fft.fftSlice,
        }, null, 2)
      );
    } else {
      console.log(`[T7] WARNING: AnalyserNode tap not present at ${label}`);
    }
  }

  // ── 6. Assertions ─────────────────────────────────────────────────────
  console.log('\n[T7] === Phase 6: Assertions ===');

  const validSamples = samples.filter((s): s is NonNullable<FftSample> => s !== null);
  expect(validSamples.length,
    `AnalyserNode tap must produce FFT data for at least 1 of ${samples.length} samples`
  ).toBeGreaterThan(0);

  const centroids     = validSamples.map(s => s.centroidHz);
  const meanCentroid  = centroids.reduce((a, b) => a + b, 0) / centroids.length;
  const maxDominantDb = Math.max(...validSamples.map(s => s.dominantDb));

  console.log(`[T7] Centroids (t5s/t20s): ${centroids.map(c => c.toFixed(1)).join(', ')} Hz`);
  console.log(`[T7] Mean centroid: ${meanCentroid.toFixed(1)} Hz  (threshold < 700 Hz)`);
  console.log(`[T7] 2× regression prediction: mean ≈ ${(meanCentroid * 2).toFixed(0)} Hz`);
  console.log(`[T7] Max dominant dB: ${maxDominantDb.toFixed(1)} dBFS`);

  /**
   * Primary: mean spectral centroid < 700 Hz.
   *
   * TD game audio source rate: 22050 Hz.
   * Calibrated from TIM-670 (44100 Hz AudioContext, TIM-555 fix active):
   *   individual centroids: 294–757 Hz → mean ≈ 400–550 Hz.
   * At 2× regression (no TIM-555 fix):
   *   centroids double → mean ≈ 800–1100 Hz.
   * 700 Hz gives ≥150 Hz margin on each side of the calibrated ranges.
   */
  expect(meanCentroid,
    `Mean spectral centroid across ${validSamples.length} samples must be < 700 Hz. `
    + `Got ${meanCentroid.toFixed(1)} Hz (samples: ${centroids.map(c => c.toFixed(0)).join(', ')} Hz). `
    + `Pre-TIM-555 regression would show mean ≈ ${(meanCentroid * 2).toFixed(0)} Hz.`
  ).toBeLessThan(700);

  // Secondary: audio must be present — dominant dB > noise floor.
  expect(maxDominantDb,
    `Audio must be present: max dominant dB must exceed −90 dBFS. Got ${maxDominantDb.toFixed(1)} dBFS.`
  ).toBeGreaterThan(-90);

  // Save console log for postmortem.
  const fullOutput = await getOutput(page);
  const tdLines    = [...fullOutput.matchAll(/\[TD\][^\n]*/g)].map(m => m[0]);
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 't7-td-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${fullOutput}\n`
  );

  console.log('\n[T7] ===== PITCH PROBE SUMMARY =====');
  console.log(`  AudioContext native rate:  ${nativeHz} Hz`);
  console.log(`  SDL have.freq:             ${haveFreq} Hz`);
  validSamples.forEach((s, i) => {
    const tLabel = sampleTimes[samples.indexOf(s)];
    console.log(`  t=${tLabel !== undefined ? tLabel / 1000 : i * 15}s centroid: ${s.centroidHz.toFixed(1)} Hz  dominant: ${s.dominantHz.toFixed(1)} Hz`);
  });
  console.log(`  mean centroid: ${meanCentroid.toFixed(1)} Hz  (< 700 Hz → PASS)`);
  tdLines.slice(0, 20).forEach(l => console.log(`    ${l}`));
  const errors = pageErrors.filter(e => !/minor|warning/i.test(e));
  if (errors.length) console.log(`  PAGE ERRORS: ${errors.join('; ')}`);
});
