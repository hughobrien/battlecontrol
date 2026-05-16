/**
 * TIM-772 — Capture the RA WASM difficulty-selector screen for visual
 * artefact analysis. Reuses the navigation pattern from tim697 (boot →
 * menu → click New Campaign → wait [DIFF] dialog ready), but stops there
 * and writes a high-quality screenshot.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const OUT_DIR   = path.join(__dirname, 'screenshots');

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });

async function waitForOutput(page: any, substring: string, timeoutMs = 300_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,
    { timeout: timeoutMs }
  );
}

async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => (document.getElementById('output')?.textContent ?? ''));
}

test('TIM-772 capture: WASM difficulty selector', async ({ page }) => {
  test.setTimeout(900_000);

  const logs: string[] = [];
  page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));

  await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, {
    waitUntil: 'domcontentloaded',
  });

  // Boot: wait for preloader to hide and Init_Game to complete.
  await page.waitForFunction(
    () => {
      const o = document.getElementById('preloader-overlay');
      return o !== null && o.style.display === 'none';
    },
    null,
    { timeout: 120_000 }
  );
  console.log('[T772] preloader hidden');

  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
  console.log('[T772] Init_Bulk_Data done');

  // Skip ENGLISH/PROLOG VQAs.
  const skipInterval = await page.evaluate(() => {
    return setInterval(() => {
      if ((window as any)._vqa_abort_installed) {
        (window as any)._vqa_aborted = true;
      }
    }, 100);
  });

  // Wait for main menu.
  await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
  await page.evaluate((id) => clearInterval(id as any), skipInterval);
  console.log('[T772] main menu up');
  await page.waitForTimeout(500);

  await page.screenshot({ path: path.join(OUT_DIR, 'tim772-menu.png'), fullPage: false });

  // Click New Campaign.
  await page.locator('#canvas').focus();
  await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
  console.log('[T772] clicked New Campaign at (322, 183)');

  await waitForOutput(page, '[DIFF] dialog ready', 30_000);
  console.log('[T772] DIFF dialog ready logged');

  // Settle: 1.5 s for the dialog to fully paint.
  await page.waitForTimeout(1500);

  // Capture the canvas as a high-quality PNG (not full-page DOM screenshot,
  // because we want pixel-exact game output, not the page chrome).
  const canvasPngBase64 = await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!c) return null;
    return c.toDataURL('image/png').split(',')[1];
  });
  expect(canvasPngBase64, 'canvas.toDataURL returned null').not.toBeNull();
  fs.writeFileSync(
    path.join(OUT_DIR, 'tim772-difficulty-wasm.png'),
    Buffer.from(canvasPngBase64 as string, 'base64'),
  );
  console.log(`[T772] wrote tim772-difficulty-wasm.png`);

  // Also page screenshot for full context.
  await page.screenshot({ path: path.join(OUT_DIR, 'tim772-difficulty-page.png'), fullPage: false });

  // TIM-772 CI gate: the original artefact was a wide horizontal cyan +
  // green + yellow band at the DD-BKGND.SHP seam (canvas y = dialog_y +
  // h/2). Difficulty dialog sits at (x=70, y=120, w=500, h=160), so the
  // seam rows are y=200..205. Count cyan-ish pixels in those rows, away
  // from the left/right edge ornaments. The fix in DIALOG.CPP overdraws
  // this band with the dominant body colour. Pre-fix the count was ~300+;
  // post-fix it should be near zero (a few label glyph pixels at most).
  const seamCyan = await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    const ctx = c.getContext('2d')!;
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let cyanish = 0;
    // Sample only the artefact rows in the dialog interior, skipping
    // ornament/edge zones at x<102 and x>538.
    for (let y = 200; y <= 205; y++) {
      for (let x = 102; x <= 538; x++) {
        const i = (y * c.width + x) * 4;
        const r = d[i], g = d[i + 1], b = d[i + 2];
        // Cyan/green band signature: low red, mid green, mid-high blue.
        // Body red is (80,8,0) and (48,8,0); labels are cream/yellow/black.
        if (r < 100 && g > 60 && b > 60) cyanish++;
      }
    }
    return cyanish;
  });
  console.log(`[T772] seam-band cyan-ish pixel count: ${seamCyan}`);

  // Pre-fix: ~300+ cyan/green pixels at the seam. Post-fix: should be <50.
  expect(seamCyan, 'no cyan/green seam-band artefact in dialog body').toBeLessThan(50);

  const out = await getOutput(page);
  // Dump all TIM-772 log lines so we can see Dialog_Box probe output.
  const t772 = out.split('\n').filter(l => l.includes('TIM-772'));
  console.log(`[T772] TIM-772 probe lines: count=${t772.length}`);
  t772.forEach(l => console.log('  ' + l));
  // Also dump the last 30 lines of output for context.
  const tail = out.split('\n').slice(-30);
  console.log('[T772] output tail (last 30 lines):');
  tail.forEach(l => console.log('  > ' + l));
  expect(out, 'no SIGSEGV').not.toContain('SIGSEGV');
  expect(out, 'no Aborted').not.toContain('Aborted(');
});
