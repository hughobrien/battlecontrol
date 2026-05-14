/**
 * TIM-595 — CI WASM smoke: verify ra.wasm loads without crash.
 *
 * Runs immediately after the emcc build step in gh-pages.yml to catch
 * binary-level regressions (TIM-593 class) before deploying to gh-pages.
 *
 * No game assets required. Requires serve-coop.py on :8080 serving build-wasm/.
 *
 * Gate: load ra.html and observe for 60 s. A broken binary (TIM-593 class:
 * null-function trap, WASM parse error) crashes within the first few seconds
 * and emits a pageerror. A clean binary produces no pageerror.
 *
 * The secondary "WASM ready" status check was removed (TIM-597): it caused
 * false failures on slow CI runners where JIT-compilation of the 12 MB -O2
 * binary takes longer than the observation window.
 */

import { test, expect } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const OBSERVE_MS = 60_000;

test('TIM-595 — CI WASM smoke: ra.wasm loads without crash', async ({ page }) => {
  test.setTimeout(120_000);

  if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  await page.goto('http://localhost:8080/ra.html?debug=1', { waitUntil: 'domcontentloaded' });

  // Observe for OBSERVE_MS. A crashing binary (null-function trap, WASM parse
  // error) throws a pageerror within the first few seconds. A clean binary
  // that just JIT-compiles slowly produces no pageerror.
  await page.waitForTimeout(OBSERVE_MS);

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim595-smoke-after-init.png') });
  const statusText = await page.locator('#status-line').textContent().catch(() => '(not found)') ?? '';
  console.log(`[TIM-595] status-line: "${statusText}" | errors: ${pageErrors.length}`);

  // Primary gate: no JavaScript / WASM crash during initialization.
  expect(
    pageErrors,
    `ra.wasm crashed during init: ${pageErrors.slice(0, 3).join('; ')}`
  ).toHaveLength(0);

  // Sanity gate: page at least started loading (not a 404 or serve failure).
  const loadedSomething =
    statusText !== '(not found)' && statusText !== 'Loading…';
  expect(
    loadedSomething,
    `ra.html status-line still shows "Loading…" after ${OBSERVE_MS / 1000}s — server may not be serving the WASM`
  ).toBe(true);
});
