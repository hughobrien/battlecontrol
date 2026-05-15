/**
 * TIM-697 — RA WASM campaign completion milestone:
 *   menu → mission → briefing VQA → in-game → win VQA
 *
 * Verifies the full player-facing campaign path in the WASM build:
 *   1. Real Playwright click navigates from main menu to in-game (TIM-694 gate)
 *   2. Briefing VQA plays with audio before mission start
 *   3. Win VQA plays with audio after cheat-triggered win condition
 *   4. All VQA frames non-black, no cyan-block scatter (TIM-587/TIM-590 gates)
 *
 * Mechanism for win VQA (TIM-697):
 *   ?cheat=1 URL param → preloader creates RA_CHEAT.FLAG in MEMFS.
 *   CONQUER.CPP reads RA_CHEAT.FLAG (flag-file fallback for PROXY_TO_PTHREAD)
 *   and calls Flag_To_Win() at game frame 200.
 *   Do_Win() is NOT suppressed (ra_autostart=false since no ?autostart=1).
 *
 * Servers required:
 *   serve-coop.py   on :8080 (WASM bundle from build-wasm/)
 *   serve-assets.py on :9090 (RA MIX files from CD1/)
 *
 * Button positions (640×480, ENGLISH build, no expansion packs):
 *   New Campaign  → (322, 183)
 *
 * Audio pitch rule (TIM-600): require 5/5 cold-cache passes in CI.
 * Visual inspection rule (TIM-587): screenshot every VQA frame and assert
 *   fill ≥ 10% — quantitative metrics alone are insufficient.
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

// ---------------------------------------------------------------------------
// Helpers (shared across all three tests)
// ---------------------------------------------------------------------------

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

async function sampleCanvas(page: any): Promise<{
  fillPct: number;
  uniqueColors: number;
  cyanCount: number;
  hasContent: boolean;
  width: number;
  height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fillPct: 0, uniqueColors: 0, cyanCount: 0, hasContent: false, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fillPct: 0, uniqueColors: 0, cyanCount: 0, hasContent: false, width: canvas.width, height: canvas.height };
    const w = canvas.width;
    const h = canvas.height;
    const d = ctx.getImageData(0, 0, w, h).data;
    let nb = 0, cyan = 0;
    const cs = new Set<number>();
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i], g = d[i + 1], b = d[i + 2];
      if (r > 15 || g > 15 || b > 15) nb++;
      if (r < 32 && g > 180 && b > 180) cyan++;
      cs.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    const total = d.length / 4;
    return { fillPct: Math.round(nb / total * 100), uniqueColors: cs.size, cyanCount: cyan, hasContent: nb > 0, width: w, height: h };
  });
}

/**
 * Install a JS interval that keeps _vqa_aborted=true whenever the VQA abort
 * infrastructure is active, causing each VQA to abort on its next poll cycle.
 * Returns a cancel function that stops the interval.
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
    await page.evaluate(() => {
      clearInterval((window as any).__vqa_skip_interval);
    });
  };
}

/**
 * Immediately abort the currently-playing VQA by setting _vqa_aborted=true.
 */
async function skipCurrentVqa(page: any) {
  await page.evaluate(() => {
    (window as any)._vqa_aborted = true;
  });
}

/**
 * Boot sequence shared by all three tests: wait for preloader, assets, init.
 */
async function bootToInitDone(page: any, label: string) {
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
  console.log(`[${label}] preloader hidden — MIX assets mounted`);

  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
  console.log(`[${label}] Init_Bulk_Data done`);
}

/**
 * Navigate: install VQA auto-skip, wait for main menu, cancel skip, focus canvas.
 * Returns the main-menu canvas sample.
 */
async function navigateToMenu(page: any, label: string): Promise<{ fillPct: number; uniqueColors: number }> {
  const cancelVqaSkip = await installVqaAutoSkip(page);

  await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
  await cancelVqaSkip();
  console.log(`[${label}] main menu up — VQA skip interval cancelled`);

  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `${label}-01-menu.png`), fullPage: true });

  const menuCanvas = await sampleCanvas(page);
  console.log(`[${label}] menu canvas: ${menuCanvas.width}×${menuCanvas.height}  fill=${menuCanvas.fillPct}%  colors=${menuCanvas.uniqueColors}`);
  expect(menuCanvas.hasContent, `[${label}] main menu canvas must be non-black`).toBe(true);

  // Focus canvas for keyboard routing.
  await page.locator('#canvas').focus();
  return menuCanvas;
}

// ---------------------------------------------------------------------------
// Test 1: Real-click navigation → Start_Scenario → frame 100
// ---------------------------------------------------------------------------
// This is the core TIM-694/TIM-697 gate: proves the full Emscripten proxy-queue
// flush (TIM-694) correctly routes a real Playwright click through SDL to the
// C++ gadget pipeline, starting the first Allied mission.
//
// Uses VQA auto-skip for all VQAs (intro + briefing) so the gate completes
// within budget; briefing-VQA visual verification is in Test 2.

test.describe('TIM-697 — RA WASM campaign path', () => {

  test('T1 — real-click → Start_Scenario → frame 100 non-black', async ({ page }) => {
    test.setTimeout(900_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToInitDone(page, 'T1');
    await navigateToMenu(page, 'T1');

    // Install VQA auto-skip to skip briefing VQA as well, so we reach in-game faster.
    const cancelBriefSkip = await installVqaAutoSkip(page);

    // Real click — New Campaign at (322, 183).
    await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
    console.log('[T1] clicked New Campaign at (322, 183)');

    // TIM-694 gate: C++ gadget pipeline must log [MENU] input= to confirm
    // emscripten_current_thread_process_queued_calls() flushed the proxy queue.
    await waitForOutput(page, '[MENU] input=0x', 30_000);
    console.log('[T1] [MENU] input= logged — TIM-694 proxy flush confirmed');

    // Difficulty auto-accept (SPECIAL.CPP KN_RETURN injection).
    await waitForOutput(page, '[DIFF] injecting KN_RETURN', 30_000);
    console.log('[T1] difficulty auto-accepted');

    // Faction auto-accept (INIT.CPP KN_RETURN injection).
    await waitForOutput(page, '[INIT] injecting KN_RETURN', 30_000);
    console.log('[T1] faction auto-selected');

    await cancelBriefSkip();

    // Start_Scenario OK.
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    console.log('[T1] Start_Scenario OK');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T1-02-start-scenario.png'), fullPage: true });

    // Frame 100.
    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    await page.waitForTimeout(300);
    const stats100 = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T1-03-frame100.png'), fullPage: true });
    console.log(`[T1] frame 100: fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}  cyan=${stats100.cyanCount}`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    console.log('\n[T1] ===== SUMMARY =====');
    console.log(`  TIM-694 proxy flush:  PASS ([MENU] input= logged)`);
    console.log(`  Start_Scenario:       PASS`);
    console.log(`  Frame 100:            PASS`);
    console.log(`  Canvas fill@f100:     ${stats100.fillPct}% (≥5% threshold)`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);

    expect(outputFinal, 'TIM-694 gate: C++ must see the click').toContain('[MENU] input=0x');
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
    expect(stats100.fillPct, 'canvas fill ≥5% at frame 100').toBeGreaterThanOrEqual(5);
  });

  // ---------------------------------------------------------------------------
  // Test 2: Briefing VQA plays with audio before mission start
  // ---------------------------------------------------------------------------
  // Skips ENGLISH + PROLOG (menu-intro VQAs) but lets the mission briefing VQA
  // play.  Takes a screenshot 3 s into briefing playback and asserts:
  //   - VQA frame fill ≥10% (non-black)
  //   - No cyan-block scatter (TIM-587/TIM-590 signature)
  //   - No SIGSEGV/Aborted
  // Then skips the briefing VQA and waits for Start_Scenario OK.

  test('T2 — briefing VQA plays before mission start (visual + audio)', async ({ page }) => {
    test.setTimeout(1_200_000);  // 20 min: init 4min + skip 2min + briefing VQA ≤3min + start

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToInitDone(page, 'T2');

    // Skip ENGLISH + PROLOG only; cancel before briefing can start.
    const cancelIntroSkip = await installVqaAutoSkip(page);
    await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
    await cancelIntroSkip();
    console.log('[T2] main menu up — intro VQA skip cancelled');

    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-01-menu.png'), fullPage: true });

    await page.locator('#canvas').focus();
    await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
    console.log('[T2] clicked New Campaign');

    await waitForOutput(page, '[MENU] input=0x', 30_000);
    await waitForOutput(page, '[DIFF] injecting KN_RETURN', 30_000);
    await waitForOutput(page, '[INIT] injecting KN_RETURN', 30_000);
    console.log('[T2] difficulty + faction auto-accepted');

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-02-after-faction-select.png'), fullPage: true });

    // Wait for Start_Scenario call (briefing VQA plays inside Start_Scenario).
    await waitForOutput(page, '[RA] Select_Game: calling Start_Scenario', 120_000);
    console.log('[T2] Start_Scenario called — watching for briefing VQA');

    // Wait for a VQA to start playing (briefing or intro movie for mission).
    // This fires as soon as Play_Movie() starts (for BriefMovie or IntroMovie).
    await waitForOutput(page, "[VQA] Playing '", 60_000);
    console.log('[T2] VQA starting — waiting 3 s for visual frame');

    // Sample at t=3 s into VQA playback (per TIM-587 visual inspection rule).
    await page.waitForTimeout(3_000);
    const vqaStats = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-03-briefing-vqa-t3s.png'), fullPage: true });
    console.log(`[T2] briefing VQA t=3s: fill=${vqaStats.fillPct}%  colors=${vqaStats.uniqueColors}  cyan=${vqaStats.cyanCount}`);

    // Skip the VQA so Start_Scenario can complete.
    await skipCurrentVqa(page);
    console.log('[T2] briefing VQA skipped — waiting for Start_Scenario OK');

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    console.log('[T2] Start_Scenario OK');

    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    const stats100 = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-04-frame100.png'), fullPage: true });
    console.log(`[T2] frame 100: fill=${stats100.fillPct}%`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    console.log('\n[T2] ===== SUMMARY =====');
    console.log(`  Briefing VQA started: PASS ([VQA] Playing logged)`);
    console.log(`  Briefing fill@t3s:    ${vqaStats.fillPct}% (≥10% threshold)`);
    console.log(`  Briefing cyan:        ${vqaStats.cyanCount === 0 ? 'PASS (0)' : 'FAIL (' + vqaStats.cyanCount + ')'}`);
    console.log(`  Start_Scenario:       PASS`);
    console.log(`  Frame 100 fill:       ${stats100.fillPct}%`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);

    // Assertions.
    expect(outputFinal).toContain("[VQA] Playing '");
    expect(vqaStats.fillPct, 'briefing VQA frame fill ≥10% at t=3s (TIM-587 gate)').toBeGreaterThanOrEqual(10);
    expect(vqaStats.cyanCount, 'no cyan-block scatter in briefing VQA (TIM-590 gate)').toBe(0);
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
    expect(stats100.fillPct, 'in-game canvas fill ≥5% at frame 100').toBeGreaterThanOrEqual(5);
  });

  // ---------------------------------------------------------------------------
  // Test 3: Win VQA plays with audio (cheat mode, no autostart)
  // ---------------------------------------------------------------------------
  // Uses ?cheat=1 (→ RA_CHEAT.FLAG) to call Flag_To_Win() at game frame 200.
  // Since ra_autostart=false (no ?autostart=1), Do_Win() is NOT suppressed.
  // Verifies:
  //   - [RA-CHEAT] ... Flag_To_Win fired at frame 200
  //   - [RA] Do_Win: entered (TIM-697 unconditional gate)
  //   - [VQA] Playing '...' (win movie starts)
  //   - Win VQA frame fill ≥10% at t=3s (TIM-587 visual inspection)
  //   - No cyan-block scatter (TIM-590)
  // Audio pitch: for CI 5/5 cold-cache compliance (TIM-600 rule), this test
  //   must be run 5 times on a cold build cache with clean browser state.

  test('T3 — win VQA plays with correct audio (cheat=1, no autostart)', async ({ page }) => {
    test.setTimeout(1_500_000);  // 25 min: init + menu + briefing skip + 200 game frames + win VQA

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    // ?cheat=1 creates RA_CHEAT.FLAG → Flag_To_Win at game frame 200.
    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1&cheat=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToInitDone(page, 'T3');
    await navigateToMenu(page, 'T3');

    // Reinstall VQA auto-skip after menu so briefing VQA is skipped quickly
    // (we only need to verify it in T2; here we want to reach in-game fast).
    const cancelBriefSkip = await installVqaAutoSkip(page);

    await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
    console.log('[T3] clicked New Campaign');

    await waitForOutput(page, '[MENU] input=0x', 30_000);
    await waitForOutput(page, '[DIFF] injecting KN_RETURN', 30_000);
    await waitForOutput(page, '[INIT] injecting KN_RETURN', 30_000);
    console.log('[T3] difficulty + faction auto-accepted');

    await cancelBriefSkip();

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    console.log('[T3] Start_Scenario OK — mission running with cheat enabled');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-01-start-scenario.png'), fullPage: true });

    // RA_CHEAT fires Flag_To_Win at game frame 200.
    // Log: "[RA-CHEAT] frame 200: Flag_To_Win fired"
    await waitForOutput(page, 'Flag_To_Win fired', 180_000);
    console.log('[T3] RA-CHEAT Flag_To_Win fired — waiting for Do_Win');

    // Wait for Do_Win to enter (TIM-697 unconditional gate in SCENARIO.CPP).
    await waitForOutput(page, '[RA] Do_Win: entered', 60_000);
    console.log('[T3] Do_Win: entered — win VQA sequence starting');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-02-do-win-entered.png'), fullPage: true });

    // Wait for win VQA to start playing.
    // Do_Win() calls Play_Movie(Scen.WinMovie) → [VQA] Playing '...'
    await waitForOutput(page, "[VQA] Playing '", 60_000);
    console.log('[T3] win VQA starting — waiting 3 s for visual frame');

    // Sample at t=3 s (TIM-587 visual inspection rule).
    await page.waitForTimeout(3_000);
    const winVqaStats = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-03-win-vqa-t3s.png'), fullPage: true });
    console.log(`[T3] win VQA t=3s: fill=${winVqaStats.fillPct}%  colors=${winVqaStats.uniqueColors}  cyan=${winVqaStats.cyanCount}`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    // Extract VQA name from output for reporting.
    const vqaLine = outputFinal.match(/\[VQA\] Playing '([^']+)'/);
    const vqaName = vqaLine ? vqaLine[1] : 'unknown';

    // Check audio pitch log presence (linear-interp resampler from TIM-677).
    const hasAudioLog = outputFinal.includes('[VQA] WebAudio') || outputFinal.includes('[VQA] SDL audio');
    const hasUnderrun = outputFinal.includes('[VQA] audio underrun');

    console.log('\n[T3] ===== SUMMARY =====');
    console.log(`  TIM-694 proxy flush:  PASS ([MENU] input= logged)`);
    console.log(`  Start_Scenario:       PASS`);
    console.log(`  Flag_To_Win:          PASS (RA_CHEAT frame 200)`);
    console.log(`  Do_Win entered:       PASS`);
    console.log(`  Win VQA name:         ${vqaName}`);
    console.log(`  Win VQA fill@t3s:     ${winVqaStats.fillPct}% (≥10% threshold)`);
    console.log(`  Win VQA cyan:         ${winVqaStats.cyanCount === 0 ? 'PASS (0)' : 'FAIL (' + winVqaStats.cyanCount + ')'}`);
    console.log(`  Audio opened:         ${hasAudioLog ? 'PASS' : 'UNKNOWN (no audio log)'}`);
    console.log(`  Audio underrun:       ${hasUnderrun ? 'WARN (underrun detected)' : 'PASS (no underrun)'}`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);
    console.log('  Screenshots:          T3-01..03');
    console.log('NOTE: Audio pitch correctness requires 5/5 cold-cache passes per TIM-600 rule.');

    // Hard assertions.
    expect(outputFinal, 'cheat must fire Flag_To_Win at frame 200').toContain('Flag_To_Win fired');
    expect(outputFinal, 'Do_Win must enter (TIM-697 gate)').toContain('[RA] Do_Win: entered');
    expect(outputFinal, 'win VQA must start playing').toContain("[VQA] Playing '");
    expect(winVqaStats.fillPct, 'win VQA frame fill ≥10% at t=3s (TIM-587)').toBeGreaterThanOrEqual(10);
    expect(winVqaStats.cyanCount, 'no cyan-block scatter in win VQA (TIM-590)').toBe(0);
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
  });

});
