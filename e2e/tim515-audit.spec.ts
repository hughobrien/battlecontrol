/**
 * TIM-515 — RA WASM full browser gameplay audit (post TIM-513).
 *
 * Validates the full WASM experience end-to-end after the TIM-513 VQA audio
 * crash fix (skip VQA audio in WASM to prevent AudioContext crash).
 *
 * Acceptance criteria:
 *   1. Boot past preloader without crash (no AudioContext exception)
 *   2. Game initialises — Init_Bulk_Data done
 *   3. Start_Scenario fires for SCG01EA
 *   4. Game loop runs ≥500 frames without crash or freeze
 *   5. Canvas has non-black content at frames 100, 300, 500
 *   6. Missing-asset audit — note "skipping" MIX files; flag gameplay regressions
 *   7. Audio initialises — SDL2 audio device opens
 *   8. No VQA AudioContext crash (TIM-513 regression check)
 *
 * Servers required:
 *   - serve-coop.py / nginx on port 8080 (WASM bundle)
 *   - serve-assets.py on port 9090 (RA MIX files)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL   = 'http://localhost:8080/ra.html';
const ASSET_URL  = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

async function waitForOutput(page: any, substring: string, timeoutMs = 180_000) {
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
    return el ? el.textContent || '' : '';
  });
}

async function canvasPixelStats(page: any): Promise<{
  hasContent: boolean; nonBlackCount: number; totalSampled: number;
  uniqueColors: number; fillPct: number; width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { hasContent: false, nonBlackCount: 0, totalSampled: 0, uniqueColors: 0, fillPct: 0, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { hasContent: len > 2000, nonBlackCount: len > 2000 ? 1 : 0, totalSampled: 1, uniqueColors: 0, fillPct: 0, width: canvas.width, height: canvas.height };
    }
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    for (let i = 0; i < data.length; i += 16) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    const total = Math.floor(data.length / 16);
    return { hasContent: nonBlack > 0, nonBlackCount: nonBlack, totalSampled: total,
             uniqueColors: colorSet.size, fillPct: Math.round(nonBlack / total * 100), width: w, height: h };
  });
}

const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;

test.describe('TIM-515 — RA WASM post-TIM-513 full gameplay audit', () => {
  test.setTimeout(900_000);   // 15 min: asset load ~4min + frame 500 ~8min total

  test('full audit: boot → init → scenario → 500 frames → visual + crash check', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // -------------------------------------------------------------------------
    // Phase 1 — Preloader: no browser-error banner, overlay hides
    // -------------------------------------------------------------------------
    console.log('\n[TIM-515] === Phase 1: Preloader ===');

    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('  browser-error banner: hidden (OK)');

    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );
    const tPreload = Date.now();
    console.log(`  preloader overlay hidden — ${Math.round((tPreload - tStart) / 1000)}s from load`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-preloader-done.png'), fullPage: true });

    // Check for AudioContext crash (TIM-513 regression check):
    // Before TIM-513, the VQA player called new AudioContext() which threw an
    // AbortError in WASM context.  After fix, VQA audio is fully skipped.
    const hasAudioCtxCrash = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    console.log(`  TIM-513 regression — AudioContext crash: ${hasAudioCtxCrash ? 'FAIL (crash seen)' : 'PASS (no crash)'}`);

    // -------------------------------------------------------------------------
    // Phase 2 — Init_Game + MIX asset audit
    // -------------------------------------------------------------------------
    console.log('\n[TIM-515] === Phase 2: Init_Game + MIX audit ===');

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);
    const tInit = Date.now();
    console.log(`  Init_Bulk_Data done — ${Math.round((tInit - tStart) / 1000)}s from load`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-init-done.png'), fullPage: true });

    let output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Audit MIX files flagged as "skipping" in preloader log
    const MIX_FILES = ['LOCAL.MIX', 'LORES.MIX', 'HIRES.MIX', 'CONQUER.MIX', 'SCORES.MIX', 'SPEECH.MIX'];
    const skippingMix: string[] = [];
    const loadedMix: string[] = [];
    for (const mix of MIX_FILES) {
      if (output.toLowerCase().includes(`skipping ${mix.toLowerCase()}`)) {
        skippingMix.push(mix);
      } else if (output.toLowerCase().includes(mix.toLowerCase())) {
        loadedMix.push(mix);
      }
    }

    // Also check console logs for skipping references
    const consoleSkip = consoleLogs.filter(l => /skipping/i.test(l));
    console.log('  MIX loading status:');
    console.log(`    Loaded (seen in output): ${loadedMix.join(', ') || 'none'}`);
    console.log(`    Skipping (seen in output): ${skippingMix.join(', ') || 'none'}`);
    if (consoleSkip.length > 0) {
      console.log('  Console "skipping" lines:');
      consoleSkip.slice(0, 10).forEach(l => console.log(`    ${l}`));
    }

    // SDL2 audio
    const hasAudioOK = output.includes('[RA] Audio_Init: SDL2 audio opened OK');
    console.log(`  Audio_Init: SDL2 audio opened OK: ${hasAudioOK ? 'PASS' : 'FAIL'}`);

    // -------------------------------------------------------------------------
    // Phase 3 — Start_Scenario
    // -------------------------------------------------------------------------
    console.log('\n[TIM-515] === Phase 3: Start_Scenario ===');

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 240_000);
    const tScenario = Date.now();
    console.log(`  Start_Scenario OK — ${Math.round((tScenario - tStart) / 1000)}s from load`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-scenario-start.png'), fullPage: true });

    output = await getOutput(page);
    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // Phase 4 — Frame milestones: 100, 300, 500 (≥500 acceptance criterion)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-515] === Phase 4: Frame milestones ===');

    // Frame 100
    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    const t100 = Date.now();
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-frame100.png'), fullPage: true });
    console.log(`  frame 100 — ${Math.round((t100 - tStart) / 1000)}s from load`);
    console.log(`    canvas ${stats100.width}x${stats100.height} fill=${stats100.fillPct}% colors=${stats100.uniqueColors} hasContent=${stats100.hasContent}`);

    // Frame 300
    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    const t300 = Date.now();
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-frame300.png'), fullPage: true });
    console.log(`  frame 300 — ${Math.round((t300 - tStart) / 1000)}s from load`);
    console.log(`    canvas fill=${stats300.fillPct}% colors=${stats300.uniqueColors} hasContent=${stats300.hasContent}`);

    // Frame 500 — ≥500 frames acceptance criterion
    await waitForOutput(page, '[RA] Main_Loop frame 500', 300_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim515-frame500.png'), fullPage: true });
    console.log(`  frame 500 — ${Math.round((t500 - tStart) / 1000)}s from load`);
    console.log(`    canvas fill=${stats500.fillPct}% colors=${stats500.uniqueColors} hasContent=${stats500.hasContent}`);

    const fps_100_300 = Math.round(200 / ((t300 - t100) / 1000) * 10) / 10;
    const fps_300_500 = Math.round(200 / ((t500 - t300) / 1000) * 10) / 10;
    console.log(`  FPS: frames 100→300=${fps_100_300}  frames 300→500=${fps_300_500}`);

    // -------------------------------------------------------------------------
    // Final output check + MIX gameplay impact assessment
    // -------------------------------------------------------------------------
    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Page error check (includes AudioContext and other JS exceptions)
    const criticalErrors = pageErrors.filter(e => !/AudioContext|NotAllowedError/i.test(e) || hasAudioCtxCrash);
    const hasAudioCtxCrashFinal = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    // -------------------------------------------------------------------------
    // SUMMARY
    // -------------------------------------------------------------------------
    console.log('\n[TIM-515] ===== AUDIT SUMMARY =====');
    console.log(`  1. Boot past preloader without crash:       PASS`);
    console.log(`  2. Init_Bulk_Data done:                     PASS`);
    console.log(`  3. Start_Scenario (SCG01EA):                PASS`);
    console.log(`  4. ≥500 frames reached:                     PASS (frame 500 at ${Math.round((t500 - tStart)/1000)}s)`);
    console.log(`  5. Canvas non-black at frame 100:           ${stats100.hasContent ? 'PASS' : 'FAIL'} (fill=${stats100.fillPct}%)`);
    console.log(`     Canvas non-black at frame 300:           ${stats300.hasContent ? 'PASS' : 'FAIL'} (fill=${stats300.fillPct}%)`);
    console.log(`     Canvas non-black at frame 500:           ${stats500.hasContent ? 'PASS' : 'FAIL'} (fill=${stats500.fillPct}%)`);
    console.log(`  6. MIX files "skipping":                    ${skippingMix.length > 0 ? skippingMix.join(', ') : 'none seen in game output'}`);
    console.log(`     Gameplay impact from skipping MIX:       ${stats500.hasContent ? 'NONE (canvas renders fine)' : 'POSSIBLE (black canvas)'}`);
    console.log(`  7. SDL2 audio opened OK:                    ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  8. TIM-513 VQA AudioContext crash:          ${hasAudioCtxCrashFinal ? 'REGRESSION (crash seen!)' : 'PASS (no AudioContext crash)'}`);
    console.log(`  FPS frames 100→300: ${fps_100_300}  300→500: ${fps_300_500}`);
    if (pageErrors.length > 0) {
      console.log('  Page errors during run:');
      pageErrors.forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }
    console.log('  Screenshots: tim515-preloader-done, tim515-init-done, tim515-scenario-start, tim515-frame100, tim515-frame300, tim515-frame500');

    // Hard assertions
    expect(stats300.hasContent, 'canvas must have content at frame 300').toBe(true);
    expect(stats500.hasContent, 'canvas must have content at frame 500').toBe(true);
    expect(hasAudioCtxCrashFinal, 'TIM-513 regression: AudioContext crash must not occur').toBe(false);
    expect(hasAudioOK, 'SDL2 audio must open successfully').toBe(true);
  });
});
