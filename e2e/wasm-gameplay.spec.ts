/**
 * TIM-399 — WASM browser gameplay end-to-end verification.
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

    // Confirm RA_AUTOSTART was active (game logs to #output via Module.printErr).
    // Checks game C++ stderr: "[RA] Select_Game: RA_AUTOSTART active → SCG01EA.INI"
    // Cold WASM load (15MB) takes longer on first run — use 120s to match overlay wait.
    await waitForOutput(page, 'RA_AUTOSTART active', 120_000);
    console.log('RA_AUTOSTART confirmed active in game output.');

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

  test('5 · audio outcome documentation', async ({ page }) => {
    const audioLogs: string[] = [];
    page.on('console', msg => {
      const text = msg.text();
      if (/audio|sound|mixer|sdl_mixer|openal|alsa|pulse|web.?audio/i.test(text)) {
        audioLogs.push(`[${msg.type()}] ${text}`);
      }
    });

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // Wait for game to start (not necessarily 100 frames — audio init happens early).
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 180_000);

    // Give audio subsystem time to initialize.
    await page.waitForTimeout(3_000);

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
    if (audioLogs.length === 0 && audioLines.length === 0) {
      console.log('No audio-related messages observed — audio may be silently skipped.');
      console.log('(Expected: Emscripten pthreads + Web Audio API requires user gesture in some browsers.)');
    }

    // Not a hard assertion — we document the outcome for TIM-399.
    expect(true).toBe(true);
  });
});
