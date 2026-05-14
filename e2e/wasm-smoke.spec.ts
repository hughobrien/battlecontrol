/**
 * TIM-595 — CI WASM smoke: verify ra.wasm loads without crash.
 *
 * Runs immediately after the emcc build step in gh-pages.yml to catch
 * binary-level regressions (TIM-593 class) before deploying to gh-pages.
 *
 * No game assets required. Requires serve-coop.py on :8080 serving build-wasm/.
 *
 * Gate: Emscripten runtime reaches onRuntimeInitialized ("WASM ready" status)
 * within 120 s with no pageerror. A broken binary crashes before this point
 * and emits a pageerror instead. 120 s is chosen because the -O2 link-time
 * WASM binary (~12 MB) takes longer to JIT-compile in CI headless Chromium
 * than the original -O3 binary did — see TIM-593.
 */

import { test, expect } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

test('TIM-595 — CI WASM smoke: ra.wasm loads without crash', async ({ page }) => {
  test.setTimeout(180_000);

  if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

  const pageErrors: string[] = [];

  // Capture the crash early so waitForFunction can exit fast.
  await page.addInitScript(() => {
    (window as any).__smokeError = false;
    window.addEventListener('error', () => { (window as any).__smokeError = true; });
  });
  page.on('pageerror', err => pageErrors.push(err.message));

  await page.goto('http://localhost:8080/ra.html?debug=1', { waitUntil: 'domcontentloaded' });

  // Wait for Emscripten runtime to fully initialize.
  //
  // Without ?src=, the preloader's Module.onRuntimeInitialized callback sets
  // #status-line to "WASM ready — pick your game folder to start."
  //
  // A broken binary (TIM-593: crash during thread-pool init or WASM parse)
  // will emit a pageerror and never reach this status, so __smokeError lets
  // waitForFunction exit quickly rather than waiting the full 120 s.
  await page.waitForFunction(
    () => {
      if ((window as any).__smokeError) return true;
      const el = document.getElementById('status-line');
      if (!el) return false;
      const t = el.textContent || '';
      return (
        t.includes('WASM ready') ||
        t.includes('pick your game folder') ||
        t.includes('Open Game Folder')  // preloader overlay visible = init done
      );
    },
    null,
    { timeout: 120_000 }
  );

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim595-smoke-after-init.png') });
  const statusText = await page.locator('#status-line').textContent() ?? '';
  console.log(`[TIM-595] status-line: "${statusText}"`);

  // Primary gate: no JavaScript / WASM crash during initialization.
  expect(
    pageErrors,
    `ra.wasm crashed during init: ${pageErrors.slice(0, 3).join('; ')}`
  ).toHaveLength(0);

  // Secondary gate: runtime reached the ready state (not just a silent hang).
  expect(statusText, 'Emscripten runtime did not reach ready state').toMatch(
    /WASM (ready|loaded)|pick your game folder|Open Game Folder/
  );
});
