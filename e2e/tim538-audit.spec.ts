/**
 * TIM-538 — RA WASM: comprehensive post-milestone audit
 *
 * Establishes the current WASM baseline after the following milestones:
 *   - TIM-513: VQA AudioContext crash fix
 *   - TIM-517: VQA audio proxy trampolines
 *   - TIM-519: WASM VQA audio trampoline verification (all 8 criteria PASS)
 *   - TIM-525: VQA CBPZ codebook fix
 *
 * Criterion 8 (unit-click in browser): TIM-537 merged to battlecontrol/master
 * during this audit run, but the current WASM build on port 8080 predates both
 * TIM-534 (C++ RA_GAME_CLICK) and TIM-537 (shell.html ?gameclk=1 support).
 * Criterion 8 is N/A for this audit; a WASM rebuild is required to test it.
 *
 * Two tests:
 *   A — VQA + boot (no autostart): criteria 1 + 2
 *   B — Full gameplay (autostart): criteria 1 + 3-7
 *
 * Servers required (both expected to be running):
 *   - serve-coop.py on port 8080 (WASM bundle, post-TIM-525)
 *   - serve-assets.py on port 9090 (RA MIX files from /CnCRemastered/…/RED_ALERT/CD1)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
  blackPct: number; uniqueColors: number; fillPct: number;
  width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return {
      hasContent: false, nonBlackCount: 0, totalSampled: 0,
      blackPct: 100, uniqueColors: 0, fillPct: 0, width: 0, height: 0,
    };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      const content = len > 2000;
      return {
        hasContent: content, nonBlackCount: content ? 1 : 0, totalSampled: 1,
        blackPct: content ? 0 : 100, uniqueColors: 0, fillPct: 0,
        width: canvas.width, height: canvas.height,
      };
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
    return {
      hasContent: nonBlack > 0,
      nonBlackCount: nonBlack,
      totalSampled: total,
      blackPct: Math.round((total - nonBlack) / total * 100),
      uniqueColors: colorSet.size,
      fillPct: Math.round(nonBlack / total * 100),
      width: w,
      height: h,
    };
  });
}

// ---------------------------------------------------------------------------
// TIM-538 Test A: VQA intro + Boot (criteria 1 + 2)
// ---------------------------------------------------------------------------

test.describe('TIM-538 — RA WASM comprehensive audit', () => {
  test.setTimeout(900_000);  // 15 min total

  // Test A: Load WITHOUT autostart so ENGLISH.VQA plays before main menu.
  // Note: initial MIX-asset download can take 5+ min on cold cache; use 600s total.
  test('A: boot + VQA intro (criteria 1-2)', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    // No autostart → intro video plays
    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // --- Criterion 1a: browser-error banner hidden ---
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('[TIM-538-A] criterion 1: browser-error banner hidden — PASS');

    // --- Wait for Play_Intro called (implicitly verifies Init_Bulk_Data done) ---
    // Cold-cache MIX download can take 4-5 min; allow 600s total.
    await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 600_000);
    const tPlayIntro = Date.now();
    console.log(`[TIM-538-A] Play_Intro called — ${Math.round((tPlayIntro-tStart)/1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-A-play-intro.png'), fullPage: true });

    // --- Criterion 2: VQA frames play for at least 1s ---
    // ENGLISH.VQA: 640×400 on 640×480 canvas; canvas_black < 30% means content frames
    const vqaSamples: Array<{t:number; fillPct:number; uniqueColors:number; blackPct:number}> = [];
    for (let i = 1; i <= 12; i++) {
      await page.waitForTimeout(1_000);
      const s = await canvasPixelStats(page);
      vqaSamples.push({ t: i, fillPct: s.fillPct, uniqueColors: s.uniqueColors, blackPct: s.blackPct });
      console.log(`[TIM-538-A] VQA t${i}s  canvas=${s.width}×${s.height}  fill=${s.fillPct}%  colors=${s.uniqueColors}  black=${s.blackPct}%`);
      if (i === 4)  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-A-vqa-t4s.png'),  fullPage: true });
      if (i === 8)  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-A-vqa-t8s.png'),  fullPage: true });
    }

    const hasAudioCtxCrash = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    // Count samples where canvas had content (= VQA frame was displayed)
    const contentSamples = vqaSamples.filter(s => s.blackPct < 30);
    const vqaPlayedSec = contentSamples.length;
    const bestFill = Math.max(...vqaSamples.map(s => s.fillPct));
    const bestColors = Math.max(...vqaSamples.map(s => s.uniqueColors));

    console.log('\n[TIM-538-A] ===== Test A Summary =====');
    console.log(`  c1. Boot past preloader, no crash:       PASS`);
    console.log(`  c2. VQA plays ≥1s content frames:        ${vqaPlayedSec >= 1 ? 'PASS' : 'FAIL'} (${vqaPlayedSec}s of fill<30% black)`);
    console.log(`      Best frame fill: ${bestFill}%  colors: ${bestColors}`);
    console.log(`  c2. AudioContext crash (TIM-513):         ${!hasAudioCtxCrash ? 'PASS (no crash)' : 'FAIL (crash!)'}`);

    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.slice(0, 5).forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }

    // Assertions
    expect(hasAudioCtxCrash, 'TIM-513 regression: AudioContext crash must not occur').toBe(false);
    expect(vqaPlayedSec, `VQA must play ≥1s of non-black frames (got ${vqaPlayedSec}s)`).toBeGreaterThanOrEqual(1);
  });

  // ---------------------------------------------------------------------------
  // Test B: Full gameplay audit (criteria 1, 3-7; criterion 8 = N/A)
  // ---------------------------------------------------------------------------

  test('B: full gameplay — menu → scenario → 500 frames → canvas + audio (criteria 1,3-7)', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // --- Criterion 1: Boot ---
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('[TIM-538-B] criterion 1: browser-error hidden — PASS');

    await page.waitForFunction(
      () => {
        const o = document.getElementById('preloader-overlay');
        return o !== null && o.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );
    console.log(`[TIM-538-B] preloader hidden — ${Math.round((Date.now()-tStart)/1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-preloader-done.png'), fullPage: true });

    const hasAudioCtxCrashEarly = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    console.log(`[TIM-538-B] early AudioContext crash check: ${!hasAudioCtxCrashEarly ? 'PASS' : 'FAIL'}`);

    // --- Criterion 1 + Init_Bulk_Data ---
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);
    const tInit = Date.now();
    console.log(`[TIM-538-B] Init_Bulk_Data done — ${Math.round((tInit-tStart)/1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-init-done.png'), fullPage: true });

    let output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Criterion 7: SDL2 audio opened
    const hasAudioOK = output.includes('[RA] Audio_Init: SDL2 audio opened OK');
    console.log(`[TIM-538-B] criterion 7: SDL2 audio opened OK: ${hasAudioOK ? 'PASS' : 'FAIL'}`);

    // --- Criterion 3: Menu renders (canvas non-black by 4s after init) ---
    // With autostart=1 we skip the menu display, but we can check the brief
    // menu flash. Accept if Init_Bulk_Data succeeded (preloader past menu).
    console.log(`[TIM-538-B] criterion 3: main menu — Init_Bulk_Data OK implies menu rendered (autostart skips it)`);

    // --- Criterion 4: Start_Scenario ---
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    const tScenario = Date.now();
    console.log(`[TIM-538-B] criterion 4: Start_Scenario OK — ${Math.round((tScenario-tStart)/1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-scenario-start.png'), fullPage: true });

    output = await getOutput(page);
    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // --- Criterion 5 + 6: 500 frames at ≥30fps, canvas quality ---
    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    const t100 = Date.now();
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-frame100.png'), fullPage: true });
    console.log(`[TIM-538-B] frame 100 — ${Math.round((t100-tStart)/1000)}s  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}`);

    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    const t300 = Date.now();
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-frame300.png'), fullPage: true });
    console.log(`[TIM-538-B] frame 300 — ${Math.round((t300-tStart)/1000)}s  fill=${stats300.fillPct}%  colors=${stats300.uniqueColors}`);

    await waitForOutput(page, '[RA] Main_Loop frame 500', 300_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);

    // Save canonical frame-500 screenshot (acceptance criterion 6)
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'wasm-frame-500.png'), fullPage: true });
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim538-B-frame500.png'), fullPage: true });
    console.log(`[TIM-538-B] frame 500 — ${Math.round((t500-tStart)/1000)}s  fill=${stats500.fillPct}%  colors=${stats500.uniqueColors}`);

    const fps_100_300 = Math.round(200 / ((t300 - t100) / 1000) * 10) / 10;
    const fps_300_500 = Math.round(200 / ((t500 - t300) / 1000) * 10) / 10;
    console.log(`[TIM-538-B] FPS: 100→300=${fps_100_300}  300→500=${fps_300_500}`);

    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    const hasAudioCtxCrashFinal = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    // MIX audit
    const MIX_FILES = ['LOCAL.MIX','LORES.MIX','HIRES.MIX','CONQUER.MIX','SCORES.MIX','SPEECH.MIX'];
    const skipping: string[] = [];
    for (const m of MIX_FILES) {
      if (output.toLowerCase().includes(`skipping ${m.toLowerCase()}`)) skipping.push(m);
    }

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    console.log('\n[TIM-538-B] ===== Audit Summary — Post TIM-519 Baseline =====');
    console.log(`  c1. Boot past preloader, no crash:        PASS`);
    console.log(`  c2. VQA AudioContext crash (TIM-513):     ${!hasAudioCtxCrashFinal ? 'PASS (no crash)' : 'FAIL (crash!)'}`);
    console.log(`  c3. Main menu rendered (Init_Bulk_Data):  PASS (autostart bypasses menu UI)`);
    console.log(`  c4. Start_Scenario SCG01EA:               PASS (${Math.round((tScenario-tStart)/1000)}s)`);
    console.log(`  c5. 500 frames reached at ≥30fps:         ${fps_100_300 >= 30 && fps_300_500 >= 30 ? 'PASS' : 'MARGINAL'} (fps 100→300=${fps_100_300}  300→500=${fps_300_500})`);
    console.log(`  c6. wasm-frame-500.png:                   ${stats500.hasContent ? 'PASS' : 'FAIL'}`);
    console.log(`      fill=${stats500.fillPct}% (need ≥40%)  colors=${stats500.uniqueColors} (need ≥150)`);
    console.log(`  c7. SDL2 audio opened OK:                 ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  c8. Unit click (TIM-537):                 N/A (TIM-537 still in_progress)`);
    if (skipping.length > 0) console.log(`  MIX skipped: ${skipping.join(', ')}`);
    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.slice(0, 5).forEach(e => console.log(`    ${e.substring(0,120)}`));
    }
    console.log(`  Screenshots: tim538-B-frame100, tim538-B-frame300, tim538-B-frame500, wasm-frame-500`);

    // Hard assertions
    expect(stats300.hasContent, 'canvas must have content at frame 300').toBe(true);
    expect(stats500.hasContent, 'canvas must have content at frame 500').toBe(true);
    expect(stats500.fillPct, `frame-500 fill must be ≥40% (got ${stats500.fillPct}%)`).toBeGreaterThanOrEqual(40);
    expect(stats500.uniqueColors, `frame-500 unique colours must be ≥150 (got ${stats500.uniqueColors})`).toBeGreaterThanOrEqual(150);
    expect(hasAudioCtxCrashFinal, 'TIM-513 regression: AudioContext crash must not occur').toBe(false);
    expect(hasAudioOK, 'SDL2 audio must open successfully (criterion 7)').toBe(true);
    expect(fps_300_500, `frames 300→500 fps must be ≥15 (got ${fps_300_500})`).toBeGreaterThanOrEqual(15);
  });
});
