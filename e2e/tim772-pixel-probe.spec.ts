/**
 * TIM-772 — Read the indexed framebuffer + palette at the difficulty
 * selector artefact rows to identify exactly what's been written.
 * Uses Module's exposed sample helper if available, otherwise dumps
 * canvas pixels.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const OUT_DIR   = path.join(__dirname, 'screenshots');

async function waitOut(page: any, s: string, timeoutMs = 300_000) {
  await page.waitForFunction(
    (sub: string) => (document.getElementById('output')?.textContent ?? '').includes(sub),
    s, { timeout: timeoutMs });
}

test('TIM-772 probe: dump indexed FB row at speckle band', async ({ page }) => {
  test.setTimeout(900_000);

  await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`,
    { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const o = document.getElementById('preloader-overlay');
    return o !== null && o.style.display === 'none';
  }, null, { timeout: 120_000 });
  await waitOut(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);

  const skipId = await page.evaluate(() => setInterval(() => {
    if ((window as any)._vqa_abort_installed) (window as any)._vqa_aborted = true;
  }, 100));
  await waitOut(page, '[TIM-616] menu_cs=', 120_000);
  await page.evaluate((id) => clearInterval(id as any), skipId);
  await page.waitForTimeout(500);

  await page.locator('#canvas').focus();
  await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
  await waitOut(page, '[DIFF] dialog ready', 30_000);
  await page.waitForTimeout(1500);

  // Read canvas pixel rows and palette via JS — use the existing canvas
  // (which is the ARGB output already palette-resolved).
  const probe = await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    const ctx = c.getContext('2d')!;
    const w = c.width, h = c.height;
    const img = ctx.getImageData(0, 0, w, h);
    const data = img.data;
    function row(y: number) {
      const out: [number, number, number][] = [];
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        out.push([data[i], data[i + 1], data[i + 2]]);
      }
      return out;
    }
    // Sample some specific rows.
    return {
      w, h,
      r195: row(195),
      r200: row(200),
      r202: row(202),
      r210: row(210),
      r222: row(222),
      r230: row(230),
    };
  });
  fs.writeFileSync(path.join(OUT_DIR, 'tim772-pixel-rows.json'), JSON.stringify(probe, null, 2));
  console.log('[T772 probe] wrote tim772-pixel-rows.json');
});
