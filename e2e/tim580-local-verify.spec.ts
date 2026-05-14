/**
 * TIM-580 — Local WASM VQA verification (post palette-fix).
 *
 * Captures frame 20 + t=2s + t=5s of ENGLISH.VQA from the local WASM build
 * and writes them as e2e/screenshots/tim580-local-vqa-*.png so we can
 * compare side-by-side with TIM-579's ghpages baselines.
 *
 * Requires: serve-coop.py on :8080 and an asset server on :9090.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const ASSET_URL = 'http://localhost:9090/';

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

async function canvasStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return { fill: 0, colors: 0, w: 0, h: 0 };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h };
  });
}

test('TIM-580 — local WASM VQA palette fix verification', async ({ page }) => {
  test.setTimeout(420_000);
  const consoleLines: string[] = [];
  page.on('console', (msg: any) => consoleLines.push(`[console:${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => consoleLines.push(`[pageerror] ${err.message}`));
  const url = `http://localhost:8080/ra.html?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[TIM-580] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[TIM-580] preloader hidden');
  await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 180_000);
  console.log('[TIM-580] Play_Intro fired');
  await page.waitForTimeout(1333);
  const sFrame20 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim580-local-vqa-frame20.png') });
  console.log(`[TIM-580] frame 20: fill=${sFrame20.fill}% colors=${sFrame20.colors}`);
  await page.waitForTimeout(666);
  const sT2 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim580-local-vqa-t2s.png') });
  console.log(`[TIM-580] t2s: fill=${sT2.fill}% colors=${sT2.colors}`);
  await page.waitForTimeout(3000);
  const sT5 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim580-local-vqa-t5s.png') });
  console.log(`[TIM-580] t5s: fill=${sT5.fill}% colors=${sT5.colors}`);
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim580-local-output.log'),
    `=== console ===\n${consoleLines.join('\n')}\n`
  );
  // Frame 20: metallic-gray title background should have fill >25% (the gold title
  // alone is ~10-15%, so 25%+ proves background is rendering correctly).
  expect(sFrame20.fill).toBeGreaterThan(25);
  expect(sFrame20.colors).toBeGreaterThan(10);
});
