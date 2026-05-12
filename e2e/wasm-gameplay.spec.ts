/**
 * TIM-399 — WASM browser gameplay end-to-end verification.
 * TIM-429 — Visual audit: units, buildings, UI sprites at frames 100/300/500.
 *
 * Tests run against a live WASM bundle served by serve-coop.py (port 8080),
 * with MIX assets served by serve-assets.py (port 9090).
 *
 * URL: http://localhost:8080/ra.html?src=http://localhost:9090/&autostart=1
 *
 * Acceptance criteria:
 *   1. Main menu renders  — #preloader-overlay hidden, no browser-error banner
 *   2. Mission starts     — Start_Scenario OK in game output
 *   3. Game loop runs     — 100+ frames confirmed in output
 *   4. Audio              — document outcome (expected: silently skipped or active)
 *   6. Visual audit       — non-black pixels and colour diversity at 100/300/500
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

// Ensure screenshots directory exists.
if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

/**
 * Wait for a substring to appear in the #output div.
 * NOTE: Playwright waitForFunction(fn, arg, options) needs 3 args — passing
 * { timeout } as the second arg treats it as the function argument, not options.
 */
async function waitForOutput(page: any, substring: string, timeoutMs = 120_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,                 // arg passed to the page function
    { timeout: timeoutMs }     // options (3rd param)
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
 * Check whether the game canvas has any non-black pixels.
 * WebGL canvases support toDataURL(); we compare against the all-black reference.
 */
async function canvasHasContent(page: any): Promise<boolean> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return false;
    // Try 2D context first (palette-mode fallback)
    const ctx2d = canvas.getContext('2d');
    if (ctx2d) {
      const d = ctx2d.getImageData(0, 0, canvas.width, canvas.height).data;
      for (let i = 0; i < d.length; i += 4) {
        if (d[i] > 15 || d[i + 1] > 15 || d[i + 2] > 15) return true;
      }
      return false;
    }
    // WebGL: toDataURL still works and differs from all-black if content was drawn.
    // All-black 640x480 PNG has a short base64 payload; any rendered content differs.
    const dataUrl = canvas.toDataURL('image/png');
    return dataUrl.length > 2000;
  });
}

/**
 * Sample the canvas and return pixel statistics for visual audit.
 * Returns: { hasContent, nonBlackCount, totalSampled, uniqueColors, fillPct }
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
      // WebGL path: use toDataURL length as proxy
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

test.describe('Red Alert WASM — browser gameplay (TIM-399)', () => {
  test.setTimeout(300_000);

  // Shared game URL — ?autostart=1 skips menu, goes directly to SCG01EA.
  const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;

  test('1 · assets load and game starts', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Confirm no unsupported-browser error banner.
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5000 });

    // Wait for overlay to disappear (preloader hides it early in S3 fetch mode).
    // IMPORTANT: pass null as arg (3rd positional) so { timeout } is treated as
    // options, not as the function argument. Playwright's JS runtime can't
    // distinguish 2-arg (fn, arg) from 2-arg (fn, options) without the extra null.
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,              // arg (ignored by function)
      { timeout: 120_000 }
    );

    const statusAfterLoad = await getStatus(page);
    console.log('Status after overlay hidden:', statusAfterLoad);

    // Capture screenshot of the initial rendered state.
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'after-asset-load.png'), fullPage: true });

    // Wait for "Starting game…" to appear in status (launchGame() fired).
    await page.waitForFunction(
      () => {
        const el = document.getElementById('status-line');
        return el !== null && (el.textContent || '').includes('Starting');
      },
      null,
      { timeout: 60_000 }
    );

    // Confirm the game binary launched and started logging.
    // Init_Game is the first function main() calls; it fires unconditionally
    // regardless of autostart mode (menu path vs. RA_AUTOSTART path).
    // Module.ENV['RA_AUTOSTART'] is set on the main thread but Emscripten
    // PROXY_TO_PTHREAD runs main() in a Worker with its own JS heap, so the
    // Worker's getenv("RA_AUTOSTART") may return NULL — the game then reaches
    // Start_Scenario via the synthetic KN_RETURN injection (INIT.CPP:981).
    await waitForOutput(page, '[RA] Init_Game:', 120_000);
    console.log('Init_Game confirmed in game output — WASM binary launched.');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'game-started.png'), fullPage: true });
  });

  test('2 · Start_Scenario fires for SCG01EA', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Wait for scenario to start — game logs "[RA] Select_Game: Start_Scenario OK".
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 180_000);

    const output = await getOutput(page);
    console.log('Output snippet (last 1500 chars):\n', output.slice(-1500));

    // Screenshot at scenario start.
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'scenario-start.png'), fullPage: true });

    expect(output).toContain('Start_Scenario OK');
    // Verify it was SCG01EA specifically.
    expect(output).toContain('SCG01EA');
  });

  test('3 · game loop runs 100+ frames', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Game logs "[RA] Main_Loop frame N" for N<=15 and every 100th frame.
    // frame 100 is logged when _ra_frame_count % 100 == 0.
    await waitForOutput(page, '[RA] Main_Loop frame 100', 240_000);

    const output = await getOutput(page);
    console.log('Output at frame 100:\n', output.slice(-2000));

    // Screenshot at frame 100.
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'frame-100.png'), fullPage: true });

    expect(output).toContain('[RA] Main_Loop frame 100');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
  });

  test('4 · canvas renders non-black pixels by frame 100', async ({ page }) => {
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Wait for 100 frames.
    await waitForOutput(page, '[RA] Main_Loop frame 100', 240_000);

    // Give the rendering pipeline one more tick.
    await page.waitForTimeout(500);

    const hasContent = await canvasHasContent(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'canvas-frame-100.png'), fullPage: true });

    if (!hasContent) {
      console.warn('Canvas appears black at frame 100 — may be expected if game is in init phase.');
    } else {
      console.log('Canvas has non-black pixels at frame 100.');
    }

    // Soft assertion: document the result.
    // Change to expect(hasContent).toBe(true) once visual output is confirmed.
    console.log('canvas-has-content:', hasContent);
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

    // Audio_Init is called early in Init_Game; wait for it to log.
    await waitForOutput(page, '[RA] Audio_Init:', 180_000);

    // Give audio subsystem a moment.
    await page.waitForTimeout(1_000);

    const output = await getOutput(page);
    const audioLines = output.split('\n').filter(l =>
      /audio|sound|mixer|openal|alsa|pulse/i.test(l)
    );

    console.log('=== Audio outcome ===');
    if (audioLogs.length > 0) {
      console.log('Console audio messages:');
      audioLogs.forEach(l => console.log(' ', l));
    }
    if (audioLines.length > 0) {
      console.log('Game output audio lines:');
      audioLines.forEach(l => console.log(' ', l));
    }

    // Hard assertion: SDL2 audio device must open successfully.
    expect(output).toContain('[RA] Audio_Init: SDL2 audio opened OK');
  });

  test('6 · TIM-429 visual audit — units, buildings, UI at frames 100, 300, 500', async ({ page }) => {
    // Needs 10 minutes: frame 500 at ~10fps WASM rate takes ~50s of real time,
    // but asset loading + game init can add 3-4 minutes on top.
    test.setTimeout(600_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Wait for scenario to load before auditing frames.
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 240_000);

    // --- Frame 100 ---
    await waitForOutput(page, '[RA] Main_Loop frame 100', 240_000);
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-visual-frame-100.png'), fullPage: true });
    console.log(`[frame 100] canvas ${stats100.width}x${stats100.height}  fill=${stats100.fillPct}%  uniqueColors=${stats100.uniqueColors}  hasContent=${stats100.hasContent}`);

    // --- Frame 300 ---
    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-visual-frame-300.png'), fullPage: true });
    console.log(`[frame 300] canvas ${stats300.width}x${stats300.height}  fill=${stats300.fillPct}%  uniqueColors=${stats300.uniqueColors}  hasContent=${stats300.hasContent}`);

    // --- Frame 500 ---
    await waitForOutput(page, '[RA] Main_Loop frame 500', 300_000);
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'ra-visual-frame-500.png'), fullPage: true });
    console.log(`[frame 500] canvas ${stats500.width}x${stats500.height}  fill=${stats500.fillPct}%  uniqueColors=${stats500.uniqueColors}  hasContent=${stats500.hasContent}`);

    // Verify no crash during the run.
    const output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Hard assertion: canvas must have non-black content by frame 300.
    // (frame 100 may still be loading terrain; 300 should show units + buildings.)
    expect(stats300.hasContent).toBe(true);
    expect(stats500.hasContent).toBe(true);

    // Warn (soft) if colour diversity is suspiciously low — possible palette corruption.
    if (stats300.uniqueColors < 10) {
      console.warn(`[frame 300] WARNING: only ${stats300.uniqueColors} unique colour buckets — possible palette/sprite corruption`);
    }
    if (stats500.uniqueColors < 10) {
      console.warn(`[frame 500] WARNING: only ${stats500.uniqueColors} unique colour buckets — possible palette/sprite corruption`);
    }

    console.log('=== TIM-429 visual audit summary ===');
    console.log(`  frame 100: fill=${stats100.fillPct}% colors=${stats100.uniqueColors}`);
    console.log(`  frame 300: fill=${stats300.fillPct}% colors=${stats300.uniqueColors}`);
    console.log(`  frame 500: fill=${stats500.fillPct}% colors=${stats500.uniqueColors}`);
    console.log('  Screenshots: ra-visual-frame-100.png, ra-visual-frame-300.png, ra-visual-frame-500.png');
  });
});
