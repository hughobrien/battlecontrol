/**
 * T10 — RA WASM post-game menu bleed regression (TIM-810).
 *
 * Regression gate: verifies that after exiting a game back to the main menu,
 * the canvas matches a clean main menu (SSIM ≥ 0.90). Catches the TIM-777
 * bug class where the game map "bleeds" into the menu screen after leaving
 * a mission.
 *
 * Flow:
 *   1. Load ra.html without autostart, wait for clean menu, capture golden.
 *   2. Load ra.html with ?autostart=1 → SCG01EA starts automatically.
 *   3. Wait for frame 100 (gameplay established).
 *   4. Press Escape → GameOptions dialog.
 *   5. ArrowUp to "Quit Mission" button, Enter to select.
 *   6. Enter again to confirm "Abort" (default in the exit-confirm dialog).
 *   7. Wait for [TIM-616] menu_cs= (main menu loop re-entered).
 *   8. Capture post-game menu screenshot.
 *   9. Compare with golden via parity-compare.py; assert SSIM ≥ 0.90.
 *
 * Skipped when RA_ASSETS_URL is not set (asset-dependent gate).
 *
 * Servers required:
 *   serve-coop.py   on :8080 — WASM bundle (started by CI workflow).
 *   serve-assets.py on :9090 — RA MIX files (or RA_ASSETS_URL CDN).
 *
 * Budget: 600 s — ~120 s preloader + ~60 s frame 100 + ~10 s exit flow +
 *   ~60 s reload + settle + ~10 s comparison.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

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

async function countMenuCs(page: any): Promise<number> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    if (!el || !el.textContent) return 0;
    return (el.textContent.match(/\[TIM-616\] menu_cs=/g) || []).length;
  });
}

test('T10 — post-game menu canvas matches clean menu (SSIM ≥ 0.90)', async ({ page }) => {
  test.setTimeout(600_000);

  if (!process.env['RA_ASSETS_URL']) {
    test.skip(true, 'T10 skipped — RA_ASSETS_URL not set');
    return;
  }

  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));

  const goldenPath = path.join(SCREENSHOTS_DIR, 't10-clean-menu-golden.png');
  const postGamePath = path.join(SCREENSHOTS_DIR, 't10-post-game-menu.png');
  const diffOutPath = path.join(SCREENSHOTS_DIR, 't10-ssim-diff.png');

  // ═══════════════════════════════════════════════════════════════════
  // Phase 1: Capture clean main-menu golden
  // ═══════════════════════════════════════════════════════════════════
  const cleanUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[T10] loading clean menu: ${cleanUrl}`);
  await page.goto(cleanUrl, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[T10] clean menu — preloader hidden (MIX assets mounted)');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't10-clean-01-preloader.png') });

  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 120_000);
  console.log('[T10] clean menu — Init_Bulk_Data done');
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't10-clean-02-init-done.png') });

  await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
  console.log('[T10] clean menu — menu gadgets up');

  await expect.poll(() => canvasFillPct(page), { timeout: 10_000, intervals: [200, 500, 1000] }).toBeGreaterThanOrEqual(5);
  const cleanFill = await canvasFillPct(page);
  console.log(`[T10] clean menu canvas fill: ${cleanFill}%`);

  await page.screenshot({ path: goldenPath });
  console.log(`[T10] clean menu golden saved: ${goldenPath}`);

  const outputClean = await getOutput(page);
  expect(outputClean, 'no SIGSEGV during clean menu boot').not.toContain('SIGSEGV');
  expect(outputClean, 'no Aborted during clean menu boot').not.toContain('Aborted(');

  // ═══════════════════════════════════════════════════════════════════
  // Phase 2: Load with autostart=1, enter game, exit back to menu
  // ═══════════════════════════════════════════════════════════════════
  const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&debug=1`;
  console.log(`[T10] loading game URL: ${gameUrl}`);
  await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[T10] game — preloader hidden');

  await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 180_000);
  console.log('[T10] game — Start_Scenario OK (SCG01EA started)');

  await waitForOutput(page, '[RA] Main_Loop frame 100', 300_000);
  console.log('[T10] game — frame 100 reached');

  await expect.poll(() => canvasFillPct(page), { timeout: 10_000, intervals: [200, 500, 1000] }).toBeGreaterThan(0);
  const gameFill = await canvasFillPct(page);
  console.log(`[T10] in-game canvas fill: ${gameFill}%`);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't10-game-01-frame100.png') });

  // ── Exit flow: keyboard navigation through GameOptions dialog ──
  // GameOptionsClass default cursor is on BUTTON_RESUME (curbutton=6).
  // One ArrowUp moves to BUTTON_QUIT (index 4).
  // Enter selects it, showing confirm dialog: [Abort] [Restart] [Cancel].
  // Abort is the default button (curbutton=0), so Enter confirms.
  const outputBeforeExit = await getOutput(page);
  const menuCsBeforeExit = (outputBeforeExit.match(/\[TIM-616\] menu_cs=/g) || []).length;
  console.log(`[T10] menu_cs= count before exit: ${menuCsBeforeExit} (should be 0 for autostart load)`);

  await page.keyboard.press('Escape');
  console.log('[T10] pressed Escape — options dialog should open');
  await page.waitForTimeout(1500);

  await page.keyboard.press('ArrowUp');
  console.log('[T10] pressed ArrowUp — should select Quit Mission');
  await page.waitForTimeout(500);

  await page.keyboard.press('Enter');
  console.log('[T10] pressed Enter — should trigger Quit Mission');
  await page.waitForTimeout(2000);

  await page.keyboard.press('Enter');
  console.log('[T10] pressed Enter — should confirm Abort (default)');
  await page.waitForTimeout(1000);

  // ── Wait for main menu to re-enter ────────────────────────────
  // After Queue_Exit fires, GameActive=false, Main_Loop returns,
  // Select_Game restarts and Main_Menu() runs → [TIM-616] fires.
  let menuCsReEntry: number;
  try {
    await page.waitForFunction(
      (countBefore: number) => {
        const el = document.getElementById('output');
        if (!el || !el.textContent) return false;
        const count = (el.textContent.match(/\[TIM-616\] menu_cs=/g) || []).length;
        return count > countBefore;
      },
      menuCsBeforeExit,
      { timeout: 60_000 }
    );
    menuCsReEntry = await countMenuCs(page);
    console.log(`[T10] menu re-entered — menu_cs= count: ${menuCsReEntry}`);
  } catch (e) {
    console.log(`[T10] TIMEOUT waiting for menu_cs= after exit — game may still be in in-game options or menu state`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 't10-game-02-after-exit-timeout.png') });
    throw e;
  }

  // Poll until the post-game menu canvas has non-black content.
  let postMenuFill = 0;
  try {
    await expect.poll(async () => {
      postMenuFill = await canvasFillPct(page);
      return postMenuFill;
    }, { timeout: 15_000, intervals: [500, 1000, 2000] }).toBeGreaterThanOrEqual(5);
  } catch {
    console.log(`[T10] WARN: post-game menu fill only ${postMenuFill}% after poll`);
  }
  console.log(`[T10] post-game menu canvas fill: ${postMenuFill}%`);

  await page.screenshot({ path: postGamePath });
  console.log(`[T10] post-game menu screenshot saved: ${postGamePath}`);

  const outputFinal = await getOutput(page);
  const noPageErrors = pageErrors.length === 0;

  console.log('\n[T10] ===== INTERMEDIATE RESULTS =====');
  console.log(`  Clean menu fill:     ${cleanFill}%`);
  console.log(`  Game frame 100 fill: ${gameFill}%`);
  console.log(`  Post-game menu fill: ${postMenuFill}%`);
  console.log(`  Menu re-entered:     ${menuCsReEntry > menuCsBeforeExit ? 'YES' : 'NO'}`);
  console.log(`  No page errors:      ${noPageErrors ? 'PASS' : 'FAIL (' + pageErrors.length + ' errors)'}`);
  console.log(`  No SIGSEGV/Aborted:  ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);

  expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
  expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
  expect(pageErrors, 'no uncaught JS errors').toHaveLength(0);
  expect(menuCsReEntry, 'menu must re-enter after exiting game').toBeGreaterThan(menuCsBeforeExit);

  // ═══════════════════════════════════════════════════════════════════
  // Phase 3: SSIM comparison with parity-compare.py
  // ═══════════════════════════════════════════════════════════════════
  console.log(`[T10] comparing screenshots via parity-compare.py...`);
  const cmpResult = execSync(
    `python3 scripts/parity-compare.py "${goldenPath}" "${postGamePath}" ` +
    `--label "TIM-810 post-game menu parity" --threshold-ssim 0.90 ` +
    `--diff-out "${diffOutPath}" --json`,
    { encoding: 'utf-8', timeout: 30_000 }
  );

  // The last line of output is the JSON result
  const lines = cmpResult.trim().split('\n');
  const jsonLine = lines[lines.length - 1];
  const result = JSON.parse(jsonLine);

  console.log(`[T10] parity result: status=${result.status} ssim=${result.ssim} threshold=${result.threshold_ssim}`);
  console.log(`[T10] p99 pixel diff: ${result.p99_diff}`);
  console.log(`[T10] fill: clean=${result.fill_a}% post-game=${result.fill_b}%`);
  console.log(`  Diff image: ${diffOutPath}`);

  // Primary regression gate: SSIM must meet threshold.
  // When the map-bleed bug is active, the menu canvas contains
  // leftover map pixels and SSIM drops well below 0.90.
  expect(
    result.ssim,
    `post-game menu SSIM ${result.ssim} < threshold ${result.threshold_ssim} — map bleed regression`
  ).toBeGreaterThanOrEqual(result.threshold_ssim);

  console.log('\n[T10] ===== SUMMARY =====');
  console.log(`  Clean menu golden:    ${cleanFill}% fill`);
  console.log(`  In-game:              frame 100 OK`);
  console.log(`  Menu re-entry:        ${menuCsReEntry} occurrences of menu_cs= (after exit)`);
  console.log(`  Post-game fill:       ${postMenuFill}%`);
  console.log(`  Clean vs post SSIM:   ${result.ssim} (threshold: ${result.threshold_ssim})`);
  console.log(`  p99 pixel diff:       ${result.p99_diff}`);
  console.log(`  Diff image:           ${diffOutPath}`);
  console.log(`  No page errors:       ${noPageErrors ? 'PASS' : 'FAIL'}`);
});
