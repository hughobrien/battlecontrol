import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html?debug=1&autostart=1&scene=SCG02EA.INI';
const OBSERVE_MS      = 30_000;
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

test('T11 — RA WASM M2 boot (Allied M2, first frame)', async ({ page }) => {
  test.setTimeout(60_000);

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  await page.goto(WASM_URL, { waitUntil: 'domcontentloaded' });

  await page.waitForTimeout(OBSERVE_MS);

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't11-ra-wasm-m2-boot.png') });
  const statusText = await page.locator('#status-line').textContent().catch(() => '(not found)') ?? '';
  console.log(`[T11] status-line: "${statusText}" | pageerrors: ${pageErrors.length}`);

  expect(
    pageErrors,
    `ra.wasm (M2) crashed during init: ${pageErrors.slice(0, 3).join('; ')}`
  ).toHaveLength(0);

  const loadedSomething = statusText !== '(not found)' && statusText !== 'Loading…';
  expect(
    loadedSomething,
    `ra.html (M2) status-line still shows "Loading…" after ${OBSERVE_MS / 1000}s`
  ).toBe(true);
});
