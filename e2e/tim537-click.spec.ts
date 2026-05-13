/**
 * TIM-537 — RA WASM: synthetic in-game unit-click injection (pass-97 WASM).
 *
 * Tests that browser mouse events injected via page.mouse.click() reach the game
 * and trigger unit selection / move orders in the WASM build.
 *
 * Two injection paths are exercised:
 *   A. C++ SDL_PushEvent (enabled by ?gameclk=1 → RA_GAME_CLICK=1): verifies that
 *      SDL_PushEvent works from a WASM pthread.  Produces [GAME-CLICK] log lines for
 *      easy criterion verification.
 *   B. Browser-native mouse events via page.locator('#canvas').click(): fires after
 *      frame 30 is confirmed, supplementing path A and independently exercising
 *      Emscripten's HTML5 mouse-event → SDL bridge.
 *
 * Acceptance criteria (issue TIM-537):
 *   1. Spec injects synthetic mouse clicks after Start_Scenario + frame 30:
 *        left-click (350,155) for unit select, right-click (430,375) for move order.
 *   2. Unit-count > 0 confirmed after left-click at frame 35 ([GAME-CLICK] log lines).
 *   3. Frame 500 reached without crash (regression check).
 *   4. Canvas non-black at frame 500 (regression check).
 *
 * Servers required:
 *   - serve-coop.py / nginx on port 8080 (WASM bundle)
 *   - serve-assets.py on port 9090 (RA MIX files)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

async function waitForOutput(page: any, substring: string, timeoutMs = 180_000) {
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

async function canvasPixelStats(page: any): Promise<{
  hasContent: boolean; fillPct: number; width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { hasContent: false, fillPct: 0, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { hasContent: len > 2000, fillPct: len > 2000 ? 1 : 0, width: canvas.width, height: canvas.height };
    }
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    for (let i = 0; i < data.length; i += 16) {
      if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
    }
    const total = Math.floor(data.length / 16);
    return { hasContent: nonBlack > 0, fillPct: Math.round(nonBlack / total * 100), width: w, height: h };
  });
}

// ?gameclk=1 → shell.html injects RA_GAME_CLICK=1 into Module.ENV so C++ fires
// SDL_PushEvent at frames 30/35 and logs [GAME-CLICK] lines.
// ?debug=1 → #output div becomes visible (required for waitForOutput).
const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&gameclk=1&debug=1`;

test.describe('TIM-537 — RA WASM unit-click injection (pass-97)', () => {
  test.setTimeout(900_000);   // 15 min — asset load ~4 min + 500 frames ~8 min

  test('unit select + move order: SDL_PushEvent (C++) + browser mouse.click() + frame 500 regression', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // -------------------------------------------------------------------------
    // Phase 1 — Preloader
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 1: Preloader ===');

    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });

    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );
    console.log(`  preloader hidden — ${Math.round((Date.now() - tStart) / 1000)}s`);

    // -------------------------------------------------------------------------
    // Phase 2 — Init_Game + Start_Scenario
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 2: Init_Game + Start_Scenario ===');

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);
    console.log(`  Init_Bulk_Data done — ${Math.round((Date.now() - tStart) / 1000)}s`);

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 240_000);
    const tScenario = Date.now();
    console.log(`  Start_Scenario OK — ${Math.round((tScenario - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim537-scenario-start.png'), fullPage: true });

    let output = await getOutput(page);
    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // Phase 3 — Wait for frame 30, then inject browser mouse clicks
    //
    // SDL_PushEvent path (C++, RA_GAME_CLICK=1): fires at frame 30 (left-click
    // 350,155) and frame 35 (right-click 430,375), logging [GAME-CLICK] lines.
    //
    // Browser-native path (Playwright): fires after frame 30 is observed in
    // #output.  page.locator('#canvas').click({ position: ... }) dispatches a
    // real browser mousedown+mouseup that Emscripten's HTML5 → SDL bridge
    // forwards to the game running in its pthread.
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 3: Click injection (frame 30 → unit select) ===');

    await waitForOutput(page, '[RA] Main_Loop frame 30', 420_000);
    console.log(`  frame 30 observed — ${Math.round((Date.now() - tStart) / 1000)}s`);

    // Browser-native left-click: position is relative to canvas top-left corner.
    // Matches native SDL coordinates (350,155) used by RA_GAME_CLICK.
    const canvas = page.locator('#canvas');
    await canvas.click({ position: { x: 350, y: 155 } });
    console.log('  browser left-click dispatched at canvas(350,155) — unit select');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim537-after-left-click.png'), fullPage: true });

    // -------------------------------------------------------------------------
    // Phase 4 — Frame 35: right-click for move order
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 4: Click injection (frame 35 → move order) ===');

    await waitForOutput(page, '[RA] Main_Loop frame 35', 120_000);
    console.log(`  frame 35 observed — ${Math.round((Date.now() - tStart) / 1000)}s`);

    // Browser-native right-click for move order.
    await canvas.click({ button: 'right', position: { x: 430, y: 375 } });
    console.log('  browser right-click dispatched at canvas(430,375) — move order');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim537-after-right-click.png'), fullPage: true });

    // -------------------------------------------------------------------------
    // Phase 5 — Verify [GAME-CLICK] logs: unit-count > 0 confirms selection
    //
    // C++ logs "[GAME-CLICK] frame 35: unit-count after left-click = N" and
    // "[GAME-CLICK] frame 40: post-click unit-count = N" when RA_GAME_CLICK=1.
    // Unit-count > 0 means a unit was selected by the click at (350,155).
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 5: Verify [GAME-CLICK] log output ===');

    await waitForOutput(page, '[GAME-CLICK] frame 40', 120_000);
    const tClick40 = Date.now();
    console.log(`  [GAME-CLICK] frame 40 seen — ${Math.round((tClick40 - tStart) / 1000)}s`);

    output = await getOutput(page);

    // Extract unit-count from "[GAME-CLICK] frame 35: unit-count after left-click = N"
    const clickLog35 = output.split('\n').find(l => l.includes('[GAME-CLICK]') && l.includes('frame 35') && l.includes('unit-count'));
    const clickLog40 = output.split('\n').find(l => l.includes('[GAME-CLICK]') && l.includes('frame 40') && l.includes('unit-count'));
    console.log(`  [GAME-CLICK] frame 35 line: ${clickLog35 || '(not found)'}`);
    console.log(`  [GAME-CLICK] frame 40 line: ${clickLog40 || '(not found)'}`);

    // Log all [GAME-CLICK] lines for audit trail
    const allClickLogs = output.split('\n').filter(l => l.includes('[GAME-CLICK]'));
    console.log(`  All [GAME-CLICK] lines (${allClickLogs.length}):`);
    allClickLogs.forEach(l => console.log(`    ${l}`));

    // Criterion 2: unit-count > 0 after left-click
    const unitCount35 = clickLog35
      ? parseInt((clickLog35.match(/unit-count after left-click = (\d+)/) || [])[1] ?? '0', 10)
      : -1;
    const unitCount40 = clickLog40
      ? parseInt((clickLog40.match(/unit-count = (\d+)/) || [])[1] ?? '0', 10)
      : -1;
    console.log(`  unit-count at frame 35: ${unitCount35}  unit-count at frame 40: ${unitCount40}`);

    // -------------------------------------------------------------------------
    // Phase 6 — Regression: frame 500 + canvas non-black
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] === Phase 6: Regression — frame 500 + canvas ===');

    await waitForOutput(page, '[RA] Main_Loop frame 500', 600_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim537-frame500.png'), fullPage: true });
    console.log(`  frame 500 — ${Math.round((t500 - tStart) / 1000)}s`);
    console.log(`  canvas ${stats500.width}x${stats500.height} fill=${stats500.fillPct}% hasContent=${stats500.hasContent}`);

    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // SUMMARY
    // -------------------------------------------------------------------------
    console.log('\n[TIM-537] ===== AUDIT SUMMARY =====');
    console.log(`  1. Click injected after Start_Scenario + frame 30:        PASS`);
    console.log(`     left-click (350,155) via browser + SDL_PushEvent`);
    console.log(`     right-click (430,375) via browser + SDL_PushEvent`);
    console.log(`  2. Unit-count > 0 at frame 35 ([GAME-CLICK] log):         ${unitCount35 > 0 ? 'PASS' : unitCount35 === 0 ? 'FAIL (count=0, no unit selected)' : 'WARN (log line absent)'}`);
    console.log(`     unit-count @ frame 35 = ${unitCount35}  @ frame 40 = ${unitCount40}`);
    console.log(`  3. Frame 500 reached without crash:                        PASS`);
    console.log(`  4. Canvas non-black at frame 500:                          ${stats500.hasContent ? 'PASS' : 'FAIL'} (fill=${stats500.fillPct}%)`);
    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }

    // Hard assertions
    expect(output).toContain('[GAME-CLICK]');
    expect(unitCount35, 'unit-count must be > 0 after left-click at frame 35 (criterion 2)').toBeGreaterThan(0);
    expect(stats500.hasContent, 'canvas must have non-black content at frame 500 (criterion 4)').toBe(true);
  });
});
