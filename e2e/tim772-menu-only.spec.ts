/**
 * TIM-772 — Capture the main-menu canvas ONLY (no dialog) to compare
 * pixels at y=200..205 against the artefact in the difficulty selector.
 * If they match, the artefact is "menu pixels showing through a gap in
 * the dialog background shape coverage."
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const OUT_DIR   = path.join(__dirname, 'screenshots');

async function waitOut(page: any, s: string, t = 300_000) {
  await page.waitForFunction(
    (sub: string) => (document.getElementById('output')?.textContent ?? '').includes(sub),
    s, { timeout: t });
}

test('TIM-772 menu-only canvas', async ({ page }) => {
  test.setTimeout(700_000);
  await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`,
    { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => {
    const o = document.getElementById('preloader-overlay');
    return o !== null && o.style.display === 'none';
  }, null, { timeout: 120_000 });
  await waitOut(page, '[RA] Init_Game: Init_Bulk_Data done');

  const skipId = await page.evaluate(() => setInterval(() => {
    if ((window as any)._vqa_abort_installed) (window as any)._vqa_aborted = true;
  }, 100));
  await waitOut(page, '[TIM-616] menu_cs=');
  await page.evaluate((id) => clearInterval(id as any), skipId);
  await page.waitForTimeout(800);

  const b64 = await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    return c.toDataURL('image/png').split(',')[1];
  });
  fs.writeFileSync(path.join(OUT_DIR, 'tim772-menu-canvas.png'), Buffer.from(b64, 'base64'));
  console.log('[T772 menu] saved tim772-menu-canvas.png');
});
