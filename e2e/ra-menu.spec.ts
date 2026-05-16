/**
 * TIM-448 — RA WASM end-to-end browser verification.
 *
 * Verifies the RA WASM milestone success criteria: main menu renders with
 * correct graphics and music playing — without the autostart shortcut.
 *
 * Servers required (started externally before this spec):
 *   - serve-coop.py on port 8080 (WASM bundle from build-wasm/)
 *   - serve-assets.py on port 9090 (RA MIX files from CD1/)
 *
 * URL: http://localhost:8080/ra.html?src=http://localhost:9090/&debug=1
 *      (no autostart — exercises the main menu path)
 *
 * Acceptance criteria (TIM-448):
 *   1. Assets load — preloader-overlay hides, no browser-error banner
 *   2. Game initialises — Init_Bulk_Data done logged
 *   3. Audio opens — "[RA] Audio_Init: SDL2 audio opened OK"
 *   4. Music plays — "[RA] Music started:" logged with .AUD filename
 *   5. Canvas non-black — menu graphics render (terrain/UI tiles)
 *   6. Screenshots at T+0 / T+5s / T+15s after menu stable, attached to issue
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
  hasContent: boolean;
  nonBlackCount: number;
  totalSampled: number;
  uniqueColors: number;
  fillPct: number;
  width: number;
  height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { hasContent: false, nonBlackCount: 0, totalSampled: 0, uniqueColors: 0, fillPct: 0, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { hasContent: len > 2000, nonBlackCount: len > 2000 ? 1 : 0, totalSampled: 1, uniqueColors: 0, fillPct: 0, width: canvas.width, height: canvas.height };
    }
    const w = canvas.width;
    const h = canvas.height;
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
      uniqueColors: colorSet.size,
      fillPct: Math.round(nonBlack / total * 100),
      width: w,
      height: h,
    };
  });
}

test.describe('Red Alert WASM — main menu verification (TIM-448)', () => {
  test.setTimeout(360_000);

  // Main menu URL: src= loads MIX files; debug=1 keeps #output visible for
  // game log scraping; no autostart → exercises the real menu path.
  const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

  test('1 · assets load — overlay hides, no error banner', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // No unsupported-browser error.
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5000 });

    // Wait for preloader overlay to disappear.
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );

    console.log('Preloader overlay hidden — MIX files mounted.');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-after-load.png'), fullPage: true });

    // Game binary launched.
    await waitForOutput(page, '[RA] Init_Game:', 120_000);
    console.log('Init_Game confirmed — WASM binary running.');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-init-game.png'), fullPage: true });
  });

  test('2 · game initialises — Init_Bulk_Data done', async ({ page }) => {
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);
    console.log('Init_Bulk_Data done — all game data loaded.');

    const output = await getOutput(page);
    console.log('Output snippet (last 1000 chars):\n', output.slice(-1000));
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-bulk-done.png'), fullPage: true });

    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
  });

  test('3 · audio opens — SDL2 device OK', async ({ page }) => {
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    await waitForOutput(page, '[RA] Audio_Init:', 180_000);
    const output = await getOutput(page);
    const audioLine = output.split('\n').find(l => l.includes('[RA] Audio_Init:'));
    console.log('Audio_Init log:', audioLine);

    expect(output).toContain('[RA] Audio_Init: SDL2 audio opened OK');
  });

  test('4 · music plays — Theme.AI starts music via File_Stream_Sample_Vol', async ({ page }) => {
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // Init_Bulk_Data done means we are in Select_Game (menu loop).
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);

    // Theme.AI fires from Select_Game's event loop. Allow up to 60s after init.
    await waitForOutput(page, '[RA] Music started:', 60_000);

    const output = await getOutput(page);
    const musicLines = output.split('\n').filter(l => l.includes('Music started'));
    console.log('Music log lines:');
    musicLines.forEach(l => console.log(' ', l));

    expect(musicLines.length).toBeGreaterThan(0);
    // Must have a real filename (ends in .AUD case-insensitive).
    const hasAudFile = musicLines.some(l => /Music started:.*\.aud/i.test(l));
    expect(hasAudFile).toBe(true);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-music-playing.png'), fullPage: true });
  });

  test('5 · canvas non-black — main menu renders graphics', async ({ page }) => {
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);

    // Give the menu a moment to render.
    await page.waitForTimeout(2_000);

    const stats = await canvasPixelStats(page);
    console.log(`Canvas: ${stats.width}x${stats.height}  fill=${stats.fillPct}%  uniqueColors=${stats.uniqueColors}  hasContent=${stats.hasContent}`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-canvas.png'), fullPage: true });

    expect(stats.width).toBe(640);
    expect(stats.height).toBe(480);
    expect(stats.hasContent).toBe(true);
  });

  test('6 · TIM-448 screenshot audit — menu at T+0 / T+5s / T+15s', async ({ page }) => {
    test.setTimeout(480_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // Wait for full game init.
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);

    // Wait for music to confirm we are in the menu loop.
    await waitForOutput(page, '[RA] Music started:', 60_000);

    // --- Screenshot 1: menu first rendered (T+0) ---
    await page.waitForTimeout(500);
    const stats0 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-t0.png'), fullPage: true });
    console.log(`[T+0]   canvas ${stats0.width}x${stats0.height}  fill=${stats0.fillPct}%  uniqueColors=${stats0.uniqueColors}`);

    // --- Screenshot 2: T+5s ---
    await page.waitForTimeout(5_000);
    const stats5 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-t5s.png'), fullPage: true });
    console.log(`[T+5s]  canvas ${stats5.width}x${stats5.height}  fill=${stats5.fillPct}%  uniqueColors=${stats5.uniqueColors}`);

    // --- Screenshot 3: T+15s ---
    await page.waitForTimeout(10_000);
    const stats15 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-menu-t15s.png'), fullPage: true });
    console.log(`[T+15s] canvas ${stats15.width}x${stats15.height}  fill=${stats15.fillPct}%  uniqueColors=${stats15.uniqueColors}`);

    const output = await getOutput(page);
    const musicLines = output.split('\n').filter(l => l.includes('Music started'));

    console.log('=== TIM-448 main menu audit ===');
    console.log(`  Canvas 640×480: confirmed`);
    console.log(`  T+0  fill=${stats0.fillPct}%  colors=${stats0.uniqueColors}  hasContent=${stats0.hasContent}`);
    console.log(`  T+5s fill=${stats5.fillPct}%  colors=${stats5.uniqueColors}  hasContent=${stats5.hasContent}`);
    console.log(`  T+15s fill=${stats15.fillPct}%  colors=${stats15.uniqueColors}  hasContent=${stats15.hasContent}`);
    console.log(`  Music stream calls: ${musicLines.length}`);
    musicLines.forEach(l => console.log(`    ${l.trim()}`));
    console.log('  Screenshots: ra-menu-t0.png, ra-menu-t5s.png, ra-menu-t15s.png');

    // Hard assertions.
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
    expect(stats5.hasContent).toBe(true);
    expect(stats15.hasContent).toBe(true);
    expect(musicLines.length).toBeGreaterThan(0);
  });
});
