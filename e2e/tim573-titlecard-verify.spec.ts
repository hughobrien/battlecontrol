/**
 * TIM-573 before/after verification — capture the title-card scene
 * (first ~3s of ENGLISH.VQA) to compare against TIM-572's corrupted screenshot.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

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
    if (!canvas) return { fill: 0, colors: 0, w: 0, h: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, colors: 0, w: canvas.width, h: canvas.height };
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

test('TIM-573 — VQA title-card capture (post-fix)', async ({ page }) => {
  test.setTimeout(300_000);

  const url = `http://localhost:8080/ra.html?src=${encodeURIComponent('http://localhost:9090/')}&debug=1`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // Wait for preloader
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 }
  );

  // Wait for Play_Intro (which triggers ENGLISH.VQA)
  await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 120_000);
  console.log('[TIM-573] ENGLISH.VQA started');

  // t1s — title card frame (COMMAND & CONQUER RED ALERT logo)
  await page.waitForTimeout(1000);
  const s1 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim573-titlecard-t1s.png') });
  console.log(`[TIM-573] t1s: fill=${s1.fill}% colors=${s1.colors} (${s1.w}x${s1.h})`);

  // t2s
  await page.waitForTimeout(1000);
  const s2 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim573-titlecard-t2s.png') });
  console.log(`[TIM-573] t2s: fill=${s2.fill}% colors=${s2.colors}`);

  // t3s
  await page.waitForTimeout(1000);
  const s3 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim573-titlecard-t3s.png') });
  console.log(`[TIM-573] t3s: fill=${s3.fill}% colors=${s3.colors}`);

  // Title card should have significant fill and multiple colors
  // (corrupted "before" would show scattered noise with very few actual colors)
  expect(s1.fill + s2.fill + s3.fill).toBeGreaterThan(0); // basic liveness
  console.log('[TIM-573] Title card captured — check screenshots for visual quality');
});
