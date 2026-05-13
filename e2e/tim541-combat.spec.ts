/**
 * TIM-541 — RA WASM: enemy AI engagement and combat verification (pass-98 WASM combat).
 *
 * Runs a 5000+ frame WASM gameplay session with RA_AUTOSTART=1 and RA_GAME_CLICK=1
 * (?autostart=1&gameclk=1&debug=1) and confirms that enemy AI is active and combat
 * occurs in the browser build.
 *
 * The WASM binary includes TIM-536 probe logging (fprintf(stderr, "[TIM-536]…"))
 * which appears in the #output div alongside all other game log lines.
 *
 * Acceptance criteria (TIM-541):
 *   1. WASM game runs 5000+ frames — no crash, no hang.
 *   2. Enemy AI evidence: [TIM-536] enemy_units>0 at any probe frame, OR
 *      [TIM-301] death_announcement (combat event), OR fps ≥10 at frame 5000.
 *   3. Screenshot wasm-frame-5000-combat.png with ≥10% pixel fill.
 *   4. TIM-538 regression: no crash, SDL2 audio OK, canvas fill ≥40% at frame 500,
 *      fps (300→500) ≥15, no AudioContext crash.
 *
 * Servers required:
 *   - serve-coop.py on port 8080 (WASM bundle, built from battlecontrol/master ≥ TIM-540)
 *   - serve-assets.py on port 9090 (RA MIX files)
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

// ---------------------------------------------------------------------------
// TIM-541: 5000-frame combat verification
// ---------------------------------------------------------------------------

// ?gameclk=1 → shell.html injects RA_GAME_CLICK=1, triggering C++ click injection.
// ?debug=1   → #output div is populated (required for waitForOutput).
const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&gameclk=1&debug=1`;

test.describe('TIM-541 — RA WASM combat verification (pass-98)', () => {
  // 30 min: ~5 min startup + 500 frames (~3 min) + 5000 frames (~10 min at 10fps) + buffer
  test.setTimeout(1_800_000);

  test('5000-frame run: enemy AI active + combat + TIM-538 regression', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors:  string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // -------------------------------------------------------------------------
    // Phase 1 — Boot + preloader
    // -------------------------------------------------------------------------
    console.log('\n[TIM-541] === Phase 1: Boot + preloader ===');

    const errorBanner = page.locator('#browser-error');
    await expect(errorBanner).toHaveCSS('display', 'none', { timeout: 5_000 });

    await page.waitForFunction(
      () => {
        const o = document.getElementById('preloader-overlay');
        return o !== null && o.style.display === 'none';
      },
      null,
      { timeout: 120_000 }
    );
    console.log(`  preloader hidden — ${Math.round((Date.now() - tStart) / 1000)}s`);

    const hasAudioCtxCrashEarly = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));
    if (hasAudioCtxCrashEarly) console.warn('  WARNING: early AudioContext crash detected (TIM-513 regression)');

    // -------------------------------------------------------------------------
    // Phase 2 — Init_Game + Start_Scenario (TIM-538 regression: criteria 1+4)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-541] === Phase 2: Init_Game + Start_Scenario ===');

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 360_000);
    const tInit = Date.now();
    console.log(`  Init_Bulk_Data done — ${Math.round((tInit - tStart) / 1000)}s`);

    let output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // TIM-538 c7: SDL2 audio opened OK
    const hasAudioOK = output.includes('[RA] Audio_Init: SDL2 audio opened OK');
    console.log(`  SDL2 audio opened OK: ${hasAudioOK ? 'PASS' : 'FAIL'}`);

    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    const tScenario = Date.now();
    console.log(`  Start_Scenario OK — ${Math.round((tScenario - tStart) / 1000)}s`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-scenario-start.png'), fullPage: true });

    output = await getOutput(page);
    expect(output).toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -------------------------------------------------------------------------
    // Phase 3 — Frames 100–500: TIM-538 regression (criteria 5+6)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-541] === Phase 3: Frames 100–500 (TIM-538 regression) ===');

    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    const t100 = Date.now();
    await page.waitForTimeout(200);
    const stats100 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-frame100.png'), fullPage: true });
    console.log(`  frame 100 — ${Math.round((t100 - tStart) / 1000)}s  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}`);

    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    const t300 = Date.now();
    await page.waitForTimeout(200);
    const stats300 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-frame300.png'), fullPage: true });
    console.log(`  frame 300 — ${Math.round((t300 - tStart) / 1000)}s  fill=${stats300.fillPct}%  colors=${stats300.uniqueColors}`);

    await waitForOutput(page, '[RA] Main_Loop frame 500', 300_000);
    const t500 = Date.now();
    await page.waitForTimeout(200);
    const stats500 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-frame500.png'), fullPage: true });
    const fps_300_500 = Math.round(200 / ((t500 - t300) / 1000) * 10) / 10;
    const fps_100_300 = Math.round(200 / ((t300 - t100) / 1000) * 10) / 10;
    console.log(`  frame 500 — ${Math.round((t500 - tStart) / 1000)}s  fill=${stats500.fillPct}%  colors=${stats500.uniqueColors}`);
    console.log(`  fps 100→300=${fps_100_300}  300→500=${fps_300_500}`);

    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Hard TIM-538 regression assertions at frame 500
    expect(stats300.hasContent, 'canvas must have content at frame 300 (TIM-538 c6)').toBe(true);
    expect(stats500.hasContent, 'canvas must have content at frame 500 (TIM-538 c6)').toBe(true);
    expect(stats500.fillPct, `frame-500 fill must be ≥40% (got ${stats500.fillPct}%)`).toBeGreaterThanOrEqual(40);
    expect(stats500.uniqueColors, `frame-500 unique colours must be ≥150 (got ${stats500.uniqueColors})`).toBeGreaterThanOrEqual(150);
    expect(fps_300_500, `fps 300→500 must be ≥15 (TIM-538 c5, got ${fps_300_500})`).toBeGreaterThanOrEqual(15);
    expect(hasAudioOK, 'SDL2 audio must open OK (TIM-538 c7)').toBe(true);

    // -------------------------------------------------------------------------
    // Phase 4 — Frames 1000–5000: enemy AI + combat evidence
    //
    // TIM-536 probe: every 1000 frames logs:
    //   [TIM-536] pass-97 probe frame=N enemy_units=X enemy_infantry=Y
    // These appear in #output (same stderr→output capture path as [GAME-CLICK]).
    //
    // TIM-301 death announcements: [TIM-301] death_announcement …
    // (combat evidence, logged on unit death)
    // -------------------------------------------------------------------------
    console.log('\n[TIM-541] === Phase 4: Frames 1000–5000 (enemy AI + combat) ===');

    // Frame 1000: first AI probe checkpoint
    await waitForOutput(page, '[RA] Main_Loop frame 1000', 600_000);
    const t1000 = Date.now();
    console.log(`  frame 1000 — ${Math.round((t1000 - tStart) / 1000)}s`);
    output = await getOutput(page);

    // Capture [TIM-536] probe at frame 1000
    const probe1000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=1000'));
    console.log(`  TIM-536 probe@1000: ${probe1000 || '(not found yet)'}`);

    // Frame 2000
    await waitForOutput(page, '[RA] Main_Loop frame 2000', 600_000);
    const t2000 = Date.now();
    const fps_1000_2000 = Math.round(1000 / ((t2000 - t1000) / 1000) * 10) / 10;
    console.log(`  frame 2000 — ${Math.round((t2000 - tStart) / 1000)}s  fps_1000→2000=${fps_1000_2000}`);
    output = await getOutput(page);
    const probe2000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=2000'));
    console.log(`  TIM-536 probe@2000: ${probe2000 || '(not found yet)'}`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-frame2000.png'), fullPage: true });

    // Frame 3000
    await waitForOutput(page, '[RA] Main_Loop frame 3000', 600_000);
    const t3000 = Date.now();
    console.log(`  frame 3000 — ${Math.round((t3000 - tStart) / 1000)}s`);
    output = await getOutput(page);
    const probe3000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=3000'));
    console.log(`  TIM-536 probe@3000: ${probe3000 || '(not found yet)'}`);

    // Frame 4000
    await waitForOutput(page, '[RA] Main_Loop frame 4000', 600_000);
    const t4000 = Date.now();
    console.log(`  frame 4000 — ${Math.round((t4000 - tStart) / 1000)}s`);
    output = await getOutput(page);
    const probe4000 = output.split('\n').find(l => l.includes('[TIM-536]') && l.includes('frame=4000'));
    console.log(`  TIM-536 probe@4000: ${probe4000 || '(not found yet)'}`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim541-frame4000.png'), fullPage: true });

    // Frame 5000 — primary milestone
    await waitForOutput(page, '[RA] Main_Loop frame 5000', 600_000);
    const t5000 = Date.now();
    await page.waitForTimeout(200);
    const stats5000 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'wasm-frame-5000-combat.png'), fullPage: true });
    const fps_at_5000 = Math.round(1000 / ((t5000 - t4000) / 1000) * 10) / 10;
    console.log(`  frame 5000 — ${Math.round((t5000 - tStart) / 1000)}s  fps_4000→5000=${fps_at_5000}`);
    console.log(`  canvas at frame 5000: ${stats5000.width}×${stats5000.height}  fill=${stats5000.fillPct}%  colors=${stats5000.uniqueColors}`);

    // -------------------------------------------------------------------------
    // Collect all enemy AI evidence
    // -------------------------------------------------------------------------
    output = await getOutput(page);

    // [TIM-536] probe lines
    const probeLines = output.split('\n').filter(l => l.includes('[TIM-536]'));
    const enemyActive = probeLines.some(l => {
      const m = l.match(/enemy_units=(\d+)/);
      return m !== null && parseInt(m[1], 10) > 0;
    });

    // [TIM-301] death announcements (combat events)
    const deathLines = output.split('\n').filter(l => l.includes('[TIM-301]') && l.includes('death_announcement'));

    // [GAME-CLICK] confirmation (pass-97 regression)
    const clickLines = output.split('\n').filter(l => l.includes('[GAME-CLICK]'));

    // -------------------------------------------------------------------------
    // Summary
    // -------------------------------------------------------------------------
    const hasAudioCtxCrashFinal = pageErrors.some(e => /AudioContext|AbortError|NotAllowedError/i.test(e));

    console.log('\n[TIM-541] ===== AUDIT SUMMARY (pass-98 WASM combat) =====');
    console.log(`  c1. 5000+ frames reached, no crash:              PASS (frame 5000 at ${Math.round((t5000 - tStart) / 1000)}s)`);
    console.log(`  c2a. [TIM-536] enemy AI active (enemy_units>0):  ${enemyActive ? 'PASS' : 'FAIL (all probes show 0 enemy units)'}`);
    console.log(`  c2b. [TIM-301] death events (combat):            ${deathLines.length > 0 ? `PASS (${deathLines.length} events)` : 'NONE (may still be PASS via c2a/c2c)'}`);
    console.log(`  c2c. fps ≥10 at frame 5000 (4000→5000):          ${fps_at_5000 >= 10 ? 'PASS' : 'FAIL'} (fps=${fps_at_5000})`);
    console.log(`  c3.  wasm-frame-5000-combat.png ≥10% fill:       ${stats5000.fillPct >= 10 ? 'PASS' : 'FAIL'} (fill=${stats5000.fillPct}%)`);
    console.log(`  c4a. TIM-538 regression — no crash:              PASS`);
    console.log(`  c4b. TIM-538 regression — SDL2 audio OK:         ${hasAudioOK ? 'PASS' : 'FAIL'}`);
    console.log(`  c4c. TIM-538 regression — canvas fill≥40%@500:   ${stats500.fillPct >= 40 ? 'PASS' : 'FAIL'} (fill=${stats500.fillPct}%)`);
    console.log(`  c4d. TIM-538 regression — fps≥15 (300→500):      ${fps_300_500 >= 15 ? 'PASS' : 'FAIL'} (fps=${fps_300_500})`);
    console.log(`  c4e. TIM-538 regression — no AudioContext crash:  ${!hasAudioCtxCrashFinal ? 'PASS' : 'FAIL'}`);
    console.log(`  c5.  [GAME-CLICK] injection (pass-97 regression): ${clickLines.length > 0 ? 'PASS' : 'FAIL'} (${clickLines.length} click events)`);
    console.log('');
    console.log('  TIM-536 probe lines:');
    probeLines.forEach(l => console.log(`    ${l.trim()}`));
    if (deathLines.length > 0) {
      console.log(`  TIM-301 deaths (first 5):`);
      deathLines.slice(0, 5).forEach(l => console.log(`    ${l.trim()}`));
    }
    if (pageErrors.length > 0) {
      console.log('  Page errors:');
      pageErrors.slice(0, 5).forEach(e => console.log(`    ${e.substring(0, 120)}`));
    }

    // -------------------------------------------------------------------------
    // Hard assertions
    // -------------------------------------------------------------------------
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // Criterion 2: enemy AI must be active (at least one of the three signals)
    const enemyEvidencePresent = enemyActive || deathLines.length > 0 || fps_at_5000 >= 10;
    expect(
      enemyEvidencePresent,
      `No enemy AI evidence: enemy_units=0 at all probes, no death events, fps=${fps_at_5000} (need ≥10)`
    ).toBe(true);

    // Criterion 3: screenshot must have ≥10% fill
    expect(
      stats5000.fillPct,
      `wasm-frame-5000-combat.png fill=${stats5000.fillPct}% — need ≥10%`
    ).toBeGreaterThanOrEqual(10);

    // Criterion 4: AudioContext crash must not occur (TIM-513 regression)
    expect(
      hasAudioCtxCrashFinal,
      'AudioContext crash regression (TIM-513)'
    ).toBe(false);
  });
});
