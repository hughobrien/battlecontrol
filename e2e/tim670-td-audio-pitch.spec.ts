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
 *      getFloatFrequencyData() is sampled at t≈10s and t≈25s into gameplay.
 *   3. Two assertions are made:
 *
 *      Primary — dominant frequency threshold:
 *        The dominant peak in the 20–2000 Hz analysis band must be < 750 Hz.
 *        TD game music (electronic/industrial, source 22050 Hz) at correct
 *        pitch: bass+kick 40–200 Hz, melody 200–600 Hz → dominant ≈ 80–500 Hz.
 *        At 2× regression (44100 Hz device): dominant shifts to ~160–1000 Hz,
 *        regularly exceeding 750 Hz.
 *        At 2.18× regression (48000 Hz device): similar shift, ~175–1090 Hz.
 *
 *      Secondary — band energy ratio:
 *        Low-band (20–400 Hz) peak dB must be ≥ high-band (800–3000 Hz) peak dB.
 *        At correct pitch: bass/mid content dominant (low-band stronger).
 *        At 2× regression: content shifts up, high-band gains relative energy.
 *
 * Acceptance (TIM-670):
 *   - FAILS on a pre-TIM-555 binary (dominant ≥ 750 Hz and/or band energy
 *     inverted).
 *   - PASSES on the post-TIM-555 binary (dominant < 750 Hz, low-band dominant).
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
 * Sample the FFT tap and return dominant frequency info.
 * Returns null if no tap is available yet.
 *
 * TD-specific bands:
 *   lowBandDb  — peak dB in 20–400 Hz (bass+mid: where correct-pitch content lives)
 *   highBandDb — peak dB in 800–3000 Hz (upper-mid: where 2× regression shifts content)
 */
async function samplePitchTap(page: any): Promise<{
  dominantHz:    number;
  dominantDb:    number;
  sampleRate:    number;
  binHz:         number;
  lowBandDb:     number;   // peak dB in 20–400 Hz  ("correct pitch" band)
  highBandDb:    number;   // peak dB in 800–3000 Hz ("2× regression" band)
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

    // Locate dominant peak in 20–2000 Hz analysis band.
    const lo = Math.max(1, Math.ceil(20   / binHz));
    const hi = Math.min(bufLen - 1, Math.floor(2000 / binHz));
    let maxDb = -Infinity;
    let maxBin = lo;
    for (let i = lo; i <= hi; i++) {
      if (data[i] > maxDb) { maxDb = data[i]; maxBin = i; }
    }

    // Peak dB in low-band (20–400 Hz) — where correct-pitch TD game music lives.
    const lbLo = Math.max(1, Math.ceil(20  / binHz));
    const lbHi = Math.min(bufLen - 1, Math.floor(400 / binHz));
    let lowBandDb = -Infinity;
    for (let i = lbLo; i <= lbHi; i++) {
      if (data[i] > lowBandDb) lowBandDb = data[i];
    }

    // Peak dB in high-band (800–3000 Hz) — where 2× regression content appears.
    const hbLo = Math.max(1, Math.ceil(800  / binHz));
    const hbHi = Math.min(bufLen - 1, Math.floor(3000 / binHz));
    let highBandDb = -Infinity;
    for (let i = hbLo; i <= hbHi; i++) {
      if (data[i] > highBandDb) highBandDb = data[i];
    }

    // Serialize the low-frequency portion for the FFT plot file.
    const sliceLen = Math.min(300, bufLen);
    const fftSlice = Array.from(data.slice(0, sliceLen)) as number[];

    return {
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
  // 25 min: preloader (~6 min) + audio init (~6 min) + frame 100 (~7 min)
  //         + FFT sampling (35s) + generous buffer
  test.setTimeout(1_500_000);

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

  // ── Phase 5: FFT sample at t≈10s after frame 100 ─────────────────────────
  console.log('\n[TIM-670] === Phase 5: FFT sample at t≈10s ===');
  const wait10 = 10_000 - (Date.now() - frame100Ms);
  if (wait10 > 0) await page.waitForTimeout(wait10);

  const fft10 = await samplePitchTap(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim670-td-frame100-t10s.png') });

  let fft25: Awaited<ReturnType<typeof samplePitchTap>> = null;

  if (fft10) {
    console.log(`  t=10s: dominantHz=${fft10.dominantHz.toFixed(1)}  dominantDb=${fft10.dominantDb.toFixed(1)}`
      + `  lowBand(20-400)=${fft10.lowBandDb.toFixed(1)} dB  highBand(800-3000)=${fft10.highBandDb.toFixed(1)} dB`
      + `  sampleRate=${fft10.sampleRate}`);
    const plotPath = writeFftPlot('t10s', fft10.fftSlice, fft10.binHz);
    console.log(`  FFT plot saved: ${plotPath}`);
    fs.writeFileSync(
      path.join(SCREENSHOTS_DIR, 'tim670-td-fft-t10s.json'),
      JSON.stringify({
        label: 't10s', dominantHz: fft10.dominantHz, dominantDb: fft10.dominantDb,
        lowBandDb: fft10.lowBandDb, highBandDb: fft10.highBandDb,
        sampleRate: fft10.sampleRate, binHz: fft10.binHz,
        fftSlice: fft10.fftSlice,
      }, null, 2)
    );
  } else {
    console.log('  WARNING: AnalyserNode tap not yet present at t=10s (no audio connected yet?)');
  }

  // ── Phase 6: FFT sample at t≈25s after frame 100 ─────────────────────────
  console.log('\n[TIM-670] === Phase 6: FFT sample at t≈25s ===');
  const wait25 = 25_000 - (Date.now() - frame100Ms);
  if (wait25 > 0) await page.waitForTimeout(wait25);

  fft25 = await samplePitchTap(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim670-td-frame100-t25s.png') });

  if (fft25) {
    console.log(`  t=25s: dominantHz=${fft25.dominantHz.toFixed(1)}  dominantDb=${fft25.dominantDb.toFixed(1)}`
      + `  lowBand(20-400)=${fft25.lowBandDb.toFixed(1)} dB  highBand(800-3000)=${fft25.highBandDb.toFixed(1)} dB`);
    writeFftPlot('t25s', fft25.fftSlice, fft25.binHz);
    fs.writeFileSync(
      path.join(SCREENSHOTS_DIR, 'tim670-td-fft-t25s.json'),
      JSON.stringify({
        label: 't25s', dominantHz: fft25.dominantHz, dominantDb: fft25.dominantDb,
        lowBandDb: fft25.lowBandDb, highBandDb: fft25.highBandDb,
        sampleRate: fft25.sampleRate, binHz: fft25.binHz,
        fftSlice: fft25.fftSlice,
      }, null, 2)
    );
  }

  // ── Phase 7: Assertions ────────────────────────────────────────────────────
  console.log('\n[TIM-670] === Phase 7: Assertions ===');

  // Sanity: at least one FFT sample must be present.
  const haveFft = fft10 !== null || fft25 !== null;
  expect(haveFft, 'AnalyserNode tap must produce FFT data during TD game audio').toBe(true);

  if (fft10 && fft25) {
    const domHz10  = fft10.dominantHz;
    const domHz25  = fft25.dominantHz;
    const maxDomHz = Math.max(domHz10, domHz25);

    console.log(`  Dominant peaks: t10s=${domHz10.toFixed(1)} Hz  t25s=${domHz25.toFixed(1)} Hz`);
    console.log(`  Primary threshold: < 750 Hz`);
    console.log(`  2× regression prediction: ~${(domHz10 * 2).toFixed(0)}–${(domHz25 * 2).toFixed(0)} Hz`);

    /**
     * Primary pitch assertion — dominant frequency threshold.
     *
     * TD game audio source rate: 22050 Hz.
     * At correct pitch (post-TIM-555): dominant in 80–500 Hz (bass/mid heavy
     *   electronic music, well below 750 Hz).
     * At 2× regression (44100 Hz device, no resampling): dominant ~160–1000 Hz,
     *   regularly exceeds 750 Hz threshold.
     * At 2.18× regression (48000 Hz device, no resampling): dominant ~175–1090 Hz,
     *   clearly exceeds 750 Hz threshold.
     *
     * We take the max of both samples to be conservative: a single outlier
     * (e.g. a brief high-pitched sound effect) could spike one sample but
     * both samples exceeding 750 Hz indicates a systematic regression.
     */
    expect(maxDomHz,
      `Dominant frequency (max of t10s/t25s samples) must be < 750 Hz for correct pitch. `
      + `Got ${maxDomHz.toFixed(1)} Hz. Pre-TIM-555 regression would show ~${(maxDomHz * 2).toFixed(0)} Hz here.`
    ).toBeLessThan(750);

    /**
     * Secondary pitch assertion — band energy ratio.
     *
     * For correct-pitch TD game music, bass and mid-range content dominates:
     *   peak energy in low-band (20–400 Hz) should exceed high-band (800–3000 Hz).
     * For 2× regression, bass content shifts to 160–800 Hz and mid to 800–1600 Hz,
     *   so the high-band gains significant relative energy.
     *
     * Use the conservative pair: min low-band vs max high-band across both samples.
     */
    const minLowBandDb  = Math.min(fft10.lowBandDb,  fft25.lowBandDb);
    const maxHighBandDb = Math.max(fft10.highBandDb,  fft25.highBandDb);
    console.log(`  Low-band peak (20–400 Hz):    ${minLowBandDb.toFixed(1)} dB (worst of two samples)`);
    console.log(`  High-band peak (800–3000 Hz): ${maxHighBandDb.toFixed(1)} dB (worst of two samples)`);

    expect(minLowBandDb,
      `Low-band (20–400 Hz) must be louder than high-band (800–3000 Hz): `
      + `lowBand=${minLowBandDb.toFixed(1)} dB  highBand=${maxHighBandDb.toFixed(1)} dB`
    ).toBeGreaterThan(maxHighBandDb);

  } else if (fft10) {
    // Only t10s sample available — assert on that alone.
    console.log(`  Only t10s sample available: dominantHz=${fft10.dominantHz.toFixed(1)}`);
    expect(fft10.dominantHz,
      `Dominant frequency at t10s must be < 750 Hz. Got ${fft10.dominantHz.toFixed(1)} Hz.`
    ).toBeLessThan(750);
    expect(fft10.lowBandDb,
      `Low-band (20–400 Hz) must be louder than high-band (800–3000 Hz)`
    ).toBeGreaterThan(fft10.highBandDb);
  } else if (fft25) {
    // Only t25s sample available.
    console.log(`  Only t25s sample available: dominantHz=${fft25.dominantHz.toFixed(1)}`);
    expect(fft25.dominantHz,
      `Dominant frequency at t25s must be < 750 Hz. Got ${fft25.dominantHz.toFixed(1)} Hz.`
    ).toBeLessThan(750);
    expect(fft25.lowBandDb,
      `Low-band (20–400 Hz) must be louder than high-band (800–3000 Hz)`
    ).toBeGreaterThan(fft25.highBandDb);
  }

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
  tdLines.slice(0, 20).forEach(l => console.log(`    ${l}`));
  const errors = pageErrors.filter(e => !/minor|warning/i.test(e));
  if (errors.length) console.log(`  PAGE ERRORS: ${errors.join('; ')}`);
});
