/**
 * T5 — RA WASM menu-click regression (TIM-683).
 *
 * Regression gate for TIM-683: verifies that real SDL mouse events are pumped
 * in Main_Menu and correctly reach the gadget input pipeline.
 *
 * Root cause of TIM-683: SDL event pump was not called inside the Main_Menu
 * loop, causing real mouse clicks to be silently dropped while the menu
 * appeared frozen.
 *
 * This spec confirms the fix applies in the WASM build:
 *   1. Load ra.html without ?autostart=1 (no synthetic injection).
 *   2. Skip intro VQAs via window._vqa_aborted interval.
 *   3. Wait for Init_Bulk_Data done + [TIM-616] menu_cs= (menu gadgets live).
 *   4. Sample canvas pixels before the click.
 *   5. page.locator('#canvas').click({position:{x:322,y:183}}) — "New Campaign".
 *   6. Assert canvas changes (pixelDiff > 0) — click was processed.
 *
 * Button positions (640×480, ENGLISH build, no expansion packs):
 *   New Campaign  → (322, 183)
 *   Load Game     → (322, 211)
 *   Multiplayer   → (322, 239)
 *   Introduction  → (322, 267)
 *   Exit          → (322, 295)
 *
 * Servers required (started by scripts/regression-suite.sh in full tier):
 *   serve-coop.py   on :8080 — WASM bundle from build-wasm/
 *   serve-assets.py on :9090 — RA MIX files from CD1/
 *
 * Budget: 420 s (7 min: 4 min init + 2 min VQA skip + 1 min settle).
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

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
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent || '' : '';
  });
}

/** Sample RGB pixels from the full canvas; returns a flat number[]. */
async function sampleCanvas(page: any): Promise<number[]> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return [];
    const ctx = canvas.getContext('2d');
    if (!ctx) return [];
    const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const out: number[] = [];
    // Sample every 4th pixel (stride 16 bytes) for speed.
    for (let i = 0; i < d.length; i += 16) {
      out.push(d[i], d[i + 1], d[i + 2]);
    }
    return out;
  });
}

/** Count pixels where any channel differs by more than a threshold. */
function pixelDiff(a: number[], b: number[]): number {
  let diff = 0;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i += 3) {
    if (Math.abs(a[i]   - b[i])   > 8 ||
        Math.abs(a[i+1] - b[i+1]) > 8 ||
        Math.abs(a[i+2] - b[i+2]) > 8) {
      diff++;
    }
  }
  return diff;
}

/**
 * Poll window._vqa_aborted=true every 100 ms whenever the VQA abort
 * infrastructure is active.  Causes both ENGLISH.VQA and PROLOG.VQA to skip
 * on their first abort-poll cycle.  Returns a cancel function.
 */
async function installVqaAutoSkip(page: any): Promise<() => Promise<void>> {
  await page.evaluate(() => {
    (window as any).__vqa_skip_interval = setInterval(() => {
      if ((window as any)._vqa_abort_installed) {
        (window as any)._vqa_aborted = true;
      }
    }, 100);
  });
  return async () => {
    await page.evaluate(() => clearInterval((window as any).__vqa_skip_interval));
  };
}

test('T5 — RA WASM menu-click: New Campaign triggers canvas change (TIM-683 gate)', async ({ page }) => {
  test.setTimeout(420_000);

  const consoleLogs: string[] = [];
  page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T5] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Preloader hides ───────────────────────────────────────────────────────
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 }
  );
  console.log('[T5] preloader hidden');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't5-01-preloader-hidden.png') });

  // ── Init_Bulk_Data done ───────────────────────────────────────────────────
  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
  console.log('[T5] Init_Bulk_Data done');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't5-02-init-done.png') });

  // ── VQA auto-skip ─────────────────────────────────────────────────────────
  const cancelVqaSkip = await installVqaAutoSkip(page);
  console.log('[T5] VQA auto-skip installed');

  // ── Main menu up ──────────────────────────────────────────────────────────
  // [TIM-616] menu_cs= fires once the button gadgets are live — earliest safe
  // point for real mouse clicks.
  await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
  await cancelVqaSkip();
  console.log('[T5] main menu up — VQA skip cancelled');

  // One tick for the menu to stabilise before sampling.
  await page.waitForTimeout(1_000);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't5-03-menu-ready.png') });

  const before = await sampleCanvas(page);
  console.log(`[T5] pre-click sample: ${before.length / 3} pixels`);

  // ── Real mouse click — "New Campaign" at (322, 183) ──────────────────────
  // Uses Playwright locator.click() — real browser mouse event; no synthetic
  // LCLICK injection.  This is the TIM-683 regression gate: before the fix,
  // SDL events were not pumped inside Main_Menu so the click was dropped and
  // the canvas never changed.
  await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
  console.log('[T5] clicked New Campaign at (322, 183)');

  // ── Wait for canvas response ──────────────────────────────────────────────
  await page.waitForTimeout(5_000);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't5-04-after-click.png') });

  const after  = await sampleCanvas(page);
  const diff   = pixelDiff(before, after);
  const output = await getOutput(page);
  const pageErrors = consoleLogs.filter(l => l.startsWith('[pageerror]'));

  console.log('\n[T5] ===== SUMMARY =====');
  console.log(`  Preloader hidden:   PASS`);
  console.log(`  Init_Bulk_Data:     PASS`);
  console.log(`  VQA skip:           PASS`);
  console.log(`  Main menu up:       PASS`);
  console.log(`  Click method:       real Playwright locator.click() — no synthetic injection`);
  console.log(`  Pixel diff:         ${diff} (must be > 0 — TIM-683 gate)`);
  console.log(`  No crash:           ${!output.includes('SIGSEGV') && !output.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
  console.log(`  No page errors:     ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);
  console.log('  Screenshots:        t5-01..04');

  expect(output, 'no SIGSEGV').not.toContain('SIGSEGV');
  expect(output, 'no Aborted').not.toContain('Aborted(');
  expect(pageErrors.length, 'no page errors').toBe(0);
  // Primary TIM-683 regression gate: the canvas must change after a real click.
  // Pre-fix this always returned 0 because the SDL pump was missing in Main_Menu.
  expect(diff, 'canvas must change after real New Campaign click (TIM-683 regression gate)').toBeGreaterThan(0);
});
