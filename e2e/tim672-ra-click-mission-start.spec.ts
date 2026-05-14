/**
 * TIM-672 — RA WASM: real-click mission start (no autostart URL param).
 *
 * Canonical regression guard for the SDL/Emscripten mouse input pipeline.
 * Covers the full player path: VQA skip → main menu → New Campaign click →
 * difficulty/faction auto-accept → mission start → in-game frames.
 *
 * Servers required (started externally before this spec):
 *   - serve-coop.py on port 8080 (WASM bundle from build-wasm/)
 *   - serve-assets.py on port 9090 (RA MIX files from CD1/)
 *
 * URL: http://localhost:8080/ra.html?src=http://localhost:9090/&debug=1
 *      NO ?autostart=1 — exercises the real menu navigation path.
 *
 * Acceptance criteria (TIM-672):
 *   1. ENGLISH.VQA and PROLOG.VQA are skipped via window._vqa_aborted
 *   2. Main menu renders — [TIM-616] menu_cs= logged
 *   3. Real Playwright click at (322, 183) triggers New Campaign
 *   4. Difficulty and faction auto-accept via surviving synthetic KN_RETURN
 *      injections (SPECIAL.CPP:585, INIT.CPP:980)
 *   5. Start_Scenario OK — logged in #output
 *   6. Frame 100+ reached without crash
 *   7. Canvas fill ≥ 5% at frame 100
 *
 * Button positions (640×480, no expansion packs) — from TIM-649 / TIM-665:
 *   New Game:     (322, 183)
 *   Load:         (322, 211)
 *   Multiplayer:  (322, 239)
 *   Introduction: (322, 267)
 *   Exit:         (322, 295)
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

/**
 * Sample the full canvas and return pixel fill statistics.
 * Returns fillPct (0–100), uniqueColors, and hasContent.
 */
async function sampleCanvas(page: any): Promise<{
  fillPct: number;
  uniqueColors: number;
  hasContent: boolean;
  width: number;
  height: number;
}> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fillPct: 0, uniqueColors: 0, hasContent: false, width: 0, height: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      const len = canvas.toDataURL('image/png').length;
      return { fillPct: 0, uniqueColors: 0, hasContent: len > 2000, width: canvas.width, height: canvas.height };
    }
    const w = canvas.width;
    const h = canvas.height;
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

/**
 * Install a page-side polling interval that keeps window._vqa_aborted = true
 * whenever the VQA abort listener infrastructure is active.  This causes both
 * ENGLISH.VQA and PROLOG.VQA to abort on the first frame after they reset the
 * flag.  Returns a cancel function; call it after [TIM-616] menu_cs= is seen.
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

// ---------------------------------------------------------------------------
// Main test
// ---------------------------------------------------------------------------

test.describe('TIM-672 — RA WASM real-click mission start (no autostart)', () => {
  test.setTimeout(900_000);  // 15 min: 4min init + 30s VQA skip + menu + briefing + 100 frames

  const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

  test('VQA skip → New Campaign click → Start_Scenario OK → frame 100 non-black', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // --- Phase 1: preloader hides ---
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
    console.log('[TIM-672] preloader hidden — MIX assets mounted');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-01-preloader-hidden.png'), fullPage: true });

    // --- Phase 2: Init_Bulk_Data done (game binary running, assets loaded) ---
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
    console.log('[TIM-672] Init_Bulk_Data done — game binary running');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-02-init-bulk-done.png'), fullPage: true });

    // --- Phase 3: VQA auto-skip ---
    // ENGLISH.VQA and PROLOG.VQA play after Init_Bulk_Data.  Install a 100ms
    // interval that keeps window._vqa_aborted=true whenever the abort
    // infrastructure is active, so each VQA exits on its first poll cycle.
    const cancelVqaSkip = await installVqaAutoSkip(page);
    console.log('[TIM-672] VQA auto-skip interval installed');

    // --- Phase 4: main menu ready ---
    // [TIM-616] menu_cs= fires when Select_Game enters the main menu loop.
    await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
    await cancelVqaSkip();
    console.log('[TIM-672] main menu up — cancelling VQA skip interval');

    // Give the menu one rendering tick to stabilise before clicking.
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-03-menu-ready.png'), fullPage: true });

    const menuCanvas = await sampleCanvas(page);
    console.log(`[TIM-672] menu canvas: ${menuCanvas.width}x${menuCanvas.height}  fill=${menuCanvas.fillPct}%  colors=${menuCanvas.uniqueColors}`);
    expect(menuCanvas.hasContent, 'main menu canvas must be non-black').toBe(true);

    // --- Phase 5: click "New Campaign" at (322, 183) ---
    // Coordinates confirmed by TIM-649 button layout and TIM-665 synthetic
    // injection position.  Focus the canvas first so SDL keyboard events follow.
    const canvas = page.locator('#canvas');
    await canvas.click({ position: { x: 322, y: 183 } });
    console.log('[TIM-672] clicked New Campaign at (322, 183)');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-04-new-campaign-click.png'), fullPage: true });

    // --- Phase 6: difficulty and faction auto-accept ---
    // SPECIAL.CPP:585 injects KN_RETURN for difficulty (static once-guard).
    // INIT.CPP:980 injects KN_RETURN for faction select (Allies → SCG01EA).
    // These are synthetic injections that survive the TIM-664 cleanup; no
    // extra Playwright input is required here.
    await waitForOutput(page, '[DIFF] injecting KN_RETURN', 30_000);
    console.log('[TIM-672] difficulty auto-accepted (KN_RETURN injection)');

    await waitForOutput(page, '[INIT] injecting KN_RETURN', 30_000);
    console.log('[TIM-672] faction auto-selected (KN_RETURN injection → Allies)');

    // --- Phase 7: Start_Scenario OK ---
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    console.log('[TIM-672] Start_Scenario OK — mission started');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-05-start-scenario.png'), fullPage: true });

    const outputAfterStart = await getOutput(page);
    expect(outputAfterStart).toContain('Start_Scenario OK');
    expect(outputAfterStart).toContain('SCG01EA');
    expect(outputAfterStart).not.toContain('SIGSEGV');
    expect(outputAfterStart).not.toContain('Aborted(');

    // --- Phase 8: frame 100 ---
    await waitForOutput(page, '[RA] Main_Loop frame 100', 420_000);
    await page.waitForTimeout(300);
    console.log('[TIM-672] frame 100 reached');

    const stats100 = await sampleCanvas(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim672-06-frame-100.png'), fullPage: true });
    console.log(`[TIM-672] frame 100 canvas: ${stats100.width}x${stats100.height}  fill=${stats100.fillPct}%  colors=${stats100.uniqueColors}  hasContent=${stats100.hasContent}`);

    const outputFinal = await getOutput(page);
    const pageErrors = consoleLogs.filter(l => l.includes('[pageerror]'));

    console.log('\n[TIM-672] ===== SUMMARY =====');
    console.log(`  Preloader hidden:     PASS`);
    console.log(`  Init_Bulk_Data done:  PASS`);
    console.log(`  VQA skip:             PASS`);
    console.log(`  Main menu rendered:   PASS (fill=${menuCanvas.fillPct}%  colors=${menuCanvas.uniqueColors})`);
    console.log(`  New Campaign click:   PASS`);
    console.log(`  Difficulty accepted:  PASS`);
    console.log(`  Faction selected:     PASS`);
    console.log(`  Start_Scenario OK:    PASS`);
    console.log(`  Frame 100 reached:    PASS`);
    console.log(`  Canvas fill@f100:     ${stats100.fillPct}% (threshold ≥5%)`);
    console.log(`  No crash:             ${!outputFinal.includes('SIGSEGV') && !outputFinal.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page errors:       ${pageErrors.length === 0 ? 'PASS' : 'FAIL (' + pageErrors.length + ' errors)'}`);
    if (pageErrors.length > 0) {
      pageErrors.forEach(e => console.log(`    ${e}`));
    }

    // Hard assertions — TIM-672 acceptance criteria.
    expect(outputFinal).toContain('[RA] Main_Loop frame 100');
    expect(outputFinal).not.toContain('SIGSEGV');
    expect(outputFinal).not.toContain('Aborted(');
    expect(pageErrors.length, 'no page errors').toBe(0);
    expect(stats100.fillPct, 'canvas fill must be ≥5% at frame 100').toBeGreaterThanOrEqual(5);
  });
});
