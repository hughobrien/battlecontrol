/**
 * TIM-677 — measure WebAudio underrun + scan recorded PCM for silence gaps
 * during PROLOG.VQA.
 *
 * The user (correctly) refused another listening round and asked for a
 * programmatic comparison.  This spec runs the WASM build with PR #117's
 * 500 ms pre-buffer in place, lets the intro VQAs auto-play, and captures:
 *
 *   1. console warning count from TIM-658's [VQA] audio buffer low message,
 *      which fires whenever the AudioBufferSourceNode scheduler is forced to
 *      clamp t forward (the underrun mechanism that produces the audible
 *      ~15 Hz "jitter" the board described).
 *   2. live AudioContext state (running vs suspended, lead time).
 *   3. raw PCM via an AnalyserNode tap routed through every node that
 *      connects to ctx.destination — scanned IN-PAGE for the longest
 *      silence run, which would be the smoking-gun signature of an underrun
 *      gap if my pre-buffer fix is insufficient.
 *
 * Acceptance: zero underrun warnings, AudioContext running, AND the longest
 * silence run during the 45 s of PROLOG.VQA we record stays below 50 ms
 * (an underrun gap from the old 20 ms pad would be 20–100 ms; the new 50 ms
 * threshold makes any gap ≥ 50 ms a clear regression signal).
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const OUT_DIR   = path.join(__dirname, 'screenshots');

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });

// AnalyserNode tap — same pattern as the TIM-603 pitch probe.
// We poll getFloatTimeDomainData and update aggregate stats in-page so we
// never transfer the full PCM stream to the test runner (it OOMs the worker).
const TAP_INIT = `
(function () {
  var _origConnect = AudioNode.prototype.connect;
  AudioNode.prototype.connect = function (dest, outIdx, inIdx) {
    if (dest && dest.constructor && dest.constructor.name === 'AudioDestinationNode') {
      if (!window.__vqa_analyser || window.__vqa_ctx !== dest.context) {
        window.__vqa_ctx       = dest.context;
        window.__vqa_analyser  = window.__vqa_ctx.createAnalyser();
        window.__vqa_analyser.fftSize = 2048;
        window.__vqa_analyser.smoothingTimeConstant = 0.0;
        _origConnect.call(window.__vqa_analyser, window.__vqa_ctx.destination);
        window.__vqa_stats = {
          totalSamples: 0,
          peak: 0,
          curSilenceRun: 0,
          maxSilenceRun: 0,
          enabled: false,
          startTime: null,
        };
        var buf = new Float32Array(window.__vqa_analyser.fftSize);
        setInterval(function () {
          if (!window.__vqa_stats.enabled) return;
          window.__vqa_analyser.getFloatTimeDomainData(buf);
          if (window.__vqa_stats.startTime === null) {
            window.__vqa_stats.startTime = window.__vqa_ctx.currentTime;
          }
          for (var i = 0; i < buf.length; i++) {
            var a = Math.abs(buf[i]);
            if (a > window.__vqa_stats.peak) window.__vqa_stats.peak = a;
            if (a < 1e-4) {
              window.__vqa_stats.curSilenceRun++;
              if (window.__vqa_stats.curSilenceRun > window.__vqa_stats.maxSilenceRun) {
                window.__vqa_stats.maxSilenceRun = window.__vqa_stats.curSilenceRun;
              }
            } else {
              window.__vqa_stats.curSilenceRun = 0;
            }
            window.__vqa_stats.totalSamples++;
          }
        }, 10);
      }
      if (inIdx !== undefined) return _origConnect.call(this, window.__vqa_analyser, outIdx, inIdx);
      if (outIdx !== undefined) return _origConnect.call(this, window.__vqa_analyser, outIdx);
      return _origConnect.call(this, window.__vqa_analyser);
    }
    return _origConnect.apply(this, arguments);
  };
})();
`;

test.describe('TIM-677 — VQA WebAudio underrun probe + silence-run scan', () => {
  test.setTimeout(900_000);

  test('PROLOG.VQA: no [VQA] audio buffer low, no >50 ms silence run', async ({ page }) => {
    await page.addInitScript({ content: TAP_INIT });

    const warnings: Array<{ t: number; text: string }> = [];
    const consoleStart = Date.now();
    page.on('console', msg => {
      const text = msg.text();
      const t = (Date.now() - consoleStart) / 1000;
      if (text.includes('[VQA] audio buffer low') || text.includes('[VQA] audio underrun')) {
        warnings.push({ t, text });
      }
    });

    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await page.locator('body').click({ position: { x: 10, y: 10 } });

    await page.waitForFunction(
      () => document.getElementById('preloader-overlay')?.style.display === 'none',
      null, { timeout: 180_000 }
    );

    await page.waitForFunction(
      () => (document.getElementById('output')?.textContent || '').includes("Playing 'PROLOG.VQA'"),
      null, { timeout: 360_000 }
    );
    const prologStartTime = (Date.now() - consoleStart) / 1000;
    console.log(`[TIM-677] PROLOG.VQA started @ t+${prologStartTime.toFixed(2)}s`);

    // Reset stats so we capture only the PROLOG window the user flagged.
    await page.evaluate(() => {
      const s = (window as any).__vqa_stats;
      s.totalSamples = 0; s.peak = 0;
      s.curSilenceRun = 0; s.maxSilenceRun = 0;
      s.startTime = null;
      s.enabled = true;
    });

    await page.waitForTimeout(45_000);

    const result = await page.evaluate(() => {
      const va  = (window as any).Module?.['_vqa_audio'];
      const ctx = (window as any).Module?.['SDL2']?.audioContext;
      const s   = (window as any).__vqa_stats;
      return {
        ctxState: ctx?.state,
        ctxCurrentTime: ctx?.currentTime,
        ctxSampleRate: ctx?.sampleRate,
        vaNextTime: va?.nextTime,
        lead: va?.nextTime != null && ctx?.currentTime != null ? va.nextTime - ctx.currentTime : null,
        pcmTotalSamples: s.totalSamples,
        pcmPeak: s.peak,
        pcmMaxSilenceRun: s.maxSilenceRun,
        pcmStartTime: s.startTime,
      };
    });

    const sampleRate = Math.round(result.ctxSampleRate || 44100);
    const maxSilenceMs = (result.pcmMaxSilenceRun / sampleRate) * 1000;

    console.log(`[TIM-677] AudioContext: state=${result.ctxState}  sr=${result.ctxSampleRate}  currentTime=${result.ctxCurrentTime}  vaNextTime=${result.vaNextTime}  lead=${result.lead}`);
    console.log(`[TIM-677] PCM stats over the 45 s PROLOG window:`);
    console.log(`    samples=${result.pcmTotalSamples}  peak=${result.pcmPeak.toFixed(4)}  longest-silence=${maxSilenceMs.toFixed(1)} ms (${result.pcmMaxSilenceRun} samples)`);
    console.log(`[TIM-677] [VQA] audio buffer low warnings: ${warnings.length}`);
    for (const w of warnings.slice(0, 10)) console.log(`    t+${w.t.toFixed(2)}s  ${w.text}`);

    fs.writeFileSync(
      path.join(OUT_DIR, 'tim677-underrun-report.json'),
      JSON.stringify({
        warningCount: warnings.length, warnings,
        audioContext: {
          state: result.ctxState, sampleRate: result.ctxSampleRate,
          currentTime: result.ctxCurrentTime, vaNextTime: result.vaNextTime, lead: result.lead,
        },
        pcm: {
          totalSamples: result.pcmTotalSamples,
          peak: result.pcmPeak,
          maxSilenceRun: result.pcmMaxSilenceRun,
          maxSilenceMs,
        },
        prologStartTime,
      }, null, 2)
    );

    expect(result.ctxState, 'AudioContext should be running').toBe('running');
    expect(warnings.length, '[VQA] audio buffer low warnings').toBe(0);
    expect(result.pcmPeak, 'recorded audio peak should be > 0.01 (actual audio playing)').toBeGreaterThan(0.01);
    expect(maxSilenceMs, 'longest silence run in ms (gap threshold = 50ms)').toBeLessThan(50);
  });
});
