/**
 * T4 — RA WASM VQA playback regression (TIM-623).
 *
 * With-assets regression: boot RA WASM, wait for ENGLISH.VQA to start
 * playing, sample the canvas at t = 3 s, and assert the frame is
 * substantive (≥ 25 % fill), free of cyan-block scatter (TIM-590), and
 * the letterbox is solid black (TIM-613 codebook fill regression).
 *
 * This is a tripwire, not a full-playback audit. The full audit lives
 * in `e2e/tim600-english-vqa-verify.spec.ts`.
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

async function vqaStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return { fill: 0, cyanCount: 0, topBand: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, cyanCount: 0, topBand: 0 };
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0, cyan = 0;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      if (r < 32 && g > 180 && b > 180) cyan++;
    }
    const fill = Math.round((nonBlack / (data.length / 4)) * 100);
    // Top letterbox band (y < 40) must be solid black.
    let topNonBlack = 0;
    const topData = ctx.getImageData(0, 0, w, 40).data;
    for (let i = 0; i < topData.length; i += 4) {
      if (topData[i] > 15 || topData[i + 1] > 15 || topData[i + 2] > 15) topNonBlack++;
    }
    const topBand = Math.round((topNonBlack / (topData.length / 4)) * 100);
    return { fill, cyanCount: cyan, topBand };
  });
}

test('T4 — RA WASM VQA playback (ENGLISH.VQA t=3 s)', async ({ page }) => {
  test.setTimeout(60_000);

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T4] loading ${url}`);
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
             el.textContent.includes("[VQA] Playing 'ENGLISH.VQA'");
    },
    null,
    { timeout: 15_000 }
  );

  // Sample once at t = 3 s into playback.
  await page.waitForTimeout(3_000);
  const s = await vqaStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't4-ra-wasm-vqa-t3s.png') });
  console.log(`[T4] t=3s | fill=${s.fill}% cyan=${s.cyanCount}px topBand=${s.topBand}% pageerrors=${pageErrors.length}`);

  expect(pageErrors, 'no pageerror during VQA').toHaveLength(0);
  expect(s.cyanCount, 'no cyan-block scatter (TIM-590)').toBe(0);
  expect(s.topBand, 'top letterbox solid black (TIM-613)').toBe(0);
  expect(s.fill, 'VQA frame fill ≥ 25 %').toBeGreaterThanOrEqual(25);
});
