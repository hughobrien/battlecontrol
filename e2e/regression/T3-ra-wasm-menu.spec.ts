/**
 * T3 — RA WASM main menu renders (TIM-623).
 *
 * With-assets regression: boot RA WASM via the asset CDN, wait for the
 * preloader to hide and Init_Bulk_Data to complete, then assert the
 * canvas has rendered the main menu (TITLE.PCX + side bar).
 *
 * Catches palette-shift regressions (TIM-141 class), TITLE.PCX load
 * failures, and blank-canvas regressions (TIM-250 class).
 *
 * Servers required (started by scripts/regression-suite.sh):
 *   serve-coop.py   on :8080 (build-wasm/)
 *   serve-assets.py on :9090 (RA CD1/)
 *
 * Budget: 55 s.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

async function canvasFillPct(page: any): Promise<number> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return 0;
    const ctx = canvas.getContext('2d');
    if (!ctx) return 0;
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
    }
    return Math.round((nonBlack / (data.length / 4)) * 100);
  });
}

test('T3 — RA WASM main menu renders', async ({ page }) => {
  test.setTimeout(60_000);

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T3] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 40_000 }
  );

  await page.waitForFunction(
    () => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null &&
             el.textContent.includes('Init_Bulk_Data done');
    },
    null,
    { timeout: 15_000 }
  );

  // Let the menu paint a few frames.
  await page.waitForTimeout(2_000);

  const fill = await canvasFillPct(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't3-ra-wasm-menu.png') });
  console.log(`[T3] canvas fill: ${fill}% | pageerrors: ${pageErrors.length}`);

  expect(pageErrors, 'no pageerror during boot').toHaveLength(0);
  expect(fill, 'main menu canvas fill ≥ 15 %').toBeGreaterThanOrEqual(15);
});
