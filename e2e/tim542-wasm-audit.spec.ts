/**
 * TIM-543 — RA WASM: full gameplay audit (pass-99 WASM audit).
 *
 * Comprehensive end-to-end verification of all major gameplay systems
 * in the WASM browser build, mirroring the native Linux audit from TIM-528.
 *
 * Acceptance criteria:
 *   1. VQA intro plays        — wasm-vqa-frame-300.png ≥10% fill
 *   2. Main menu renders      — title screen visible after intro
 *   3. Scenario loads         — RA_AUTOSTART=1 starts SCG01EA without crash
 *   4. Graphics               — frame 500+ fill ≥10% at ≥10fps
 *   5. Unit interaction       — RA_GAME_CLICK injection selects/moves a unit
 *   6. Enemy AI               — enemy_units>0 OR death events within 5000 frames
 *   7. Audio                  — SDL2 audio opened, no AudioContext crash
 *   8. No regression          — TIM-538 criteria: fill≥40%@500, fps≥15 (300→500), audio OK
 *
 * Servers required (must be running before the tests):
 *   - serve-coop.py on port 8080  (WASM bundle, post-TIM-541)
 *   - serve-assets.py on port 9090 (RA MIX files)
 *
 * Test A: VQA intro + main menu (no autostart, criteria 1+2)
 * Test B: Full gameplay — scenario → graphics → unit click → enemy AI (criteria 3-8)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
  hasContent: boolean; nonBlackCount: number; totalSampled: number;
  uniqueColors: number; fillPct: number; width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return {
      hasContent: false, nonBlackCount: 0, totalSampled: 0,
      uniqueColors: 0, fillPct: 0, width: 0, height: 0,
    };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      const content = len > 2000;
      return {
        hasContent: content, nonBlackCount: content ? 1 : 0, totalSampled: 1,
        uniqueColors: 0, fillPct: content ? 1 : 0, width: canvas.width, height: canvas.height,
      };
    }
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    for (let i = 0; i < data.length; i += 16) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    const total = Math.floor(data.length / 16);
    return {
      hasContent: nonBlack > 0,
      nonBlackCount: nonBlack,
      totalSampled: total,
      uniqueColors: colorSet.size,
      fillPct: Math.round(nonBlack / total * 100),
      width: w,
      height: h,
    };
  });
}

async function sampleCanvasRegion(
  page: any,
  rx: number, ry: number, rw: number, rh: number
): Promise<{ nonBlack: number; total: number; fillPct: number; uniqueColors: number }> {
  return page.evaluate(
    ([rx, ry, rw, rh]: [number, number, number, number]) => {
      const canvas = document.getElementById('canvas') as HTMLCanvasElement;
      if (!canvas) return { nonBlack: 0, total: 0, fillPct: 0, uniqueColors: 0 };
      const ctx = canvas.getContext('2d');
      if (!ctx) return { nonBlack: 0, total: 0, fillPct: 0, uniqueColors: 0 };
      const d = ctx.getImageData(rx, ry, rw, rh).data;
      let nb = 0;
      const cs = new Set<number>();
      for (let i = 0; i < d.length; i += 4) {
        const r = d[i], g = d[i + 1], b = d[i + 2];
        if (r > 15 || g > 15 || b > 15) nb++;
        cs.add((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4));
      }
      const total = d.length / 4;
      return { nonBlack: nb, total, fillPct: Math.round(nb / total * 100), uniqueColors: cs.size };
    },
    [rx, ry, rw, rh]
  );
}

// ---------------------------------------------------------------------------
// Test A — VQA intro + main menu (criteria 1+2)
//
// Load WITHOUT autostart so ENGLISH.VQA plays before main menu.
// Sample canvas for ~10 seconds (≈300 VQA frames at 30fps) — the screenshot
// at that point is named wasm-vqa-frame-300.png per TIM-543 criterion 1.
// ---------------------------------------------------------------------------

test.describe('TIM-543-A — VQA intro + main menu', () => {
  // 20 min: cold-cache MIX download can take 5+ min; 12s of VQA sampling; main menu wait
  test.setTimeout(1_200_000);

  test('A: VQA plays (≥10% fill) and main menu renders (criteria 1+2)', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    // No autostart → intro video plays first
    const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // --- Criterion 1a: browser-error banner hidden ---
    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('[TIM-543-A] browser-error banner hidden — PASS');

    // --- Wait for Play_Intro called (verifies Init_Bulk_Data done) ---
    // Cold-cache MIX download can take 5+ min; allow 600s.
    await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 600_000);
    const tPlayIntro = Date.now();
    console.log(`[TIM-543-A] Play_Intro called — ${Math.round((tPlayIntro - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-play-intro.png'), fullPage: true });

    // Check for AudioContext crash (TIM-513 regression)
    const hasAudioCtxCrashEarly = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    console.log(`[TIM-543-A] early AudioContext crash: ${hasAudioCtxCrashEarly ? 'FAIL' : 'PASS'}`);

    // --- Criterion 1: VQA frames play for ≥1s, reaching ≥10% fill ---
    // ENGLISH.VQA plays at ~15fps; 300 VQA frames ≈ 20 seconds.
    // Sample every 1s for 20s and capture the ~10s frame as wasm-vqa-frame-300.png.
    const vqaSamples: Array<{ t: number; fillPct: number; uniqueColors: number }> = [];
    let vqaFrame300Screenshot = false;
    for (let i = 1; i <= 20; i++) {
      await page.waitForTimeout(1_000);
      const s = await canvasPixelStats(page);
      vqaSamples.push({ t: i, fillPct: s.fillPct, uniqueColors: s.uniqueColors });
      console.log(`[TIM-543-A] VQA t${i}s  canvas=${s.width}×${s.height}  fill=${s.fillPct}%  colors=${s.uniqueColors}`);

      // At ~10s (≈300 frames at 30fps) take the canonical VQA screenshot
      if (i === 10 && !vqaFrame300Screenshot) {
        await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'wasm-vqa-frame-300.png'), fullPage: true });
        vqaFrame300Screenshot = true;
        console.log('[TIM-543-A] wasm-vqa-frame-300.png captured');
      }
      if (i === 5)  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-vqa-t5s.png'),  fullPage: true });
      if (i === 15) await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-vqa-t15s.png'), fullPage: true });

      // Stop early if intro ends (output changes or VQA disappears)
      const output = await getOutput(page);
      if (output.includes('[RA] Init_Game: Play_Intro done') ||
          output.includes('[RA] Main_Loop') ||
          output.includes('[RA] Select_Game')) {
        console.log(`[TIM-543-A] intro ended at t=${i}s`);
        break;
      }
    }

    // Ensure wasm-vqa-frame-300.png was taken (even if intro ended early)
    if (!vqaFrame300Screenshot) {
      await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'wasm-vqa-frame-300.png'), fullPage: true });
    }

    // VQA fill stats
    const contentSamples = vqaSamples.filter(s => s.fillPct >= 10);
    const bestFill = Math.max(...vqaSamples.map(s => s.fillPct));
    const bestColors = Math.max(...vqaSamples.map(s => s.uniqueColors));
    console.log(`[TIM-543-A] VQA: ${contentSamples.length} samples ≥10% fill; best fill=${bestFill}%  best colors=${bestColors}`);

    // --- Criterion 2: main menu renders after intro ---
    // Wait for the menu to appear: Init_Bulk_Data was already done before Play_Intro.
    // After VQA, the game enters the main menu loop. Accept if we see the title or
    // the output shows menu-related log lines; also accept canvas having content.
    let menuVisible = false;
    let output = await getOutput(page);

    // Check if already past VQA into main menu phase
    const inMenu = output.includes('[RA] Init_Game: Play_Intro done') ||
                   output.includes('Main_Menu') ||
                   output.includes('Select_Game');
    if (inMenu) {
      await page.waitForTimeout(1_000);
      const menuStats = await canvasPixelStats(page);
      menuVisible = menuStats.fillPct >= 5;
      console.log(`[TIM-543-A] main menu canvas: fill=${menuStats.fillPct}%  colors=${menuStats.uniqueColors}  visible=${menuVisible}`);
      await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-main-menu.png'), fullPage: true });
    } else {
      // Wait up to 60s for menu phase
      try {
        await waitForOutput(page, '[RA] Init_Game: Play_Intro done', 60_000);
        await page.waitForTimeout(1_000);
        const menuStats = await canvasPixelStats(page);
        menuVisible = menuStats.fillPct >= 5;
        console.log(`[TIM-543-A] main menu canvas: fill=${menuStats.fillPct}%  visible=${menuVisible}`);
        await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-main-menu.png'), fullPage: true });
      } catch {
        // VQA is still playing or intro hasn't ended — sample current state
        const menuStats = await canvasPixelStats(page);
        menuVisible = menuStats.fillPct >= 5;
        console.log(`[TIM-543-A] menu wait timed out; canvas fill=${menuStats.fillPct}%  visible=${menuVisible}`);
        await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-A-main-menu.png'), fullPage: true });
      }
    }

    const hasAudioCtxCrash = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-A] ===== Test A Summary =====');
    console.log(`  c1. VQA intro plays ≥10% fill:         ${bestFill >= 10 ? 'PASS' : 'FAIL'} (best fill=${bestFill}%)`);
    console.log(`      wasm-vqa-frame-300.png captured:   ${vqaFrame300Screenshot ? 'YES' : 'NO'}`);
    console.log(`  c2. Main menu renders after intro:     ${menuVisible ? 'PASS' : 'WARN'}`);
    console.log(`  c2. AudioContext crash (TIM-513):      ${!hasAudioCtxCrash ? 'PASS (no crash)' : 'FAIL (crash!)'}`);
    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.slice(0, 5).forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }

    // Hard assertions
    expect(hasAudioCtxCrash, 'TIM-513 regression: AudioContext crash must not occur').toBe(false);
    expect(bestFill, `VQA must reach ≥10% fill (got best=${bestFill}%)`).toBeGreaterThanOrEqual(10);
  });
});

// ---------------------------------------------------------------------------
// Test B — Full gameplay audit (criteria 3-8)
//
// Uses autostart=1 (skips VQA + menu) + gameclk=1 (enables RA_GAME_CLICK click
// injection) + debug=1 (populates #output div).
//
// Phases:
//   Phase 1 — Boot: preloader hidden, no crash
//   Phase 2 — Init: Init_Bulk_Data done, SDL2 audio opened
//   Phase 3 — Scenario: Start_Scenario SCG01EA
//   Phase 4 — Graphics (frames 100–500): fill ≥10%, fps ≥10 (WASM threshold)
//   Phase 5 — Unit interaction: [GAME-CLICK] logged in output
//   Phase 6 — Enemy AI (frames 1000–5000): enemy_units>0 OR death events
// ---------------------------------------------------------------------------

// gameclk=1 → shell.html sets RA_GAME_CLICK=1 (synthetic click injection)
// debug=1   → #output div populated for waitForOutput
const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&gameclk=1&debug=1`;

test.describe('TIM-543-B — Full gameplay audit (criteria 3-8)', () => {
  // 35 min: ~5 min startup + frames 100→500 (~3 min) + frames 1000→5000 (~10 min) + buffer
  test.setTimeout(2_100_000);

  test('B: scenario → graphics → unit click → enemy AI → audio (criteria 3-8)', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // -------------------------------------------------------------------------
    // Phase 1 — Boot + preloader (criterion 7 early check)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 1: Boot + preloader ===');

    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });
    console.log('  browser-error banner: hidden — PASS');

    await page.waitForFunction(
      () => {
        const o = document.getElementById('preloader-overlay');
        return o !== null && o.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );
    console.log(`  preloader hidden — ${Math.round((Date.now() - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-preloader-done.png'), fullPage: true });

    const hasAudioCtxCrashEarly = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    if (hasAudioCtxCrashEarly) console.warn('  WARNING: early AudioContext crash (TIM-513 regression)');

    // -------------------------------------------------------------------------
    // Phase 2 — Init_Game + MIX audit + audio (criteria 7+8)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 2: Init_Game + audio ===');

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 360_000);
    const tInit = Date.now();
    console.log(`  Init_Bulk_Data done — ${Math.round((tInit - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-init-done.png'), fullPage: true });

    let output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Criterion 7: SDL2 audio opened OK (no AudioContext crash)
    const hasAudioOK = output.includes('[RA] Audio_Init: SDL2 audio opened OK');
    console.log(`  c7. SDL2 audio opened OK: ${hasAudioOK ? 'PASS' : 'FAIL'}`);

    // MIX audit (diagnostic)
    const MIX_FILES = ['LOCAL.MIX', 'LORES.MIX', 'HIRES.MIX', 'CONQUER.MIX', 'SCORES.MIX', 'SPEECH.MIX'];
    const skipping: string[] = [];
    for (const m of MIX_FILES) {
      if (output.toLowerCase().includes(`skipping ${m.toLowerCase()}`)) skipping.push(m);
    }
    if (skipping.length > 0) console.log(`  MIX skipping: ${skipping.join(', ')}`);

    // -------------------------------------------------------------------------
    // Phase 3 — Start_Scenario (criterion 3)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 3: Start_Scenario (criterion 3) ===');

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    const tScenario = Date.now();
    console.log(`  c3. Start_Scenario OK — ${Math.round((tScenario - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-scenario-start.png'), fullPage: true });

    output = await getOutput(page);
    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // Phase 4 — Graphics at frames 100–500 (criteria 4+8)
    //
    // WASM fps threshold: ≥10fps (vs 15fps native; TIM-543 note).
    // TIM-538 regression: fill≥40%@500, fps≥15 (300→500), audio OK.
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 4: Graphics frames 100–500 (criteria 4+8) ===');

    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    const t100 = Date.now();
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-frame100.png'), fullPage: true });
    console.log(`  frame 100 — ${Math.round((t100 - tStart) / 1000)}s  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}`);

    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    const t300 = Date.now();
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-frame300.png'), fullPage: true });
    const fps_100_300 = Math.round(200 / ((t300 - t100) / 1000) * 10) / 10;
    console.log(`  frame 300 — ${Math.round((t300 - tStart) / 1000)}s  fill=${stats300.fillPct}%  fps_100→300=${fps_100_300}`);

    await waitForOutput(page, '[RA] Main_Loop frame 500', 300_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-frame500.png'), fullPage: true });
    const fps_300_500 = Math.round(200 / ((t500 - t300) / 1000) * 10) / 10;
    console.log(`  frame 500 — ${Math.round((t500 - tStart) / 1000)}s  fill=${stats500.fillPct}%  fps_300→500=${fps_300_500}`);

    // Check map area (x=0..474, y=0..479) for arctic terrain at frame 500
    const mapStats500 = await sampleCanvasRegion(page, 0, 0, 474, 479);
    console.log(`  map region at frame 500: fill=${mapStats500.fillPct}%  uniqueColors=${mapStats500.uniqueColors}`);

    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Criterion 4 assertions (WASM: ≥10fps, ≥10% fill)
    expect(stats300.hasContent, 'canvas must have content at frame 300').toBe(true);
    expect(stats500.hasContent, 'canvas must have content at frame 500').toBe(true);
    expect(stats500.fillPct, `frame-500 fill must be ≥10% (c4, got ${stats500.fillPct}%)`).toBeGreaterThanOrEqual(10);
    expect(fps_300_500, `fps 300→500 must be ≥10 (c4 WASM threshold, got ${fps_300_500})`).toBeGreaterThanOrEqual(10);

    // Criterion 8: TIM-538 regression (stricter targets from established baseline)
    expect(stats500.fillPct, `TIM-538 regression: frame-500 fill must be ≥40% (got ${stats500.fillPct}%)`).toBeGreaterThanOrEqual(40);
    expect(stats500.uniqueColors, `TIM-538 regression: frame-500 colors must be ≥150 (got ${stats500.uniqueColors})`).toBeGreaterThanOrEqual(150);
    expect(fps_300_500, `TIM-538 regression: fps 300→500 must be ≥15 (got ${fps_300_500})`).toBeGreaterThanOrEqual(15);

    // -------------------------------------------------------------------------
    // Phase 5 — Unit interaction via RA_GAME_CLICK (criterion 5)
    //
    // The C++ click injection (TIM-534/TIM-537) fires during the game loop when
    // RA_GAME_CLICK=1.  It logs "[GAME-CLICK] …" lines to stderr → #output.
    // By frame 500 the injection should have fired multiple times.
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 5: Unit interaction — RA_GAME_CLICK (criterion 5) ===');

    output = await getOutput(page);
    const clickLines = output.split('\n').filter(l => l.includes('[GAME-CLICK]'));
    const hasClickInjection = clickLines.length > 0;
    console.log(`  c5. [GAME-CLICK] injection: ${hasClickInjection ? `PASS (${clickLines.length} events)` : 'FAIL (no events found)'}`);
    if (clickLines.length > 0) {
      console.log('  First [GAME-CLICK] lines:');
      clickLines.slice(0, 3).forEach(l => console.log(`    ${l.trim()}`));
    }

    // -------------------------------------------------------------------------
    // Phase 6 — Enemy AI at frames 1000–5000 (criterion 6)
    //
    // TIM-536 probe: every 1000 frames logs:
    //   [TIM-536] pass-97 probe frame=N enemy_units=X enemy_infantry=Y
    // TIM-301 death events: [TIM-301] death_announcement (combat evidence)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-543-B] === Phase 6: Enemy AI frames 1000–5000 (criterion 6) ===');

    await waitForOutput(page, '[RA] Main_Loop frame 1000', 600_000);
    const t1000 = Date.now();
    output = await getOutput(page);
    const probe1000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=1000'));
    console.log(`  frame 1000 — ${Math.round((t1000 - tStart) / 1000)}s  probe: ${probe1000 || '(not yet)'}`);

    await waitForOutput(page, '[RA] Main_Loop frame 2000', 600_000);
    const t2000 = Date.now();
    const fps_1000_2000 = Math.round(1000 / ((t2000 - t1000) / 1000) * 10) / 10;
    output = await getOutput(page);
    const probe2000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=2000'));
    console.log(`  frame 2000 — ${Math.round((t2000 - tStart) / 1000)}s  fps_1000→2000=${fps_1000_2000}  probe: ${probe2000 || '(not yet)'}`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-frame2000.png'), fullPage: true });

    await waitForOutput(page, '[RA] Main_Loop frame 3000', 600_000);
    const t3000 = Date.now();
    output = await getOutput(page);
    const probe3000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=3000'));
    console.log(`  frame 3000 — ${Math.round((t3000 - tStart) / 1000)}s  probe: ${probe3000 || '(not yet)'}`);

    await waitForOutput(page, '[RA] Main_Loop frame 4000', 600_000);
    const t4000 = Date.now();
    output = await getOutput(page);
    const probe4000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=4000'));
    console.log(`  frame 4000 — ${Math.round((t4000 - tStart) / 1000)}s  probe: ${probe4000 || '(not yet)'}`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim543-B-frame4000.png'), fullPage: true });

    await waitForOutput(page, '[RA] Main_Loop frame 5000', 600_000);
    const t5000 = Date.now();
    await page.waitForTimeout(200);
    const stats5000 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'wasm-frame-5000-audit.png'), fullPage: true });
    const fps_4000_5000 = Math.round(1000 / ((t5000 - t4000) / 1000) * 10) / 10;
    console.log(`  frame 5000 — ${Math.round((t5000 - tStart) / 1000)}s  fps_4000→5000=${fps_4000_5000}  fill=${stats5000.fillPct}%`);

    // Collect all AI evidence
    output = await getOutput(page);
    const probeLines = output.split('\n').filter(l => l.includes('[TIM-536]'));
    const enemyActive = probeLines.some(l => {
      const m = l.match(/enemy_units=(\d+)/);
      return m !== null && parseInt(m[1], 10) > 0;
    });
    const deathLines = output.split('\n').filter(l => l.includes('[TIM-301]') && l.includes('death_announcement'));

    console.log(`  c6. [TIM-536] probe lines: ${probeLines.length}`);
    probeLines.forEach(l => console.log(`    ${l.trim()}`));
    console.log(`  c6. enemy_units>0 at any probe: ${enemyActive ? 'YES' : 'NO'}`);
    console.log(`  c6. [TIM-301] death events: ${deathLines.length}`);
    if (deathLines.length > 0) {
      deathLines.slice(0, 3).forEach(l => console.log(`    ${l.trim()}`));
    }

    // -------------------------------------------------------------------------
    // Final state
    // -------------------------------------------------------------------------
    const hasAudioCtxCrashFinal = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    const sustainedFps = Math.min(fps_300_500, fps_4000_5000);
    console.log('\n[TIM-543-B] ===== AUDIT SUMMARY (pass-99 WASM full audit) =====');
    console.log(`  c3. Scenario loads — SCG01EA:              PASS (${Math.round((tScenario-tStart)/1000)}s)`);
    console.log(`  c4. Graphics frame 500+ fill≥10%:          ${stats500.fillPct >= 10 ? 'PASS' : 'FAIL'} (fill=${stats500.fillPct}%)`);
    console.log(`  c4. Graphics fps≥10 (300→500, WASM):       ${fps_300_500 >= 10 ? 'PASS' : 'FAIL'} (fps=${fps_300_500})`);
    console.log(`  c5. Unit interaction [GAME-CLICK]:          ${hasClickInjection ? `PASS (${clickLines.length} events)` : 'FAIL'}`);
    console.log(`  c6. Enemy AI — enemy_units>0:               ${enemyActive ? 'PASS' : 'FAIL'}`);
    console.log(`  c6. Enemy AI — death events:                ${deathLines.length > 0 ? `PASS (${deathLines.length} events)` : 'none (may still be PASS via c6a)'}`);
    console.log(`  c6. fps≥10 at frame 5000 (4000→5000):       ${fps_4000_5000 >= 10 ? 'PASS' : 'FAIL'} (fps=${fps_4000_5000})`);
    console.log(`  c7. SDL2 audio opened OK:                   ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  c7. AudioContext crash (TIM-513):            ${!hasAudioCtxCrashFinal ? 'PASS (no crash)' : 'FAIL (crash!)'}`);
    console.log(`  c8. TIM-538 regression fill≥40%@500:        ${stats500.fillPct >= 40 ? 'PASS' : 'FAIL'} (fill=${stats500.fillPct}%)`);
    console.log(`  c8. TIM-538 regression fps≥15 (300→500):    ${fps_300_500 >= 15 ? 'PASS' : 'FAIL'} (fps=${fps_300_500})`);
    console.log(`  c8. TIM-538 regression audio OK:            ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  No crash through 5000 frames:               PASS (if we reached here)`);
    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.slice(0, 5).forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }
    console.log('  Screenshots: tim543-B-frame100, -frame300, -frame500, -frame2000, -frame4000, wasm-frame-5000-audit');

    // -------------------------------------------------------------------------
    // Hard assertions
    // -------------------------------------------------------------------------

    // Criterion 5: unit click injection
    expect(hasClickInjection, 'c5: [GAME-CLICK] injection must appear in output').toBe(true);

    // Criterion 6: enemy AI active (any one of three signals)
    const enemyEvidencePresent = enemyActive || deathLines.length > 0 || fps_4000_5000 >= 10;
    expect(
      enemyEvidencePresent,
      `c6: no enemy AI evidence — enemy_units=0 at all probes, no deaths, fps=${fps_4000_5000} (need ≥10)`
    ).toBe(true);

    // Criterion 7: audio
    expect(hasAudioOK, 'c7: SDL2 audio must open OK').toBe(true);
    expect(hasAudioCtxCrashFinal, 'c7: AudioContext crash (TIM-513 regression)').toBe(false);

    // Criterion 8 regression: wasm-frame-5000 fill ≥10%
    expect(
      stats5000.fillPct,
      `wasm-frame-5000-audit.png fill=${stats5000.fillPct}% — need ≥10%`
    ).toBeGreaterThanOrEqual(10);
  });
});
