/**
 * T8 — RA WASM PROLOG.VQA audio pitch probe (TIM-773).
 *
 * Regression gate: detects the TIM-602 class of pitch regression where the
 * RA VQA audio plays at the wrong pitch because the 22050 Hz PCM source rate
 * is fed raw to an AudioContext running at the browser native rate
 * (44100 or 48000 Hz), causing audio to play 2–2.18× too fast.
 *
 * Mechanism (AudioBufferSourceNode tap pattern from TIM-603 / T7):
 *   1. page.addInitScript() overrides AudioNode.prototype.connect to redirect
 *      any connection targeting AudioDestinationNode through a tap AnalyserNode
 *      wired to the real destination.
 *   2. ENGLISH.VQA plays to completion (~10 s).  When PROLOG.VQA starts
 *      (Hell March), getFloatFrequencyData() is sampled twice: t=5 s and
 *      t=20 s after "[VQA] Playing 'PROLOG.VQA'" fires.
 *   3. Two assertions:
 *
 *      Primary — minimum dominant peak (TIM-766 lesson — min, not max):
 *        min(dominantHz_t5s, dominantHz_t20s) < 90 Hz.
 *        Calibrated from TIM-603 (Hell March sub-bass fundamental ~50–80 Hz).
 *        At 2× regression (no TIM-602 fix): dominant doubles → ~100–160 Hz.
 *        90 Hz threshold is midway between the two ranges.
 *        Using min (not max) resists false positives from single-window
 *        percussion transients — a sustained regression keeps BOTH samples
 *        above threshold.
 *
 *      Secondary — audio presence:
 *        At least one sample must have dominant dB > −90 dBFS.
 *
 * CI characteristics:
 *   - Skipped when RA_ASSETS_URL is not set (asset-gated; needs MIX files for VQAs).
 *   - Budget: 600 s.  CDN path: ~120 s preloader + ~30 s Init_Bulk_Data +
 *     ~10 s ENGLISH.VQA + ~25 s PROLOG sampling = ~185 s typical.
 *   - Servers required: serve-coop.py on :8080 (started by CI workflow).
 *     Assets come from RA_ASSETS_URL (CDN) or fallback to local :9090.
 *   - Runnable under the 5×cold-cache wrapper — see scripts/tim773-t8-5run-verify.sh.
 *
 * Analogous to:
 *   e2e/regression/T7-td-audio-pitch.spec.ts — TD game audio CI gate (TIM-767)
 *   e2e/tim603-audio-pitch-probe.spec.ts     — full RA VQA pitch audit spec
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
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
 * AnalyserNode injection script — identical to TIM-603 / T7.
 * Runs before any page JS via page.addInitScript().  Overrides
 * AudioNode.prototype.connect to redirect any connection targeting
 * AudioDestinationNode through a tap AnalyserNode wired to the real
 * destination.
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
 * Sample the FFT tap and return dominant-peak info in the 20–300 Hz band.
 * Returns null if no tap is present yet.
 *
 * dominantHz — frequency of the peak energy bin in 20–300 Hz.
 *   Hell March sub-bass fundamental at correct pitch: ~50–80 Hz.
 *   At 2× regression: ~100–160 Hz.
 */
async function samplePitchTap(page: any): Promise<{
  dominantHz:  number;
  dominantDb:  number;
  sampleRate:  number;
  binHz:       number;
  subBassDb:   number;  // peak dB in 20–90 Hz ("correct pitch" band)
  lowMidDb:    number;  // peak dB in 100–300 Hz ("2× regression" band)
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

    const lo = Math.max(1, Math.ceil(20  / binHz));
    const hi = Math.min(bufLen - 1, Math.floor(300 / binHz));

    let maxDb = -Infinity, maxBin = lo;
    for (let i = lo; i <= hi; i++) {
      if (data[i] > maxDb) { maxDb = data[i]; maxBin = i; }
    }

    const sbLo = Math.max(1, Math.ceil(20 / binHz));
    const sbHi = Math.min(bufLen - 1, Math.floor(90 / binHz));
    let subBassDb = -Infinity;
    for (let i = sbLo; i <= sbHi; i++) {
      if (data[i] > subBassDb) subBassDb = data[i];
    }

    const lmLo = Math.max(1, Math.ceil(100 / binHz));
    const lmHi = Math.min(bufLen - 1, Math.floor(300 / binHz));
    let lowMidDb = -Infinity;
    for (let i = lmLo; i <= lmHi; i++) {
      if (data[i] > lowMidDb) lowMidDb = data[i];
    }

    const fftSlice = Array.from(data.slice(0, Math.min(300, bufLen))) as number[];

    return {
      dominantHz: maxBin * binHz,
      dominantDb: maxDb,
      sampleRate: sr,
      binHz,
      subBassDb,
      lowMidDb,
      fftSlice,
      tapPresent: true,
    };
  });
}

function writeFftPlot(label: string, fftSlice: number[], binHz: number) {
  const lines: string[] = [`# T8 RA WASM audio pitch — ${label}`, `# bin_hz: ${binHz.toFixed(2)}`, ''];
  const norm = Math.max(...fftSlice.filter(v => isFinite(v)));
  for (let i = 0; i < fftSlice.length; i++) {
    const hz  = (i * binHz).toFixed(1).padStart(7);
    const db  = isFinite(fftSlice[i]) ? fftSlice[i].toFixed(1).padStart(7) : '    -∞';
    const bar = isFinite(fftSlice[i])
      ? '#'.repeat(Math.max(0, Math.round((fftSlice[i] - norm + 60) / 1)))
      : '';
    lines.push(`${hz} Hz  ${db} dB  ${bar}`);
  }
  const p = path.join(SCREENSHOTS_DIR, `t8-ra-audio-fft-${label}.txt`);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// ---------- test -------------------------------------------------------------

test('T8 — RA WASM PROLOG.VQA audio pitch probe (min dominant < 90 Hz → correct pitch)', async ({ page }) => {
  // 600 s: ~120 s preloader + ~30 s init + ~10 s ENGLISH.VQA + 25 s PROLOG sampling.
  test.setTimeout(600_000);

  if (!process.env['RA_ASSETS_URL']) {
    test.skip(true, 'T8 skipped — RA_ASSETS_URL not set');
    return;
  }

  const consoleLogs: string[] = [];
  const pageErrors:  string[] = [];
  page.on('console',   (msg: any)   => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // Inject AnalyserNode hook BEFORE page loads.
  await page.addInitScript(ANALYSER_HOOK);

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T8] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── 1. Preloader ─────────────────────────────────────────────────────────
  console.log('\n[T8] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[T8] preloader hidden ✓');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't8-ra-01-preloader.png') });

  // ── 2. Init_Bulk_Data done ───────────────────────────────────────────────
  console.log('\n[T8] === Phase 2: Init_Bulk_Data ===');
  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 120_000);
  console.log('[T8] Init_Bulk_Data done ✓');

  // ── 3. ENGLISH.VQA completes (~10 s) ────────────────────────────────────
  console.log('\n[T8] === Phase 3: ENGLISH.VQA ===');
  await waitForOutput(page, "[VQA] 'ENGLISH.VQA' done", 120_000);
  console.log("[T8] ENGLISH.VQA done ✓");

  // ── 4. PROLOG.VQA starts (Hell March begins) ─────────────────────────────
  console.log('\n[T8] === Phase 4: PROLOG.VQA start ===');
  await waitForOutput(page, "[VQA] Playing 'PROLOG.VQA'", 30_000);
  const prologStartMs = Date.now();
  console.log("[T8] PROLOG.VQA playing ✓");
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't8-ra-02-prolog-start.png') });

  const output0 = await getOutput(page);
  const nativeRateLine = output0.split('\n').find(l => l.includes('[RA] WASM audio:') || l.includes('[RA] SDL audio open:'));
  const nativeHz = nativeRateLine ? (nativeRateLine.match(/(\d{4,6})\s*Hz/)?.[1] ?? 'unknown') : 'unknown';
  console.log(`[T8] browser native AudioContext rate: ${nativeHz} Hz`);

  // ── 5–6. FFT samples at t=5 s and t=20 s after PROLOG.VQA starts ────────
  type FftSample = Awaited<ReturnType<typeof samplePitchTap>>;
  const sampleTimes = [5_000, 20_000]; // ms after "[VQA] Playing 'PROLOG.VQA'"
  const samples: FftSample[] = [];

  for (const tMs of sampleTimes) {
    const label = `t${tMs / 1000}s`;
    const wait  = tMs - (Date.now() - prologStartMs);
    if (wait > 0) await page.waitForTimeout(wait);

    console.log(`\n[T8] === FFT sample at ${label} ===`);
    const fft = await samplePitchTap(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `t8-ra-03-${label}.png`) });
    samples.push(fft);

    if (fft) {
      console.log(`[T8] ${label}: dominant=${fft.dominantHz.toFixed(1)} Hz  db=${fft.dominantDb.toFixed(1)} dBFS  subBass=${fft.subBassDb.toFixed(1)} dB  lowMid=${fft.lowMidDb.toFixed(1)} dB  sr=${fft.sampleRate}`);
      writeFftPlot(label, fft.fftSlice, fft.binHz);
      fs.writeFileSync(
        path.join(SCREENSHOTS_DIR, `t8-ra-fft-${label}.json`),
        JSON.stringify({
          label, dominantHz: fft.dominantHz, dominantDb: fft.dominantDb,
          subBassDb: fft.subBassDb, lowMidDb: fft.lowMidDb,
          sampleRate: fft.sampleRate, binHz: fft.binHz,
          fftSlice: fft.fftSlice,
        }, null, 2)
      );
    } else {
      console.log(`[T8] WARNING: AnalyserNode tap not present at ${label}`);
    }
  }

  // ── 7. Assertions ─────────────────────────────────────────────────────
  console.log('\n[T8] === Phase 7: Assertions ===');

  const validSamples = samples.filter((s): s is NonNullable<FftSample> => s !== null);
  expect(validSamples.length,
    `AnalyserNode tap must produce FFT data for at least 1 of ${samples.length} samples`
  ).toBeGreaterThan(0);

  const dominants    = validSamples.map(s => s.dominantHz);
  const minDominant  = Math.min(...dominants);
  const maxDominantDb = Math.max(...validSamples.map(s => s.dominantDb));

  console.log(`[T8] Dominant peaks (t5s/t20s): ${dominants.map(d => d.toFixed(1)).join(', ')} Hz`);
  console.log(`[T8] Min dominant: ${minDominant.toFixed(1)} Hz  (threshold < 90 Hz)`);
  console.log(`[T8] 2× regression prediction: ~${(minDominant * 2).toFixed(0)} Hz`);
  console.log(`[T8] Max dominant dB: ${maxDominantDb.toFixed(1)} dBFS`);

  /**
   * Primary: min dominant peak in 20–300 Hz band < 90 Hz.
   *
   * RA VQA audio source: 22050 Hz (PROLOG.VQA / Hell March).
   * Calibrated from TIM-603 (Hell March sub-bass fundamental):
   *   correct pitch: dominant ~50–80 Hz.
   *   TIM-602 regression (2× pitch): dominant ~100–160 Hz.
   * 90 Hz threshold sits between the correct and regression ranges.
   *
   * Using min (not max) per TIM-766: a sustained 2× regression keeps BOTH
   * samples above 90 Hz; a single percussion transient can push one sample
   * above threshold without indicating a regression.
   */
  expect(minDominant,
    `Min dominant peak (20–300 Hz) across ${validSamples.length} samples must be < 90 Hz. `
    + `Got min=${minDominant.toFixed(1)} Hz (samples: ${dominants.map(d => d.toFixed(0)).join(', ')} Hz). `
    + `Pre-TIM-602 regression would show both samples ~>${(minDominant * 2).toFixed(0)} Hz.`
  ).toBeLessThan(90);

  // Secondary: audio must be present — dominant dB > noise floor.
  expect(maxDominantDb,
    `Audio must be present: max dominant dB must exceed −90 dBFS. Got ${maxDominantDb.toFixed(1)} dBFS.`
  ).toBeGreaterThan(-90);

  // Save console log for postmortem.
  const fullOutput = await getOutput(page);
  const raLines    = [...fullOutput.matchAll(/\[(RA|VQA)\][^\n]*/g)].map(m => m[0]);
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 't8-ra-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${fullOutput}\n`
  );

  console.log('\n[T8] ===== PITCH PROBE SUMMARY =====');
  console.log(`  AudioContext native rate:  ${nativeHz} Hz`);
  validSamples.forEach((s, i) => {
    const tLabel = sampleTimes[samples.indexOf(s)];
    console.log(`  t=${tLabel !== undefined ? tLabel / 1000 : i * 15}s dominant: ${s.dominantHz.toFixed(1)} Hz  subBass: ${s.subBassDb.toFixed(1)} dB  lowMid: ${s.lowMidDb.toFixed(1)} dB`);
  });
  console.log(`  min dominant: ${minDominant.toFixed(1)} Hz  (< 90 Hz → PASS)`);
  raLines.slice(0, 20).forEach(l => console.log(`    ${l}`));
  const errors = pageErrors.filter(e => !/minor|warning/i.test(e));
  if (errors.length) console.log(`  PAGE ERRORS: ${errors.join('; ')}`);
});
