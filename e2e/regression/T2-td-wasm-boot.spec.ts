/**
 * T2 — TD WASM boot smoke (TIM-623).
 *
 * Asset-free regression: load td.html, observe for 30 s, assert that
 * Emscripten runtime initializes without a pageerror. Catches TD-only
 * WASM build regressions (TIM-343 / TIM-447 / TIM-453 class).
 *
 * Servers required (started by scripts/regression-suite.sh):
 *   serve-coop.py on :8080 (build-wasm/)
 *
 * Budget: 45 s.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/td.html?debug=1';
const OBSERVE_MS      = 30_000;
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

test('T2 — TD WASM boots without crash', async ({ page }) => {
  test.setTimeout(60_000);

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  await page.goto(WASM_URL, { waitUntil: 'domcontentloaded' });

  await page.waitForTimeout(OBSERVE_MS);

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't2-td-wasm-boot.png') });
  const statusText = await page.locator('#status-line').textContent().catch(() => '(not found)') ?? '';
  console.log(`[T2] status-line: "${statusText}" | pageerrors: ${pageErrors.length}`);

  expect(
    pageErrors,
    `td.wasm crashed during init: ${pageErrors.slice(0, 3).join('; ')}`
  ).toHaveLength(0);

  const loadedSomething = statusText !== '(not found)' && statusText !== 'Loading…';
  expect(
    loadedSomething,
    `td.html status-line still shows "Loading…" after ${OBSERVE_MS / 1000}s — server may not be serving the WASM`
  ).toBe(true);
});
