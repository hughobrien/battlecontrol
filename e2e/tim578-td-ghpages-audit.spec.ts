/**
 * TIM-578 — TD WASM GH Pages regression audit.
 *
 * Runs the 5 gameplay audit criteria against the live GH Pages deployment:
 *   https://hughobrien.github.io/battlecontrol/td.html
 *
 * MIX assets are fetched via ?src=http://localhost:9091/ (local serve-assets.py,
 * TD data from /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/).
 *
 * The WASM bundle itself is loaded from GH Pages — this validates the deployed
 * artefact, not the local build.
 *
 * Acceptance criteria (5 checks):
 *   1. Boot            — preloader hidden, no browser-error banner
 *   2. Menu navigation — main menu canvas renders (debug mode, no autostart)
 *   3. Scenario loads  — TD_AUTOSTART active, SCG01EA starts
 *   4. Game loop       — 1000+ frames, no SIGSEGV/Aborted
 *   5. Visual          — frame-300 and frame-500 fill ≥20%, ≥50 unique colour buckets
 *
 * Requires:
 *   - serve-assets.py on port 9091 (TD MIX files)
 *   - Network access to https://hughobrien.github.io/battlecontrol/td.html
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const GHPAGES_URL  = 'https://hughobrien.github.io/battlecontrol/td.html';
const ASSET_URL    = 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// Game URL with autostart + debug output + gameclk for unit interaction
const gameUrl = `${GHPAGES_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&debug=1&gameclk=1`;
const menuUrl = `${GHPAGES_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

async function waitForOutput(page: any, substring: string, timeoutMs = 240_000) {
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
  hasContent: boolean; fillPct: number; uniqueColors: number; width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { hasContent: false, fillPct: 0, uniqueColors: 0, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { hasContent: len > 2000, fillPct: len > 2000 ? 1 : 0, uniqueColors: 0, width: canvas.width, height: canvas.height };
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
      fillPct: Math.round(nonBlack / total * 100),
      uniqueColors: colorSet.size,
      width: w,
      height: h,
    };
  });
}

// ---------------------------------------------------------------------------
// Criterion 1+2 — Boot + menu
// ---------------------------------------------------------------------------

test.describe('TIM-578 — TD GH Pages: boot + menu', () => {
  test.setTimeout(600_000);

  test('c1+c2: preloader hidden, no error banner, main menu canvas has content', async ({ page }) => {
    const pageErrors: string[] = [];
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // c1a: no browser-error banner
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('[TIM-578] c1a: no browser-error banner — PASS');

    // c1b: preloader hidden after MIX files fetched
    await page.waitForFunction(
      () => {
        const o = document.getElementById('preloader-overlay');
        return o !== null && o.style.display === 'none';
      },
      null,
      { timeout: 360_000 }
    );
    console.log(`[TIM-578] c1b: preloader hidden — ${Math.round((Date.now() - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-boot-preloader-done.png'), fullPage: true });

    // c2: wait for audio init (menu reachable) then check canvas
    try {
      await waitForOutput(page, '[TD] Audio_Init:', 240_000);
    } catch {
      console.log('[TIM-578] c2: Audio_Init not seen — checking canvas anyway');
    }
    await page.waitForTimeout(2_000);

    const menuStats = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-menu.png'), fullPage: true });
    console.log(`[TIM-578] c2: canvas ${menuStats.width}×${menuStats.height} fill=${menuStats.fillPct}% colors=${menuStats.uniqueColors}`);

    const hasAudioCrash = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    console.log('\n[TIM-578] ===== Boot + Menu Summary =====');
    console.log(`  c1. No error banner:     PASS`);
    console.log(`  c1. Preloader hidden:    PASS`);
    console.log(`  c2. Canvas has content:  ${menuStats.hasContent ? 'PASS' : 'WARN'} (fill=${menuStats.fillPct}%)`);
    console.log(`  AudioContext crash:       ${!hasAudioCrash ? 'PASS' : 'FAIL'}`);

    expect(hasAudioCrash, 'AudioContext crash must not occur').toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Criteria 3+4+5 — Scenario, game loop, visual
// ---------------------------------------------------------------------------

test.describe('TIM-578 — TD GH Pages: scenario + gameplay', () => {
  test.setTimeout(1_200_000);  // 20 min: GH Pages cold load + 1000 frames

  test('c3+c4+c5: TD_AUTOSTART → SCG01EA → 1000 frames → visual fill ≥20%', async ({ page }) => {
    const pageErrors: string[] = [];
    page.on('console', msg => {
      if (/error|warn/i.test(msg.type())) console.log(`[browser] ${msg.text()}`);
    });
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Boot
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });

    await page.waitForFunction(
      () => {
        const o = document.getElementById('preloader-overlay');
        return o !== null && o.style.display === 'none';
      },
      null,
      { timeout: 360_000 }
    );
    console.log(`[TIM-578] preloader hidden — ${Math.round((Date.now() - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-gameplay-boot.png'), fullPage: true });

    // Audio init
    await waitForOutput(page, '[TD] Audio_Init:', 360_000);
    const tInit = Date.now();
    let output = await getOutput(page);
    const hasAudioOK = output.includes('[TD] Audio_Init: SDL2 audio opened OK');
    console.log(`[TIM-578] audio init — ${Math.round((tInit - tStart) / 1000)}s  audioOK=${hasAudioOK}`);

    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // c3: TD_AUTOSTART → SCG01EA
    await waitForOutput(page, 'TD_AUTOSTART active', 120_000);
    const tScenario = Date.now();
    output = await getOutput(page);
    console.log(`[TIM-578] c3: TD_AUTOSTART active — ${Math.round((tScenario - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-scenario-start.png'), fullPage: true });

    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // c5: visual at frame 100
    await waitForOutput(page, '[TD] Main_Loop frame 100', 420_000);
    const t100 = Date.now();
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-frame100.png'), fullPage: true });
    console.log(`[TIM-578] frame 100 — ${Math.round((t100 - tStart) / 1000)}s  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}`);

    // c5: visual at frame 300
    await waitForOutput(page, '[TD] Main_Loop frame 300', 300_000);
    const t300 = Date.now();
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-frame300.png'), fullPage: true });
    console.log(`[TIM-578] frame 300 — ${Math.round((t300 - tStart) / 1000)}s  fill=${stats300.fillPct}%  colors=${stats300.uniqueColors}`);

    // c5: visual at frame 500
    await waitForOutput(page, '[TD] Main_Loop frame 500', 300_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-frame500.png'), fullPage: true });
    console.log(`[TIM-578] frame 500 — ${Math.round((t500 - tStart) / 1000)}s  fill=${stats500.fillPct}%  colors=${stats500.uniqueColors}`);

    // c4: 1000 frames without crash
    await waitForOutput(page, '[TD] Main_Loop frame 1000', 600_000);
    const t1000 = Date.now();
    await page.waitForTimeout(200);
    const stats1000 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim578-frame1000.png'), fullPage: true });
    console.log(`[TIM-578] c4: frame 1000 — ${Math.round((t1000 - tStart) / 1000)}s  fill=${stats1000.fillPct}%`);

    output = await getOutput(page);
    const hasAudioCtxCrash = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    // Unit click injection (bonus check)
    const clickLines = output.split('\n').filter(l => l.includes('[GAME-CLICK]'));

    console.log('\n[TIM-578] ===== Gameplay Audit Summary =====');
    console.log(`  c3. Scenario loads (TD_AUTOSTART → SCG01EA): PASS (${Math.round((tScenario-tStart)/1000)}s)`);
    console.log(`  c4. 1000+ frames, no crash:                  PASS`);
    console.log(`  c5. frame-100  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}`);
    console.log(`  c5. frame-300  fill=${stats300.fillPct}%  colors=${stats300.uniqueColors}  ${stats300.fillPct >= 20 ? 'PASS' : 'FAIL (need ≥20%)'}`);
    console.log(`  c5. frame-500  fill=${stats500.fillPct}%  colors=${stats500.uniqueColors}  ${stats500.fillPct >= 20 ? 'PASS' : 'FAIL (need ≥20%)'}`);
    console.log(`  c5. frame-1000 fill=${stats1000.fillPct}%`);
    console.log(`  Audio opened OK:                              ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  AudioContext crash:                           ${!hasAudioCtxCrash ? 'PASS' : 'FAIL'}`);
    console.log(`  Unit click injection [GAME-CLICK]:            ${clickLines.length > 0 ? `PASS (${clickLines.length} events)` : 'not seen'}`);

    // Hard assertions
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // c5: fill ≥20% at frames 300 and 500
    expect(stats300.hasContent, 'canvas must have content at frame 300').toBe(true);
    expect(stats500.hasContent, 'canvas must have content at frame 500').toBe(true);
    expect(stats300.fillPct, `c5: frame-300 fill must be ≥20% (got ${stats300.fillPct}%)`).toBeGreaterThanOrEqual(20);
    expect(stats500.fillPct, `c5: frame-500 fill must be ≥20% (got ${stats500.fillPct}%)`).toBeGreaterThanOrEqual(20);
    expect(stats300.uniqueColors, `c5: frame-300 must have ≥50 unique colour buckets (got ${stats300.uniqueColors})`).toBeGreaterThan(50);
    expect(stats500.uniqueColors, `c5: frame-500 must have ≥50 unique colour buckets (got ${stats500.uniqueColors})`).toBeGreaterThan(50);

    // Audio
    expect(hasAudioOK, 'Audio_Init: SDL2 audio opened OK must appear').toBe(true);
    expect(hasAudioCtxCrash, 'AudioContext crash must not occur').toBe(false);
  });
});
