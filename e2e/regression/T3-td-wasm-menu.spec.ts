/**
 * T3 — TD WASM main menu navigation (TIM-696).
 *
 * Regression gate for the TD WASM menu input pipeline.
 * Verifies that real Playwright mouse clicks reach the game's input processing
 * and trigger menu button actions (catches the TIM-664/TIM-684 class of bug in TD).
 *
 * Flow:
 *   1. Load td.html via HTTP asset server — no ?autostart=1, exercises real menu path.
 *   2. Wait for #preloader-overlay to hide (MIX assets mounted).
 *   3. Wait for "[TD] Main_Menu: gadgets up" (MENUS.CPP loop start — TIM-696 probe).
 *   4. Sample canvas pixels before click.
 *   5. page.locator('#canvas').click({position:{x:321,y:59}}) — "Start New Game".
 *   6. Assert canvas changes (pixelDiff > 0) — proves click reached button processing.
 *
 * Menu "ready" signal: "[TD] Main_Menu: gadgets up" logged from TIBERIANDAWN/MENUS.CPP
 * just before the main gadget loop starts — only fires once per menu entry.
 *
 * Button layout (canvas 640×480, NEWMENU, no expansions, ystep=30):
 *   SeenBuff coordinates = canvas coordinates (both 640×480, direct 1:1 mapping).
 *   Dialog box: D_DIALOG_X=170, D_DIALOG_W=304 → center X = 170 + 152 = 322
 *   Button X: D_START_X=196, D_START_W=250 → center X = 196 + 125 = 321
 *   Button H: D_START_H=18 → center offset = 9
 *
 *   starty=50 (25*2), ystep=30 (15*2), no expansions:
 *     Start New Game : canvas (321,  59)  ← regression-click target
 *     Internet/DDE   : canvas (321,  89)  (not accessible in WASM build)
 *     Load Mission   : canvas (321, 119)
 *     Multiplayer    : canvas (321, 149)
 *     Intro          : canvas (321, 179)
 *     Exit Game      : canvas (319, 209)  (D_EXIT_X=256, D_EXIT_W=126 → center 319)
 *
 *   Note: the SDL present pump reads from HidPage (TIM-453). The buttons are drawn
 *   to SeenBuff. The canvas may not show button text visually, but the input
 *   processing uses SeenBuff coordinates which map 1:1 to canvas coordinates.
 *
 * Servers required (started externally before this spec):
 *   serve-coop.py   on :8080 (build-wasm/ — COOP/COEP headers for SAB/pthreads)
 *   serve-assets.py on :9091 (TD CD1/ — CCLOCAL.MIX, CONQUER.MIX, GENERAL.MIX, ...)
 *
 * Budget: 120 s (init ~60 s + menu settle + click response).
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/td.html';
// TD_ASSETS_URL env var lets CI pass a CDN URL directly; local runs use :9091.
const ASSET_URL       = process.env['TD_ASSETS_URL'] || 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

async function waitForOutput(page: any, substring: string, timeoutMs: number) {
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

/** Sample every 4th pixel (RGB only) from the full canvas for a fast diff. */
async function sampleCanvas(page: any): Promise<number[]> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return [];
    const ctx = canvas.getContext('2d');
    if (!ctx) return [];
    const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const out: number[] = [];
    for (let i = 0; i < d.length; i += 16) {
      out.push(d[i], d[i + 1], d[i + 2]);
    }
    return out;
  });
}

/** Count pixels where any channel differs by more than threshold. */
function pixelDiff(a: number[], b: number[]): number {
  let diff = 0;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i += 3) {
    if (Math.abs(a[i]   - b[i])   > 8 ||
        Math.abs(a[i+1] - b[i+1]) > 8 ||
        Math.abs(a[i+2] - b[i+2]) > 8) diff++;
  }
  return diff;
}

/** Return canvas fill percentage (non-black pixels). */
async function canvasFillPct(page: any): Promise<number> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return 0;
    const ctx = canvas.getContext('2d');
    if (!ctx) return 0;
    const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    let nb = 0;
    for (let i = 0; i < d.length; i += 4) {
      if (d[i] > 15 || d[i + 1] > 15 || d[i + 2] > 15) nb++;
    }
    return Math.round((nb / (d.length / 4)) * 100);
  });
}

test('T3 — TD WASM main menu "Start New Game" click triggers canvas change', async ({ page }) => {
  test.setTimeout(120_000);

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T3] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── 1. Assets mounted (preloader overlay hides) ───────────────────────────
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 60_000 }
  );
  console.log('[T3] preloader hidden — MIX assets mounted');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't3-td-wasm-menu-01-preloader.png') });

  // ── 2. Menu loop started ───────────────────────────────────────────────────
  // "[TD] Main_Menu: gadgets up" is logged from TIBERIANDAWN/MENUS.CPP (TIM-696)
  // just before the GadgetClass input loop begins.  Only fires after Init_Game
  // completes, assets are loaded, and the title screen is rendered.
  await waitForOutput(page, '[TD] Main_Menu: gadgets up', 60_000);
  console.log('[T3] main menu loop started');

  // Poll until the title screen has rendered at least some pixels.
  // Canvas pixel state is not DOM-observable — expect.poll on getImageData is the
  // right primitive here; it replaces a fixed waitForTimeout settle.
  let fillBefore = 0;
  await expect.poll(async () => {
    fillBefore = await canvasFillPct(page);
    return fillBefore;
  }, { timeout: 10_000, intervals: [200, 500, 1_000] }).toBeGreaterThan(0);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't3-td-wasm-menu-02-menu-up.png') });
  console.log(`[T3] canvas fill before click: ${fillBefore}%`);

  // ── 3. Pre-click sample ────────────────────────────────────────────────────
  const before = await sampleCanvas(page);

  // ── 4. Real mouse click — "Start New Game" at (321, 59) ───────────────────
  // SeenBuff coordinates match canvas coordinates (both 640×480, 1:1 mapping).
  // D_START_X=196, D_START_W=250 → center X=321; starty=50, H=18 → center Y=59.
  // No synthetic injection; exercises the TIM-664-class input pipeline in TD.
  await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
  console.log('[T3] clicked Start New Game at (321, 59)');

  // ── 5. Poll for canvas change (up to 10 s) ────────────────────────────────
  // Canvas pixel state is not DOM-observable — poll via getImageData until at
  // least one pixel channel changes from the pre-click sample.
  let afterSample: number[] = [];
  await expect.poll(async () => {
    afterSample = await sampleCanvas(page);
    return pixelDiff(before, afterSample);
  }, { timeout: 10_000, intervals: [500, 1_000, 2_000] }).toBeGreaterThan(0);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't3-td-wasm-menu-03-after-click.png') });

  // ── 6. Post-click assertions ──────────────────────────────────────────────
  const diff = pixelDiff(before, afterSample);
  const output = await getOutput(page);
  console.log(`[T3] pixel diff after click: ${diff} pixels changed`);

  const noPageErrors = pageErrors.length === 0;
  const noCrash = !output.includes('SIGSEGV') && !output.includes('Aborted(');

  console.log('\n[T3] ===== SUMMARY =====');
  console.log(`  Assets loaded:          PASS`);
  console.log(`  Main menu gadgets up:   PASS`);
  console.log(`  Canvas fill pre-click:  ${fillBefore}% (title screen)`);
  console.log(`  Click method:           real Playwright locator.click (no synthetic injection)`);
  console.log(`  Pixel diff post-click:  ${diff} (must be > 0)`);
  console.log(`  No crash:               ${noCrash ? 'PASS' : 'FAIL'}`);
  console.log(`  No page errors:         ${noPageErrors ? 'PASS' : 'FAIL'}`);
  console.log('  Screenshots:            t3-td-wasm-menu-0[1-3].png');

  expect(pageErrors, 'no pageerror during boot or click').toHaveLength(0);
  expect(noCrash, 'no SIGSEGV or Abort during test').toBe(true);
  expect(fillBefore, 'title screen canvas fill ≥ 5 %').toBeGreaterThanOrEqual(5);
  // Primary regression gate: canvas must change after a real mouse click.
  // If the TIM-664 class bug exists in TD (WWKEY_VK_BIT on mouse button code),
  // GadgetClass::Input() never matches KN_LMOUSE and diff will be 0.
  expect(diff, 'canvas must change after Start New Game click').toBeGreaterThan(0);
});
