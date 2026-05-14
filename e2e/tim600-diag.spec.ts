/**
 * TIM-600 quick diagnostic — dumps #output every 20 s for 5 min so we can
 * see exactly where boot stalls when ENGLISH.VQA never prints its "Playing"
 * line within the previous 4-minute window.
 */

import { test } from '@playwright/test';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const SHOTS     = path.join(__dirname, 'screenshots');

test('TIM-600 boot diagnostic', async ({ page }) => {
  test.setTimeout(360_000);

  const consoleLogs: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => consoleLogs.push(`[pageerror] ${err.message}`));

  await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`,
                  { waitUntil: 'domcontentloaded' });

  for (let i = 0; i < 60; i++) {
    await page.waitForTimeout(2_000);
    // Save a screenshot every snapshot so passing runs leave visual evidence.
    await page.screenshot({
      path: `${SHOTS}/tim600-diag-snapshot-${String(i + 1).padStart(2, '0')}.png`,
    });
    const text = await page.evaluate(() => {
      const el = document.getElementById('output');
      return el ? (el.textContent || '').slice(-2000) : '';
    });
    console.log(`\n──── snapshot @ ${(i + 1) * 2}s — last 2KB of #output ────`);
    console.log(text || '(empty)');
    const status = await page.evaluate(() => {
      const el = document.getElementById('status-line');
      return el ? el.textContent || '' : '';
    });
    console.log(`status: ${status}`);
    if (text.includes("[VQA] 'ENGLISH.VQA' done")) {
      console.log('ENGLISH.VQA complete — done.');
      break;
    }
  }
  console.log('\n──── recent console / pageerror ────');
  consoleLogs.slice(-40).forEach(l => console.log(l));
});
