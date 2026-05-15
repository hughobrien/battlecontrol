/**
 * TIM-755 — TD WASM: real-click GDI L1 mission start (no ?autostart=1).
 *
 * Canonical regression guard for the TD WASM input → mission-start pipeline.
 * Covers the full player path: main menu → real "Start New Game" click →
 * Choose_Side (hardcoded GDI, returns immediately in the WASM build) →
 * Start_Scenario(SCG01EA) → 200 game frames rendered.
 *
 * No ?autostart=1 URL param — exercises the real menu navigation path.
 * Mirrors what TIM-672 did for RA WASM.
 *
 * Servers required (started externally before this spec):
 *   - serve-coop.py  on port 8082 (WASM bundle from build-wasm/)
 *   - serve-assets.py on port 9091 (TD MIX files from CD1/)
 *
 * URL: http://localhost:8082/td.html?src=http://localhost:9091/&debug=1
 *
 * Acceptance criteria (TIM-755):
 *   1. Assets load — preloader-overlay hides, no browser-error banner
 *   2. Main menu reached — [TD] Main_Menu: gadgets up
 *   3. Real Playwright click at (321, 59) triggers "Start New Game"
 *   4. Choose_Side() auto-selects GDI (hardcoded in WASM build — no dialog shown)
 *   5. Start_Scenario(SCG01EA) fires — logged in #output
 *   6. Frame 200+ reached without crash
 *   7. Canvas fill ≥ 20% at frame 200
 *   8. No uncaught JS errors
 *
 * Button layout (canvas 640×480, NEWMENU, from T3 / TIM-696):
 *   D_START_X=196, D_START_W=250 → center X = 196 + 125 = 321
 *   starty=50, ystep=30, H=18   → center Y = 50 + 9 = 59
 *   Start New Game: (321, 59)
 *
 * Note: INTRO.CPP Choose_Side() in the WASM build immediately sets
 *   Whom = HOUSE_GOOD; ScenPlayer = SCEN_PLAYER_GDI; return;
 * No interactive GDI/NOD dialog is shown — the mission starts directly.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8082/td.html';
const ASSET_URL       = 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

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

async function canvasPixelStats(page: any): Promise<{
  fillPct: number; uniqueColors: number; hasContent: boolean; width: number; height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement | null;
    if (!canvas) return { fillPct: 0, uniqueColors: 0, hasContent: false, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { fillPct: 0, uniqueColors: 0, hasContent: len > 2000, width: canvas.width, height: canvas.height };
    }
    const w = canvas.width, h = canvas.height;
    const d = ctx.getImageData(0, 0, w, h).data;
    let nb = 0;
    const cs = new Set<number>();
    for (let i = 0; i < d.length; i += 16) {
      const r = d[i], g = d[i + 1], b = d[i + 2];
      if (r > 15 || g > 15 || b > 15) nb++;
      cs.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    const total = Math.floor(d.length / 16);
    return {
      fillPct: Math.round(nb / total * 100),
      uniqueColors: cs.size,
      hasContent: nb > 0,
      width: w,
      height: h,
    };
  });
}

// ---------------------------------------------------------------------------
// Main test — TD WASM real-click GDI L1 mission start (TIM-755)
// ---------------------------------------------------------------------------

test.describe('TIM-755 — TD WASM real-click GDI L1 mission start (no autostart)', () => {
  test.setTimeout(300_000);  // 5 min: ~60s asset load + ~20s game boot + ~20s to frame 200

  const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

  test('Start New Game click → Choose_Side GDI → Start_Scenario OK → frame 200 ≥20% fill', async ({ page }) => {
    const consoleLogs: string[] = [];
    const pageErrors: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => pageErrors.push(err.message));

    const tStart = Date.now();
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // --- Phase 1: assets load ---
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
    console.log(`[TIM-755] preloader hidden — MIX assets mounted (${Math.round((Date.now() - tStart) / 1000)}s)`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim755-01-preloader-hidden.png'), fullPage: true });

    // --- Phase 2: main menu ready ---
    // [TD] Main_Menu: gadgets up — logged from TIBERIANDAWN/MENUS.CPP just before
    // the main gadget loop starts.  Only fires once per menu entry.
    await waitForOutput(page, '[TD] Main_Menu: gadgets up', 120_000);
    console.log(`[TIM-755] main menu ready (${Math.round((Date.now() - tStart) / 1000)}s)`);

    // Poll until title screen has rendered at least some pixels.
    let fillBefore = 0;
    await expect.poll(async () => {
      fillBefore = await canvasFillPct(page);
      return fillBefore;
    }, { timeout: 10_000, intervals: [200, 500, 1_000] }).toBeGreaterThan(0);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim755-02-menu-ready.png'), fullPage: true });
    console.log(`[TIM-755] canvas fill before click: ${fillBefore}%`);

    // --- Phase 3: click "Start New Game" at (321, 59) ---
    // SeenBuff coordinates match canvas coordinates (both 640×480, 1:1 mapping).
    // D_START_X=196, D_START_W=250 → center X=321; starty=50, H=18 → center Y=59.
    // After this click, Choose_Side() immediately returns with GDI selected —
    // no interactive dialog, no VQA to skip.
    await page.locator('#canvas').click({ position: { x: 321, y: 59 } });
    console.log('[TIM-755] clicked Start New Game at (321, 59)');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim755-03-start-new-game-click.png'), fullPage: true });

    // --- Phase 4: Start_Scenario fires (GDI auto-selected, game starting) ---
    // [TD INIT] calling Start_Scenario(SCG01EA) appears after Choose_Side() returns
    // and the main Select_Game loop exits with process=false.
    await waitForOutput(page, '[TD INIT] calling Start_Scenario', 60_000);
    console.log(`[TIM-755] Start_Scenario called — GDI L1 starting (${Math.round((Date.now() - tStart) / 1000)}s)`);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim755-04-start-scenario.png'), fullPage: true });

    let output = await getOutput(page);
    expect(output, 'SCG01EA must appear in output').toContain('SCG01EA');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // --- Phase 5: frame 200 ---
    // [TD] Main_Loop logs at frames 1–15 and every 100th frame.
    await waitForOutput(page, '[TD] Main_Loop frame 200', 120_000);
    // Poll until canvas has non-black content — the log fires before the SDL present
    // call, so the canvas update may lag by one vsync.
    await expect.poll(() => canvasFillPct(page), { timeout: 5_000, intervals: [100, 200, 500] }).toBeGreaterThan(0);
    console.log(`[TIM-755] frame 200 reached (${Math.round((Date.now() - tStart) / 1000)}s)`);

    const stats200 = await canvasPixelStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim755-05-frame-200.png'), fullPage: true });
    console.log(`[TIM-755] frame 200 canvas: ${stats200.width}×${stats200.height}  fill=${stats200.fillPct}%  colors=${stats200.uniqueColors}  hasContent=${stats200.hasContent}`);

    output = await getOutput(page);
    const noPageErrors = pageErrors.length === 0;

    // --- Summary ---
    console.log('\n[TIM-755] ===== SUMMARY =====');
    console.log(`  1. Assets load:          PASS`);
    console.log(`  2. Main menu ready:      PASS`);
    console.log(`  3. Start New Game click: PASS`);
    console.log(`  4. Choose_Side GDI:      PASS (auto-selected, no dialog)`);
    console.log(`  5. Start_Scenario OK:    PASS`);
    console.log(`  6. Frame 200 reached:    PASS (${Math.round((Date.now() - tStart) / 1000)}s total)`);
    console.log(`  7. Canvas fill@f200:     ${stats200.fillPct}% (threshold ≥20%)`);
    console.log(`  8. No page errors:       ${noPageErrors ? 'PASS' : 'FAIL (' + pageErrors.length + ' errors)'}`);
    if (!noPageErrors) pageErrors.forEach(e => console.log(`     ${e}`));
    console.log('  Screenshots: tim755-0[1-5].png');

    // Hard assertions — TIM-755 acceptance criteria.
    expect(output).toContain('[TD] Main_Loop frame 200');
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
    expect(pageErrors, 'no uncaught JS errors').toHaveLength(0);
    expect(stats200.fillPct, 'canvas fill must be ≥20% at frame 200').toBeGreaterThanOrEqual(20);
  });
});
