/**
 * TIM-772 — Diagnose RA WASM difficulty-selector artefact. Captures the
 * dialog at t=0/+500/+1500ms after [DIFF] dialog ready to determine if the
 * speckle band is animating (smear) or static (one-shot render bug).
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

async function dumpCanvas(page: any, name: string) {
  const b64 = await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    return c.toDataURL('image/png').split(',')[1];
  });
  fs.writeFileSync(path.join(OUT_DIR, name), Buffer.from(b64, 'base64'));
}

test('TIM-772 diag: difficulty selector frames', async ({ page }) => {
  test.setTimeout(900_000);
  page.on('console', m => console.log(`[console.${m.type()}] ${m.text()}`));

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

  // Capture at t=0, t=500ms, t=1500ms.
  await page.waitForTimeout(50);
  await dumpCanvas(page, 'tim772-diff-t0050.png');
  await page.waitForTimeout(450);
  await dumpCanvas(page, 'tim772-diff-t0500.png');
  await page.waitForTimeout(1000);
  await dumpCanvas(page, 'tim772-diff-t1500.png');
  await page.waitForTimeout(2000);
  await dumpCanvas(page, 'tim772-diff-t3500.png');

  // Move mouse over the dialog to see if hover causes speckle change.
  await page.mouse.move(320, 240);
  await page.waitForTimeout(400);
  await dumpCanvas(page, 'tim772-diff-mouse-hover.png');

  console.log('[T772 diag] frames captured');
});
