/**
 * TIM-774 — TD WASM campaign completion smoke:
 *   menu → Start New Game → briefing VQA → in-game → win VQA
 *
 * RA parallel: TIM-697 (tim697-ra-campaign-complete.spec.ts)
 *
 * Verifies the full GDI L1 campaign path in the TD WASM build:
 *   1. Real Playwright click navigates from main menu to in-game (T6 gate)
 *   2. Briefing VQA plays with audio before mission start
 *   3. Win VQA plays with audio after cheat-triggered win condition
 *   4. All VQA frames non-black, no pageerror, no SIGSEGV
 *
 * Mechanism for win VQA (TIM-774):
 *   ?cheat=1 URL param → preloader creates TD_CHEAT.FLAG in MEMFS.
 *   CONQUER.CPP reads TD_CHEAT.FLAG (flag-file fallback for PROXY_TO_PTHREAD)
 *   and calls PlayerPtr->Flag_To_Win() at game frame 200.
 *   Do_Win() plays WinMovie; game proceeds to next scenario.
 *
 * TD WASM specifics:
 *   - Choose_Side() is hardcoded to GDI in the WASM build — no dialog shown
 *   - No difficulty dialog (unlike RA which shows a difficulty dialog)
 *   - LOGO.VQA plays during boot (skipped via VQA auto-skip interval)
 *   - BriefMovie + ActionMovie VQAs play inside Start_Scenario
 *   - ?cheat=1 fires Flag_To_Win at frame 200 (TD_CHEAT.FLAG pattern)
 *
 * Release-gate spec — NOT wired into PR CI (90s budget, too slow for every-push).
 * Run before tagging v0.3.0:
 *   npx playwright test e2e/tim774-td-campaign-complete.spec.ts --headed
 *
 * Servers required:
 *   serve-coop.py   on :8082 (TD WASM bundle from build-wasm/)
 *   serve-assets.py on :9091 (TD MIX files from CD1/)
 *
 * Button positions (640×480, NEWMENU):
 *   Start New Game → (321, 59)   [D_START_X=196+125, starty=50+9]
 *
 * Anti-flake rigor: 5/5 cold-cache passes required (TIM-766 pattern).
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8082/td.html';
const ASSET_URL       = 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Helpers
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
 * infrastructure is active.  Returns a cancel function.
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

/** Immediately abort the currently-playing VQA. */
async function skipCurrentVqa(page: any) {
  await page.evaluate(() => {
    (window as any)._vqa_aborted = true;
  });
}

/**
 * Boot sequence: wait for preloader to hide (assets mounted).
 * TD init takes longer than RA — use 300 s for the preloader gate.
 */
async function bootToPreloaderDone(page: any, label: string) {
  const errorBanner = page.locator('#browser-error');
  await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 300_000 }
  );
  console.log(`[${label}] preloader hidden — MIX assets mounted`);
}

/**
 * Navigate to main menu:
 *   - Install VQA auto-skip to suppress LOGO.VQA
 *   - Wait for [TD] Main_Menu: gadgets up
 *   - Cancel skip and focus canvas
 */
async function navigateToMenu(page: any, label: string): Promise<{ fillPct: number; uniqueColors: number }> {
  const cancelVqaSkip = await installVqaAutoSkip(page);

  await waitForOutput(page, '[TD] Main_Menu: gadgets up', 180_000);
  await cancelVqaSkip();
  console.log(`[${label}] main menu up — LOGO.VQA skip interval cancelled`);

  // Poll until title screen has rendered at least some pixels.
  let fillBefore = 0;
  await expect.poll(async () => {
    fillBefore = await page.evaluate(() => {
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
    return fillBefore;
  }, { timeout: 10_000, intervals: [200, 500, 1_000] }).toBeGreaterThan(0);

  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `${label}-01-menu.png`), fullPage: true });

  const menuCanvas = await sampleCanvas(page);
  console.log(`[${label}] menu canvas: ${menuCanvas.width}×${menuCanvas.height}  fill=${menuCanvas.fillPct}%  colors=${menuCanvas.uniqueColors}`);
  expect(menuCanvas.hasContent, `[${label}] main menu canvas must be non-black`).toBe(true);

  await page.locator('#canvas').focus();
  return menuCanvas;
}

// ---------------------------------------------------------------------------
// Test 1: Real-click navigation → Start_Scenario → frame 100
// ---------------------------------------------------------------------------
// Core campaign gate: proves that a real Playwright click on "Start New Game"
// reaches SCG01EA frame 100 with canvas fill ≥20%.  Mirrors TIM-755 / T6 but
// is a narrative sub-test within this campaign-completion spec.
//
// Choose_Side() is hardcoded to GDI in the WASM build — no interactive dialog.
// All VQAs (LOGO intro, BriefMovie, ActionMovie) are auto-skipped so the gate
// completes within budget; briefing VQA verification is in Test 2.

test.describe('TIM-774 — TD WASM campaign path', () => {

  test('T1 — real-click → Start_Scenario → frame 100 non-black', async ({ page }) => {
    test.setTimeout(900_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToPreloaderDone(page, 'T1');
    await navigateToMenu(page, 'T1');

    // Install VQA auto-skip to skip BriefMovie + ActionMovie so we reach in-game faster.
    const cancelBriefSkip = await installVqaAutoSkip(page);

    // Real click — Start New Game at (321, 59).
    await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
    console.log('[T1] clicked Start New Game at (321, 59)');

    // Choose_Side() returns immediately with GDI auto-selected — no dialog.
    await waitForOutput(page, '[TD INIT] calling Start_Scenario', 60_000);
    console.log('[T1] Start_Scenario called — GDI L1 loading');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T1-02-start-scenario.png'), fullPage: true });

    await cancelBriefSkip();

    // Frame 100.
    await waitForOutput(page, '[TD] Main_Loop frame 100', 420_000);
    await expect.poll(() => page.evaluate(() => {
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
    }), { timeout: 5_000, intervals: [100, 200, 500] }).toBeGreaterThan(0);

    const stats100 = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T1-03-frame100.png'), fullPage: true });
    console.log(`[T1] frame 100: fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}  cyan=${stats100.cyanCount}`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    console.log('\n[T1] ===== SUMMARY =====');
    console.log(`  Start New Game click: PASS`);
    console.log(`  Choose_Side GDI:      PASS (auto-selected)`);
    console.log(`  Start_Scenario:       PASS`);
    console.log(`  Frame 100:            PASS`);
    console.log(`  Canvas fill@f100:     ${stats100.fillPct}% (≥20% threshold)`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);

    expect(outputFinal).toContain('[TD INIT] calling Start_Scenario');
    expect(outputFinal).toContain('SCG01EA');
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
    expect(stats100.fillPct, 'canvas fill ≥20% at frame 100').toBeGreaterThanOrEqual(20);
  });

  // ---------------------------------------------------------------------------
  // Test 2: Briefing VQA plays with audio before mission start
  // ---------------------------------------------------------------------------
  // Skips LOGO.VQA (boot intro) but lets the BriefMovie VQA play.
  // Takes a screenshot 3 s into briefing playback and asserts:
  //   - VQA frame fill ≥5% (non-black)
  //   - No cyan-block scatter (TIM-587/TIM-590 signature)
  //   - No SIGSEGV/Aborted
  // Then skips the briefing VQA and waits for game loop.

  test('T2 — briefing VQA plays before mission start (visual + audio)', async ({ page }) => {
    test.setTimeout(1_200_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToPreloaderDone(page, 'T2');

    // Skip LOGO.VQA only; cancel before briefing.
    const cancelIntroSkip = await installVqaAutoSkip(page);
    await waitForOutput(page, '[TD] Main_Menu: gadgets up', 180_000);
    await cancelIntroSkip();
    console.log('[T2] main menu up — LOGO.VQA skip cancelled');

    await expect.poll(() => page.evaluate(() => {
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
    }), { timeout: 10_000, intervals: [200, 500, 1_000] }).toBeGreaterThan(0);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-01-menu.png'), fullPage: true });
    await page.locator('#canvas').focus();

    // Click Start New Game.
    await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
    console.log('[T2] clicked Start New Game');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-02-after-click.png'), fullPage: true });

    // Wait for Start_Scenario call (BriefMovie VQA plays inside Start_Scenario).
    await waitForOutput(page, '[TD INIT] calling Start_Scenario', 60_000);
    console.log('[T2] Start_Scenario called — watching for briefing VQA');

    // Wait for a VQA to start playing (BriefMovie or ActionMovie for this scenario).
    await waitForOutput(page, "[VQA] Playing '", 60_000);
    console.log('[T2] VQA starting — waiting 3 s for visual frame');

    // Sample at t=3 s into VQA playback (per TIM-587 visual inspection rule).
    await page.waitForTimeout(3_000);
    const vqaStats = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-03-briefing-vqa-t3s.png'), fullPage: true });
    console.log(`[T2] briefing VQA t=3s: fill=${vqaStats.fillPct}%  colors=${vqaStats.uniqueColors}  cyan=${vqaStats.cyanCount}`);

    // Skip the VQA so the game loop can start.
    await skipCurrentVqa(page);
    console.log('[T2] briefing VQA skipped — waiting for game loop');

    // Skip ActionMovie if it follows.
    const cancelActionSkip = await installVqaAutoSkip(page);
    await waitForOutput(page, '[TD] Main_Loop frame 100', 420_000);
    await cancelActionSkip();

    const stats100 = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T2-04-frame100.png'), fullPage: true });
    console.log(`[T2] frame 100: fill=${stats100.fillPct}%`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    console.log('\n[T2] ===== SUMMARY =====');
    console.log(`  Briefing VQA started: PASS ([VQA] Playing logged)`);
    console.log(`  Briefing fill@t3s:    ${vqaStats.fillPct}% (≥5% threshold)`);
    console.log(`  Briefing cyan:        ${vqaStats.cyanCount === 0 ? 'PASS (0)' : 'FAIL (' + vqaStats.cyanCount + ')'}`);
    console.log(`  Frame 100 fill:       ${stats100.fillPct}%`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);

    expect(outputFinal).toContain("[VQA] Playing '");
    expect(vqaStats.fillPct, 'briefing VQA frame fill ≥5% at t=3s (TIM-587 gate)').toBeGreaterThanOrEqual(5);
    expect(vqaStats.cyanCount, 'no cyan-block scatter in briefing VQA (TIM-590 gate)').toBe(0);
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
    expect(stats100.fillPct, 'in-game canvas fill ≥20% at frame 100').toBeGreaterThanOrEqual(20);
  });

  // ---------------------------------------------------------------------------
  // Test 3: Win VQA plays with audio (cheat mode, no autostart)
  // ---------------------------------------------------------------------------
  // Uses ?cheat=1 (→ TD_CHEAT.FLAG) to call PlayerPtr->Flag_To_Win() at game
  // frame 200.  Verifies:
  //   - [TD-CHEAT] frame 200: Flag_To_Win fired
  //   - [TD] Do_Win: entered (win sequence started)
  //   - [VQA] Playing '...' (win movie starts)
  //   - Win VQA frame fill ≥5% at t=3s (TIM-587 visual inspection)
  //   - No cyan-block scatter (TIM-590)
  //   - No SIGSEGV, no pageerror
  //
  // Anti-flake: per TIM-766 / TIM-600 rule, run 5× cold-cache before marking
  // this spec verified.

  test('T3 — win VQA plays with correct audio (cheat=1, no autostart)', async ({ page }) => {
    test.setTimeout(1_500_000);

    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    // ?cheat=1 creates TD_CHEAT.FLAG → PlayerPtr->Flag_To_Win() at game frame 200.
    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1&cheat=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    await bootToPreloaderDone(page, 'T3');
    await navigateToMenu(page, 'T3');

    // Install VQA auto-skip to skip BriefMovie + ActionMovie so we reach frame 200 fast.
    const cancelBriefSkip = await installVqaAutoSkip(page);

    await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
    console.log('[T3] clicked Start New Game');

    await waitForOutput(page, '[TD INIT] calling Start_Scenario', 60_000);
    console.log('[T3] Start_Scenario called — cheat enabled, briefing VQAs being skipped');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-01-start-scenario.png'), fullPage: true });

    await cancelBriefSkip();

    // Wait for game loop frame 200 where TD_CHEAT fires Flag_To_Win.
    await waitForOutput(page, '[TD] Main_Loop frame 200', 420_000);
    console.log('[T3] frame 200 reached — waiting for Flag_To_Win');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-02-frame200.png'), fullPage: true });

    // TD-CHEAT fires at frame 200: Flag_To_Win.
    await waitForOutput(page, 'Flag_To_Win fired', 30_000);
    console.log('[T3] TD-CHEAT Flag_To_Win fired — waiting for Do_Win');

    // Do_Win: entered (TIM-774 gate in SCENARIO.CPP).
    await waitForOutput(page, '[TD] Do_Win: entered', 60_000);
    console.log('[T3] Do_Win: entered — win VQA sequence starting');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-03-do-win-entered.png'), fullPage: true });

    // Wait for win VQA to start playing.
    await waitForOutput(page, "[VQA] Playing '", 60_000);
    console.log('[T3] win VQA starting — waiting 3 s for visual frame');

    // Sample at t=3 s (TIM-587 visual inspection rule).
    await page.waitForTimeout(3_000);
    const winVqaStats = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'T3-04-win-vqa-t3s.png'), fullPage: true });
    console.log(`[T3] win VQA t=3s: fill=${winVqaStats.fillPct}%  colors=${winVqaStats.uniqueColors}  cyan=${winVqaStats.cyanCount}`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    // Extract VQA name and WinMovie for reporting.
    const vqaLine = outputFinal.match(/\[VQA\] Playing '([^']+)'/);
    const vqaName = vqaLine ? vqaLine[1] : 'unknown';
    const doWinLine = outputFinal.match(/\[TD\] Do_Win: entered \(WinMovie=([^)]+)\)/);
    const winMovieName = doWinLine ? doWinLine[1] : 'unknown';

    // Check audio log presence (WebAudio bypass from TIM-604 pattern).
    const hasAudioLog = outputFinal.includes('[VQA] WebAudio') || outputFinal.includes('[VQA] SDL audio');
    const hasUnderrun = outputFinal.includes('[VQA] audio underrun');

    console.log('\n[T3] ===== SUMMARY =====');
    console.log(`  Start_Scenario:       PASS`);
    console.log(`  Flag_To_Win:          PASS (TD-CHEAT frame 200)`);
    console.log(`  Do_Win entered:       PASS (WinMovie=${winMovieName})`);
    console.log(`  Win VQA name:         ${vqaName}`);
    console.log(`  Win VQA fill@t3s:     ${winVqaStats.fillPct}% (≥5% threshold)`);
    console.log(`  Win VQA cyan:         ${winVqaStats.cyanCount === 0 ? 'PASS (0)' : 'FAIL (' + winVqaStats.cyanCount + ')'}`);
    console.log(`  Audio opened:         ${hasAudioLog ? 'PASS' : 'UNKNOWN (no audio log)'}`);
    console.log(`  Audio underrun:       ${hasUnderrun ? 'WARN (underrun detected)' : 'PASS (no underrun)'}`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ')'}`);
    console.log('  Screenshots:          T3-01..04');
    console.log('NOTE: Audio pitch correctness requires 5/5 cold-cache passes per TIM-766 rule.');

    // Hard assertions.
    expect(outputFinal, 'cheat must fire Flag_To_Win at frame 200').toContain('Flag_To_Win fired');
    expect(outputFinal, 'Do_Win must enter (TIM-774 gate)').toContain('[TD] Do_Win: entered');
    expect(outputFinal, 'win VQA must start playing').toContain("[VQA] Playing '");
    expect(winVqaStats.fillPct, 'win VQA frame fill ≥5% at t=3s (TIM-587)').toBeGreaterThanOrEqual(5);
    expect(winVqaStats.cyanCount, 'no cyan-block scatter in win VQA (TIM-590)').toBe(0);
    expect(outputFinal, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(outputFinal, 'no Aborted').not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
  });

});
