/**
 * TIM-586 — Verify intro VQA cinematics can be skipped on the local WASM
 * build via canvas click or keyboard event.
 *
 * Targets http://localhost:8081 (a fresh build of this worktree). Local MIX
 * assets are served from /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 via
 * Playwright's context.route() interception, same as TIM-579.
 *
 * Pass criteria: "[VQA] 'ENGLISH.VQA' done (N/M frames)" with N < M after a
 * canvas click during playback.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const ASSET_DIR = '/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1';
const FAKE_ASSET_BASE = 'http://localhost:8081/__assets__/';
const BASE = 'http://localhost:8081';

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

test('TIM-586 — clicking canvas during intro VQA aborts playback', async ({ page, context }) => {
  test.setTimeout(420_000);

  await context.route(`${FAKE_ASSET_BASE}*`, async (route) => {
    const url = new URL(route.request().url());
    const filename = path.basename(url.pathname);
    const filepath = path.join(ASSET_DIR, filename);
    try {
      const buf = fs.readFileSync(filepath);
      await route.fulfill({
        status: 200,
        contentType: 'application/octet-stream',
        body: buf,
        headers: {
          'access-control-allow-origin': '*',
          'cross-origin-resource-policy': 'cross-origin',
          'cache-control': 'no-cache',
        },
      });
    } catch (e: any) {
      await route.fulfill({ status: 404, body: 'not found: ' + filename });
    }
  });

  const consoleLines: string[] = [];
  page.on('console', (msg: any) => consoleLines.push(`[console:${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => consoleLines.push(`[pageerror] ${err.message}`));

  const url = `${BASE}/ra.html?src=${encodeURIComponent(FAKE_ASSET_BASE)}&debug=1`;
  console.log(`[TIM-586] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[TIM-586] preloader hidden — assets mounted');

  await waitForOutput(page, "[VQA] Playing 'ENGLISH.VQA'", 180_000);
  console.log('[TIM-586] VQA playback started');

  // Let a few frames render so the abort is observably mid-play.
  await page.waitForTimeout(2000);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim586-pre-click.png') });

  // ── Try to abort via canvas click ─────────────────────────────────────────
  const canvas = page.locator('#canvas');
  await canvas.click({ position: { x: 320, y: 240 } });
  console.log('[TIM-586] canvas clicked at center');

  // Wait long enough for the player's per-frame poll to observe the flag and
  // the audio drain (the post-loop SDL_Delay drain after user_abort) to run.
  await page.waitForTimeout(4000);

  const outputText = await page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent : '';
  });

  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim586-output.log'),
    `=== console ===\n${consoleLines.join('\n')}\n\n=== #output ===\n${outputText}\n`,
  );

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim586-post-click.png') });

  const doneMatch = (outputText || '').match(/\[VQA\] 'ENGLISH\.VQA' done \((\d+)\/(\d+) frames\)/);
  const abortMatch = (outputText || '').match(/\[VQA\] 'ENGLISH\.VQA' aborted by user/);
  if (doneMatch) {
    const playedFrames = parseInt(doneMatch[1], 10);
    const totalFrames = parseInt(doneMatch[2], 10);
    console.log(`[TIM-586] ENGLISH.VQA done: ${playedFrames}/${totalFrames} frames`);
    console.log(`[TIM-586] abort line present: ${abortMatch != null}`);
    expect(playedFrames).toBeLessThan(totalFrames);
  } else {
    console.log('[TIM-586] no "done" line yet — VQA still running, skip is broken');
    expect(doneMatch).not.toBeNull();
  }
});
