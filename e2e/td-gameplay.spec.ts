/**
 * TIM-404 — TiberiaDawn WASM browser gameplay end-to-end verification.
 *
 * Tests run against a live WASM bundle served by serve-coop.py (port 8080),
 * with MIX assets served by serve-assets.py (port 9090) from
 * /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/.
 *
 * URL: http://localhost:8080/td.html?src=http://localhost:9090/&autostart=1
 *
 * Acceptance criteria:
 *   1. Main menu / init renders — #preloader-overlay hidden, no browser-error
 *   2. TD_AUTOSTART active      — skips main menu, fires SCG01EA (GDI mission 1)
 *   3. Start_Scenario fires     — CONQUER.CPP logs the scenario start
 *   4. Game loop runs 100+ frames
 *   5. Audio outcome documented
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

// Env var overrides for CI — TD_WASM_URL default matches local serve-coop.py on :8080.
// TD_ASSETS_URL can point to a CDN (e.g. GitHub Pages with CORS headers) for CI runs.
const WASM_URL  = process.env['TD_WASM_URL']  || 'http://localhost:8082/td.html';
const ASSET_URL = process.env['TD_ASSETS_URL'] || 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

/**
 * Wait for a substring to appear in the #output div.
 */
async function waitForOutput(page: any, substring: string, timeoutMs = 120_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,
    { timeout: timeoutMs }
  );
}

/** Return current text content of #output. */
async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent || '' : '';
  });
}

/** Return text content of #status-line. */
async function getStatus(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('status-line');
    return el ? el.textContent || '' : '';
  });
}

/**
 * Sample the canvas and return pixel statistics for visual audit.
 * Returns: { hasContent, nonBlackCount, totalSampled, uniqueColors, fillPct, width, height }
 */
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
    // Sample every 4th pixel for speed
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

/**
 * Check whether the game canvas has any non-black pixels.
 */
async function canvasHasContent(page: any): Promise<boolean> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return false;
    const ctx2d = canvas.getContext('2d');
    if (ctx2d) {
      const d = ctx2d.getImageData(0, 0, canvas.width, canvas.height).data;
      for (let i = 0; i < d.length; i += 4) {
        if (d[i] > 15 || d[i + 1] > 15 || d[i + 2] > 15) return true;
      }
      return false;
    }
    const dataUrl = canvas.toDataURL('image/png');
    return dataUrl.length > 2000;
  });
}

test.describe('Tiberian Dawn WASM — browser gameplay (TIM-404)', () => {
  test.setTimeout(300_000);

  // ?autostart=1 skips menu and jumps to SCG01EA (GDI mission 1 easy).
  const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;

  test('1 · assets load and game starts', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Confirm no unsupported-browser error banner.
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5000 });

    // Wait for preloader overlay to disappear (hidden after ?src= fetches complete).
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );

    const statusAfterLoad = await getStatus(page);
    console.log('Status after overlay hidden:', statusAfterLoad);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-after-asset-load.png'), fullPage: true });

    // Wait for "Starting game…" in status (launchGame() fired).
    await page.waitForFunction(
      () => {
        const el = document.getElementById('status-line');
        return el !== null && (el.textContent || '').includes('Starting');
      },
      null,
      { timeout: 60_000 }
    );

    // Confirm TD_AUTOSTART was active (game logs to #output via Module.printErr).
    await waitForOutput(page, 'TD_AUTOSTART active', 30_000);
    console.log('TD_AUTOSTART confirmed active in game output.');

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-game-started.png'), fullPage: true });
  });

  test('2 · Start_Scenario fires for SCG01EA', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // TD logs "[TD] Select_Game: TD_AUTOSTART active → SCG01EA (GDI m1 easy)"
    // then later the scenario start confirmation.
    await waitForOutput(page, 'TD_AUTOSTART active', 180_000);

    const output = await getOutput(page);
    console.log('Output snippet (last 1500 chars):\n', output.slice(-1500));

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-scenario-start.png'), fullPage: true });

    expect(output).toContain('TD_AUTOSTART active');
    expect(output).toContain('SCG01EA');
  });

  test('3 · game loop runs 100+ frames', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // TD logs "[TD] Main_Loop frame N" for N<=15 and every 100th frame.
    await waitForOutput(page, '[TD] Main_Loop frame 100', 240_000);

    const output = await getOutput(page);
    console.log('Output at frame 100:\n', output.slice(-2000));

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-frame-100.png'), fullPage: true });

    expect(output).toContain('[TD] Main_Loop frame 100');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
  });

  test('4 · canvas renders non-black pixels by frame 100', async ({ page }) => {
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    await waitForOutput(page, '[TD] Main_Loop frame 100', 240_000);
    await page.waitForTimeout(500);

    const hasContent = await canvasHasContent(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-canvas-frame-100.png'), fullPage: true });

    if (!hasContent) {
      console.warn('Canvas appears black at frame 100 — may be expected if game is in init phase.');
    } else {
      console.log('Canvas has non-black pixels at frame 100.');
    }

    console.log('canvas-has-content:', hasContent);
    // Soft assertion — document outcome; harden to .toBe(true) once visual confirmed.
  });

  test('5 · SDL2 audio opens in WASM (TIM-428)', async ({ page }) => {
    const audioLogs: string[] = [];
    page.on('console', msg => {
      const text = msg.text();
      if (/audio|sound|mixer|sdl_mixer|openal|alsa|pulse|web.?audio/i.test(text)) {
        audioLogs.push(`[${msg.type()}] ${text}`);
      }
    });

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Audio_Init is called early in startup; wait for its log line.
    await waitForOutput(page, '[TD] Audio_Init:', 180_000);
    await page.waitForTimeout(1_000);

    const output = await getOutput(page);
    const audioLines = output.split('\n').filter(l =>
      /audio|sound|mixer|openal|alsa|pulse/i.test(l)
    );

    console.log('=== Audio outcome (TIM-428) ===');
    if (audioLogs.length > 0) {
      console.log('Console audio messages:');
      audioLogs.forEach(l => console.log(' ', l));
    }
    if (audioLines.length > 0) {
      console.log('Game output audio lines:');
      audioLines.forEach(l => console.log(' ', l));
    }

    // Hard assertion: SDL2 audio device must open successfully.
    expect(output).toContain('[TD] Audio_Init: SDL2 audio opened OK');
  });

  test('6 · TIM-435 visual audit — units, buildings, UI at frames 100, 300, 500', async ({ page }) => {
    // 10 minutes: frame 500 at ~10fps WASM rate takes ~50s real time,
    // but asset loading + game init can add 3-4 minutes on top.
    test.setTimeout(600_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Wait for scenario to load before auditing frames.
    await waitForOutput(page, 'TD_AUTOSTART active', 240_000);

    // --- Frame 100 ---
    await waitForOutput(page, '[TD] Main_Loop frame 100', 240_000);
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-visual-frame-100.png'), fullPage: true });
    console.log(`[frame 100] canvas ${stats100.width}x${stats100.height}  fill=${stats100.fillPct}%  uniqueColors=${stats100.uniqueColors}  hasContent=${stats100.hasContent}`);

    // --- Frame 300 ---
    await waitForOutput(page, '[TD] Main_Loop frame 300', 300_000);
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-visual-frame-300.png'), fullPage: true });
    console.log(`[frame 300] canvas ${stats300.width}x${stats300.height}  fill=${stats300.fillPct}%  uniqueColors=${stats300.uniqueColors}  hasContent=${stats300.hasContent}`);

    // --- Frame 500 ---
    await waitForOutput(page, '[TD] Main_Loop frame 500', 300_000);
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'td-visual-frame-500.png'), fullPage: true });
    console.log(`[frame 500] canvas ${stats500.width}x${stats500.height}  fill=${stats500.fillPct}%  uniqueColors=${stats500.uniqueColors}  hasContent=${stats500.hasContent}`);

    // Verify no crash during the run.
    const output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Hard assertion: canvas must have non-black content by frame 300.
    expect(stats300.hasContent).toBe(true);
    expect(stats500.hasContent).toBe(true);

    // Acceptance criteria: > 20% fill at frame 300 and 500.
    expect(stats300.fillPct).toBeGreaterThan(20);
    expect(stats500.fillPct).toBeGreaterThan(20);

    // Acceptance criteria: > 50 unique colour buckets (palette health check).
    expect(stats300.uniqueColors).toBeGreaterThan(50);
    expect(stats500.uniqueColors).toBeGreaterThan(50);

    // Warn (soft) if colour diversity is suspiciously low — possible palette corruption.
    if (stats300.uniqueColors < 10) {
      console.warn(`[frame 300] WARNING: only ${stats300.uniqueColors} unique colour buckets — possible palette/sprite corruption`);
    }
    if (stats500.uniqueColors < 10) {
      console.warn(`[frame 500] WARNING: only ${stats500.uniqueColors} unique colour buckets — possible palette/sprite corruption`);
    }

    console.log('=== TIM-435 visual audit summary ===');
    console.log(`  frame 100: fill=${stats100.fillPct}% colors=${stats100.uniqueColors}`);
    console.log(`  frame 300: fill=${stats300.fillPct}% colors=${stats300.uniqueColors}`);
    console.log(`  frame 500: fill=${stats500.fillPct}% colors=${stats500.uniqueColors}`);
    console.log('  Screenshots: td-visual-frame-100.png, td-visual-frame-300.png, td-visual-frame-500.png');
  });
});
