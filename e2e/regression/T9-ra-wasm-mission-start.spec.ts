/**
 * T9 — RA WASM real-click Allied L1 mission start (TIM-773).
 *
 * Regression gate: verifies that a real Playwright mouse click on "New Campaign"
 * at canvas (322, 183) navigates through the difficulty/faction dialogs (via
 * existing KN_RETURN auto-injections in SPECIAL.CPP / INIT.CPP) and starts
 * Allied Mission 1 (SCG01EA), reaching frame 100 with canvas fill ≥5%.
 *
 * Flow:
 *   1. Load ra.html via HTTP (COOP/COEP from serve-coop.py) — no ?autostart=1.
 *   2. Wait for #preloader-overlay to hide (MIX assets fetched from RA_ASSETS_URL).
 *   3. Wait for "[RA] Init_Game: Init_Bulk_Data done" (binary running, assets loaded).
 *   4. Install VQA auto-skip — aborts ENGLISH.VQA and PROLOG.VQA quickly.
 *   5. Wait for "[TIM-616] menu_cs=" — menu gadgets live, safe for real clicks.
 *   6. Cancel VQA auto-skip.
 *   7. page.locator('#canvas').click({position:{x:322,y:183}}) — "New Campaign".
 *   8. Wait for "[DIFF] injecting KN_RETURN" (difficulty auto-accepted).
 *   9. Wait for "[INIT] injecting KN_RETURN" (Allies faction auto-selected).
 *  10. Wait for "[RA] Select_Game: Start_Scenario OK" — SCG01EA mission started.
 *  11. Wait for "[RA] Main_Loop frame 100" and assert canvas fill ≥5%.
 *
 * Button positions (640×480, ENGLISH build, no expansion packs):
 *   New Campaign  → (322, 183)
 *   Load Game     → (322, 211)
 *
 * Skipped when RA_ASSETS_URL is not set (asset-dependent gate).
 *
 * Servers required:
 *   serve-coop.py on :8080 — WASM bundle (started by CI workflow).
 *   Assets come from RA_ASSETS_URL (CDN) or fallback to local :9090.
 *
 * Budget: 600 s — ~120 s preloader + ~30 s init + ~10 s VQA skip +
 *   ~10 s menu + ~10 s Start_Scenario + ~120 s to frame 100 + buffer.
 *
 * Analogous to:
 *   e2e/regression/T6-td-wasm-mission-start.spec.ts — TD mission start CI gate
 *   e2e/tim672-ra-click-mission-start.spec.ts       — full RA click audit spec
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
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

/**
 * Poll window._vqa_aborted=true every 100 ms when the VQA abort
 * infrastructure is active.  Aborts both ENGLISH.VQA and PROLOG.VQA on
 * their first abort-poll cycle, allowing the main menu to come up quickly.
 * Returns a cancel function; call it once "[TIM-616] menu_cs=" is seen.
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

test('T9 — RA WASM "New Campaign" click → SCG01EA loads → frame 100 fill ≥5%', async ({ page }) => {
  test.setTimeout(600_000);

  if (!process.env['RA_ASSETS_URL']) {
    test.skip(true, 'T9 skipped — RA_ASSETS_URL not set');
    return;
  }

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T9] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── 1. Assets mounted ────────────────────────────────────────────────────
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[T9] preloader hidden — MIX assets mounted');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-01-preloader.png') });

  // ── 2. Init_Bulk_Data done ───────────────────────────────────────────────
  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 120_000);
  console.log('[T9] Init_Bulk_Data done');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-02-init-done.png') });

  // ── 3. VQA auto-skip ─────────────────────────────────────────────────────
  const cancelVqaSkip = await installVqaAutoSkip(page);
  console.log('[T9] VQA auto-skip installed — ENGLISH.VQA and PROLOG.VQA will abort quickly');

  // ── 4. Main menu ready ───────────────────────────────────────────────────
  // [TIM-616] menu_cs= fires when Select_Game enters the main menu loop
  // with gadgets live — earliest safe point for real mouse clicks.
  await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
  await cancelVqaSkip();
  console.log('[T9] main menu gadgets up — VQA skip cancelled');

  // One tick for the menu to stabilise before sampling / clicking.
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-03-menu-ready.png') });

  // ── 5. Click "New Campaign" at (322, 183) ────────────────────────────────
  // Button layout confirmed by TIM-649 / TIM-665 (ENGLISH build, 640×480).
  // Choose_Side() auto-selects Allies via the KN_RETURN injection in INIT.CPP.
  await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
  console.log('[T9] clicked New Campaign at (322, 183)');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-04-after-click.png') });

  // ── 6. Difficulty auto-accepted ─────────────────────────────────────────
  await waitForOutput(page, '[DIFF] injecting KN_RETURN', 30_000);
  console.log('[T9] difficulty auto-accepted (KN_RETURN injection)');

  // ── 7. Faction auto-selected ─────────────────────────────────────────────
  await waitForOutput(page, '[INIT] injecting KN_RETURN', 30_000);
  console.log('[T9] faction auto-selected → Allies');

  // ── 8. Start_Scenario fires ─────────────────────────────────────────────
  await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
  console.log('[T9] Start_Scenario OK — SCG01EA loading');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-05-start-scenario.png') });

  const outputAfterStart = await getOutput(page);
  expect(outputAfterStart).toContain('SCG01EA');
  expect(outputAfterStart).not.toContain('SIGSEGV');
  expect(outputAfterStart).not.toContain('Aborted(');

  // ── 9. Frame 100 ────────────────────────────────────────────────────────
  await waitForOutput(page, '[RA] Main_Loop frame 100', 300_000);
  // Poll until canvas has non-black content — log fires before SDL present call.
  await expect.poll(() => canvasFillPct(page), { timeout: 5_000, intervals: [100, 200, 500] }).toBeGreaterThan(0);
  console.log('[T9] frame 100 reached');

  const fill100 = await canvasFillPct(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't9-ra-wasm-06-frame-100.png') });
  console.log(`[T9] frame 100 fill: ${fill100}%`);

  const outputFinal = await getOutput(page);
  const noPageErrors = pageErrors.length === 0;

  console.log('\n[T9] ===== SUMMARY =====');
  console.log(`  Assets load:          PASS`);
  console.log(`  Init_Bulk_Data:       PASS`);
  console.log(`  VQA skip:             PASS`);
  console.log(`  Main menu ready:      PASS`);
  console.log(`  New Campaign click:   PASS`);
  console.log(`  Difficulty accepted:  PASS`);
  console.log(`  Faction → Allies:     PASS`);
  console.log(`  Start_Scenario OK:    PASS`);
  console.log(`  Frame 100 reached:    PASS`);
  console.log(`  Canvas fill@f100:     ${fill100}% (threshold ≥5%)`);
  console.log(`  No page errors:       ${noPageErrors ? 'PASS' : 'FAIL (' + pageErrors.length + ' errors)'}`);
  console.log('  Screenshots: t9-ra-wasm-0[1-6].png');

  expect(outputFinal).toContain('[RA] Main_Loop frame 100');
  expect(outputFinal).not.toContain('SIGSEGV');
  expect(outputFinal).not.toContain('Aborted(');
  expect(pageErrors, 'no uncaught JS errors').toHaveLength(0);
  expect(fill100, 'canvas fill must be ≥5% at frame 100').toBeGreaterThanOrEqual(5);
});
