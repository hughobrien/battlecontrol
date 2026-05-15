/**
 * T6 — TD WASM real-click GDI L1 mission start (TIM-755).
 *
 * Regression gate: verifies that a real Playwright mouse click on "Start New
 * Game" at canvas (321, 59) causes the game to load GDI Mission 1 (SCG01EA)
 * and reach frame 200 with canvas fill ≥20%.
 *
 * Flow:
 *   1. Load td.html via HTTP (COOP/COEP from serve-coop.py) — no ?autostart=1.
 *   2. Wait for #preloader-overlay to hide (MIX assets fetched from TD_ASSETS_URL).
 *   3. Wait for "[TD] Main_Menu: gadgets up" (gadget loop started).
 *   4. Poll until canvas has content (title screen rendered).
 *   5. page.locator('#canvas').click({position:{x:321,y:59}}) — "Start New Game".
 *   6. Wait for "[TD INIT] calling Start_Scenario" — Choose_Side() returns GDI
 *      immediately (INTRO.CPP WASM stub), so no GDI/NOD dialog appears.
 *   7. Wait for "[TD] Main_Loop frame 200" and assert canvas fill ≥20%.
 *
 * Skipped when TD_ASSETS_URL is not set (asset-dependent gate).
 *
 * Servers required:
 *   serve-coop.py on :8080 — WASM bundle (started by CI workflow).
 *   Assets come from TD_ASSETS_URL (CDN) or fallback to local :9091.
 *
 * Budget: 300 s — ~60s asset load + ~20s boot + ~20s to frame 200.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/td.html';
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

test('T6 — TD WASM "Start New Game" click → SCG01EA loads → frame 200 fill ≥20%', async ({ page }) => {
  test.setTimeout(300_000);

  if (!process.env['TD_ASSETS_URL']) {
    test.skip(true, 'T6 skipped — TD_ASSETS_URL not set');
    return;
  }

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T6] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── 1. Assets mounted ────────────────────────────────────────────────────────
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 }
  );
  console.log('[T6] preloader hidden — MIX assets mounted');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't6-td-wasm-01-preloader.png') });

  // ── 2. Main menu ready ───────────────────────────────────────────────────────
  await waitForOutput(page, '[TD] Main_Menu: gadgets up', 60_000);
  console.log('[T6] main menu gadgets up');

  let fillBefore = 0;
  await expect.poll(async () => {
    fillBefore = await canvasFillPct(page);
    return fillBefore;
  }, { timeout: 10_000, intervals: [200, 500, 1_000] }).toBeGreaterThan(0);

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't6-td-wasm-02-menu-up.png') });
  console.log(`[T6] canvas fill before click: ${fillBefore}%`);

  // ── 3. Click "Start New Game" ────────────────────────────────────────────────
  // SeenBuff coords = canvas coords (640×480 1:1). Button center X=321, Y=59.
  // After click, Choose_Side() returns immediately with GDI auto-selected.
  await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
  console.log('[T6] clicked Start New Game at (321, 59)');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't6-td-wasm-03-after-click.png') });

  // ── 4. Start_Scenario fires ─────────────────────────────────────────────────
  await waitForOutput(page, '[TD INIT] calling Start_Scenario', 60_000);
  console.log('[T6] Start_Scenario called — GDI L1 loading');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't6-td-wasm-04-start-scenario.png') });

  const outputAfterStart = await getOutput(page);
  expect(outputAfterStart).toContain('SCG01EA');
  expect(outputAfterStart).not.toContain('SIGSEGV');
  expect(outputAfterStart).not.toContain('Aborted(');

  // ── 5. Frame 200 ────────────────────────────────────────────────────────────
  await waitForOutput(page, '[TD] Main_Loop frame 200', 120_000);
  // Poll until canvas has non-black content — log fires before SDL present call.
  await expect.poll(() => canvasFillPct(page), { timeout: 5_000, intervals: [100, 200, 500] }).toBeGreaterThan(0);
  console.log('[T6] frame 200 reached');

  const fill200 = await canvasFillPct(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't6-td-wasm-05-frame-200.png') });
  console.log(`[T6] frame 200 fill: ${fill200}%`);

  const outputFinal = await getOutput(page);
  const noPageErrors = pageErrors.length === 0;

  console.log('\n[T6] ===== SUMMARY =====');
  console.log(`  Assets load:          PASS`);
  console.log(`  Main menu ready:      PASS`);
  console.log(`  Start New Game click: PASS`);
  console.log(`  Choose_Side GDI:      PASS (auto-selected)`);
  console.log(`  Start_Scenario OK:    PASS`);
  console.log(`  Frame 200 reached:    PASS`);
  console.log(`  Canvas fill@f200:     ${fill200}% (threshold ≥20%)`);
  console.log(`  No page errors:       ${noPageErrors ? 'PASS' : 'FAIL (' + pageErrors.length + ' errors)'}`);
  console.log('  Screenshots: t6-td-wasm-0[1-5].png');

  expect(outputFinal).toContain('[TD] Main_Loop frame 200');
  expect(outputFinal).not.toContain('SIGSEGV');
  expect(outputFinal).not.toContain('Aborted(');
  expect(pageErrors, 'no uncaught JS errors').toHaveLength(0);
  expect(fill200, 'canvas fill must be ≥20% at frame 200').toBeGreaterThanOrEqual(20);
});
