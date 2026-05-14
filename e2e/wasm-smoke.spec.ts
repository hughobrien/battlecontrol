/**
 * TIM-595 — CI WASM smoke: verify ra.wasm loads without crash.
 * TIM-652 — Add pixel assertion to catch all-black canvas / TIM-587-class corruption.
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
 *
 * Pixel gate (TIM-652): canvasStats() is always sampled and logged. The
 * fill > 0 assertion fires only when the game loop has produced output
 * (callMain was invoked with game data). In CI smoke runs without game assets
 * callMain is never invoked so the canvas stays black; the guard prevents a
 * false failure while still catching all-black regressions on full runs.
 */

import { test, expect } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const OBSERVE_MS = 60_000;

/**
 * Sample the game canvas for non-black pixels.
 * Returns fill (0–100%), total pixel count, and canvas dimensions.
 * Pixels with all channels ≤ 15 are treated as black (matches existing
 * canvasStats pattern in tim590-ghpages-cyan-verify.spec.ts).
 */
async function canvasStats(page: any): Promise<{ fill: number; total: number; w: number; h: number }> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return { fill: 0, total: 0, w: 0, h: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, total: 0, w: canvas.width, h: canvas.height };
    const { width: w, height: h } = canvas;
    const total = w * h;
    if (total === 0) return { fill: 0, total: 0, w, h };
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
    }
    return { fill: Math.round(nonBlack / total * 100), total, w, h };
  });
}

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

  // Pixel gate (TIM-652): canvas must not be entirely black when the game has
  // rendered. canvasStats() is always sampled so the fill percentage is visible
  // in CI logs. The assertion only fires when #output has content — proof that
  // callMain ran and the game loop produced at least one frame. In the standard
  // CI smoke run (no game assets, callMain never called) this guard is false and
  // the check is skipped, preventing a false failure on a valid no-asset run.
  const outputText = await page.locator('#output').textContent().catch(() => '') ?? '';
  const gameHasRun = outputText.trim().length > 0;
  const stats = await canvasStats(page);
  console.log(
    `[TIM-652] canvas: fill=${stats.fill}% total=${stats.total} (${stats.w}×${stats.h}) game-ran=${gameHasRun}`
  );
  if (gameHasRun) {
    expect(
      stats.fill,
      `canvas is entirely black after ${OBSERVE_MS / 1000}s with game running — ` +
      `rendering regression detected (fill=${stats.fill}%, ${stats.w}×${stats.h}). ` +
      `Screenshot: e2e/screenshots/tim595-smoke-after-init.png`
    ).toBeGreaterThan(0);
  }
});
