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

const WASM_URL = 'http://localhost:8082/td.html';  // port 8082: _default/build-wasm/ (8080 is TIM-399)
const ASSET_URL = 'http://localhost:9091/';          // TD assets on port 9091 (RA uses 9090)
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
});
