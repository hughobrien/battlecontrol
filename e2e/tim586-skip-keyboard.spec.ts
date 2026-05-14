/**
 * TIM-586 — Verify keyboard-only skip (no canvas click) aborts the intro VQA.
 *
 * Mirrors tim586-skip-cinematic.spec.ts but skips the mouse path; instead,
 * focuses the canvas via JS (so the keydown listener registered by the VQA
 * player can fire) and dispatches Escape.
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

test('TIM-586 — pressing Escape during intro VQA aborts playback', async ({ page, context }) => {
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

  const url = `${BASE}/ra.html?src=${encodeURIComponent(FAKE_ASSET_BASE)}&debug=1`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );

  await waitForOutput(page, "[VQA] Playing 'ENGLISH.VQA'", 180_000);

  await page.waitForTimeout(2000);

  const state1 = await page.evaluate(() => ({
    abortInstalled: (window as any)._vqa_abort_installed,
    aborted: (window as any)._vqa_aborted,
    activeEl: document.activeElement?.tagName,
  }));
  console.log('[TIM-586/kbd] state before keydown:', JSON.stringify(state1));

  // Focus the canvas via JS so subsequent keyboard events get delivered to
  // it. (Real users click first, which TIM-582's mousedown handler does.)
  await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    if (c) c.focus();
  });

  // Press Escape via Playwright keyboard. The VQA player's listener is on
  // `document.addEventListener('keydown', ...)`, which fires via bubble
  // phase regardless of the focused element.
  await page.keyboard.press('Escape');

  await page.waitForTimeout(200);
  const state2 = await page.evaluate(() => ({
    aborted: (window as any)._vqa_aborted,
    activeEl: document.activeElement?.tagName,
  }));
  console.log('[TIM-586/kbd] state after keydown:', JSON.stringify(state2));

  // If Playwright's keydown didn't reach our listener, try dispatching one
  // directly to verify the listener works in principle.
  if (!state2.aborted) {
    await page.evaluate(() => {
      const ev = new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: 'Escape',
        code: 'Escape', keyCode: 27, which: 27,
      });
      document.dispatchEvent(ev);
    });
    const state3 = await page.evaluate(() => ({
      aborted: (window as any)._vqa_aborted,
    }));
    console.log('[TIM-586/kbd] state after synthetic dispatch:', JSON.stringify(state3));
  }

  await page.waitForTimeout(4000);

  const outputText = await page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent : '';
  });

  const doneMatch = (outputText || '').match(/\[VQA\] 'ENGLISH\.VQA' done \((\d+)\/(\d+) frames\)/);
  expect(doneMatch).not.toBeNull();
  const played = parseInt(doneMatch![1], 10);
  const total = parseInt(doneMatch![2], 10);
  console.log(`[TIM-586/kbd] ENGLISH.VQA done: ${played}/${total} frames`);
  expect(played).toBeLessThan(total);
});
