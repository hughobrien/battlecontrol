/**
 * TIM-779 — Fix comparison system (Deliverable 1) + map-bleed after quit
 * regression (TIM-777, Deliverable 2).
 *
 * Three tests:
 *
 *   1 · Capture clean main-menu golden (if absent) — always generates the
 *       reference that the regression test compares against.  Uses the
 *       menu-only URL (no autostart).  Also asserts basic menu sanity
 *       (640×480, ≥30% fill, no cyan-scatter).
 *
 *   2 · Regress — gameplay → mission win → menu transition canvas grab.
 *       First compares against the committed golden (clean-ra-menu.png) if
 *       present, or falls back to a freshly-captured golden from test 1.
 *       SSIM ≥ 0.90 → PASS  (menu is clean; bug is fixed).
 *       SSIM <  0.90 → FAIL (map persists on canvas — TIM-777 regression).
 *
 *   3 · Parity-compare JSON logged for CI parsing.
 *
 * ─── Test 2 flow ────────────────────────────────────────────────────────────
 *   ra.html?src=ASSET_URL&autostart=1&mission_test=1&debug=1
 *    1. Assets load → preloader hides
 *    2. RA_AUTOSTART bypasses menu → SCG01EA.INI (EASY)
 *    3. FPS audit: frames 0-999 (win/loss suppressed)
 *    4. _ra_frame_count == 1050:  RA_MISSION_TEST.FLAG re-arms win trigger
 *    5. Frame ~1250: forced win fires → Do_Win() → win movies + score
 *    6. GameActive = false → Main_Loop exits → Select_Game re-entered
 *    7. Menu renders on canvas  →  take screenshot
 *    8. parity-compare.py --threshold-ssim 0.90 vs clean golden
 *
 * ─── Servers ─────────────────────────────────────────────────────────────────
 *   serve-coop.py on :8080  (WASM bundle from build-wasm/)
 *   serve-assets.py on :9090 (CD1 MIX files)
 *
 * ─── Run ─────────────────────────────────────────────────────────────────────
 *   npx playwright test e2e/tim779-menu-bleed.spec.ts --project chromium
 */

import { test, expect } from '@playwright/test';
import * as child_process from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const GOLDENS_DIR     = path.join(__dirname, 'goldens');
const CLEAN_GOLDEN    = path.join(GOLDENS_DIR, 'clean-ra-menu.png');
const REPO_ROOT       = path.resolve(__dirname, '..');

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
    { timeout: timeoutMs },
  );
}

async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? (el.textContent || '') : '';
  });
}

async function canvasStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fill: 0, colors: 0, w: 0, h: 0, cyanCount: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, colors: 0, w: canvas.width, h: canvas.height, cyanCount: 0 };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0, cyanCount = 0;
    const colorSet = new Set<number>();
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      if (r < 32 && g > 180 && b > 180) cyanCount++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, cyanCount, w, h };
  });
}

function runParityCompare(
  pathA: string, pathB: string,
  opts: { label?: string; thresholdSsim?: number; diffOut?: string } = {},
): { status: string; ssim: number; p99Diff: number; fillA: number; fillB: number; error?: string } {
  const argv = [
    path.join(REPO_ROOT, 'scripts', 'parity-compare.py'),
    pathA, pathB,
    '--label', opts.label ?? 'comparison',
    '--threshold-ssim', String(opts.thresholdSsim ?? 0.90),
    '--json',
  ];
  if (opts.diffOut) argv.push('--diff-out', opts.diffOut);

  const proc = child_process.spawnSync('python3', argv, {
    encoding: 'utf-8',
    timeout: 30_000,
  });

  const lines = (proc.stdout || '').trim().split('\n');
  const jsonLine = lines[lines.length - 1] || '';
  try {
    const r = JSON.parse(jsonLine);
    return {
      status:  r.status   ?? 'SKIP',
      ssim:    r.ssim     ?? 0,
      p99Diff: r.p99_diff ?? 999,
      fillA:   r.fill_a   ?? 0,
      fillB:   r.fill_b   ?? 0,
      error:   r.error,
    };
  } catch {
    return {
      status: 'SKIP', ssim: 0, p99Diff: 999, fillA: 0, fillB: 0,
      error: `parity-compare.py parse error: ${jsonLine.slice(0, 200)}`,
    };
  }
}

const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

test.describe('TIM-779 — menu-bleed regression (TIM-777)', () => {
  test.setTimeout(900_000); // 15 min — mission_test cycle can take ~8 min

  test('1 · capture clean menu golden & assert menu sanity', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // Wait for game ready
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 },
    );
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);

    // Wait for main menu to settle
    await waitForOutput(page, '[TIM-616] menu_cs=', 90_000);
    await page.waitForTimeout(3_000);

    const stats = await canvasStats(page);
    const shot  = path.join(SCREENSHOTS_DIR, 'tim779-clean-menu.png');
    await page.screenshot({ path: shot });

    console.log(`Clean menu canvas: fill=${stats.fill}% colors=${stats.colors} cyan=${stats.cyanCount} w=${stats.w} h=${stats.h}`);

    expect(stats.w, 'canvas width 640').toBe(640);
    expect(stats.h, 'canvas height 480').toBe(480);
    expect(stats.fill, 'menu fill ≥30% (TIM-250 gate)').toBeGreaterThanOrEqual(30);
    expect(stats.cyanCount, 'no cyan-scatter (TIM-590 gate)').toBeLessThan(50);
    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during menu render',
    ).toHaveLength(0);

    // Copy to goldens dir for subsequent comparisons
    if (!fs.existsSync(CLEAN_GOLDEN)) {
      fs.mkdirSync(GOLDENS_DIR, { recursive: true });
      fs.copyFileSync(shot, CLEAN_GOLDEN);
      console.log(`Golden saved → ${CLEAN_GOLDEN}`);
    }
  });

  test('2 · gameplay → forced win → menu: SSIM ≥ 0.90 vs clean golden', async ({ page }, testInfo) => {
    test.skip(
      !fs.existsSync(CLEAN_GOLDEN),
      'clean-ra-menu.png golden not found — run test 1 first',
    );

    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1&mission_test=1&debug=1`;
    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // ── Phase 1 — boot + in-game ──────────────────────────────────────────
    console.log('[bleed] waiting for preloader overlay to hide…');
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 },
    );

    console.log('[bleed] waiting for Start_Scenario OK…');
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 300_000);
    console.log('[bleed] Start_Scenario OK — in-game phase');

    // Wait for FPS audit to complete (frame 1000) and win trigger to arm
    // (re-armed at frame 1050 with RA_MISSION_TEST.FLAG).
    console.log('[bleed] waiting for FPS audit + win trigger arm (frame 1050)…');
    await waitForOutput(page, '[RA] Main_Loop frame 1050', 420_000);
    console.log('[bleed] frame 1050 reached');

    // ── Phase 2 — win trigger fires at ~frame 1250 ────────────────────────
    console.log('[bleed] waiting for forced win…');
    await waitForOutput(page, '[TIM-310] forcing win', 300_000);

    const output1 = await getOutput(page);
    const winLine = output1.split('\n').find(l => l.includes('[TIM-310] forcing win'));
    console.log(`[bleed] win trigger: ${winLine || '(not found)'}`);

    // ── Phase 3 — wait for Do_Win + transition back to menu ───────────────
    console.log('[bleed] waiting for Do_Win…');
    await waitForOutput(page, '[RA] Do_Win: entered', 120_000);

    // Win movies + score presentation can take ~30-60s.  After that,
    // GameActive goes false and Select_Game re-enters.
    console.log('[bleed] waiting for Select_Game re-entry…');
    await waitForOutput(page, '[TIM-712] Select_Game entered', 300_000);
    console.log('[bleed] Select_Game re-entered — menu rendering');

    // Let the menu fully render
    await page.waitForTimeout(5_000);

    // ── Phase 4 — capture + compare ───────────────────────────────────────
    const postGameShot = path.join(SCREENSHOTS_DIR, 'tim779-postgame-menu.png');
    await page.screenshot({ path: postGameShot });

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim779-diff-menu-bleed.png');
    const cmp = runParityCompare(CLEAN_GOLDEN, postGameShot, {
      label: 'menu-bleed', thresholdSsim: 0.90, diffOut,
    });

    console.log(`[bleed] parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} ` +
      `fill_golden=${cmp.fillA}% fill_post=${cmp.fillB}% status=${cmp.status}`);
    if (cmp.error) console.log(`[bleed] parity error: ${cmp.error}`);

    // Attach artifacts on failure
    if (cmp.status !== 'PASS') {
      if (fs.existsSync(diffOut))     await testInfo.attach('diff-menu-bleed.png',     { path: diffOut,     contentType: 'image/png' });
      if (fs.existsSync(CLEAN_GOLDEN)) await testInfo.attach('clean-menu-golden.png',   { path: CLEAN_GOLDEN, contentType: 'image/png' });
      if (fs.existsSync(postGameShot)) await testInfo.attach('postgame-menu.png',       { path: postGameShot, contentType: 'image/png' });
    }

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during the bleed test',
    ).toHaveLength(0);

    expect(cmp.ssim, `menu-bleed SSIM ≥ 0.90 (got ${cmp.ssim}) — TIM-777 regression detected`).toBeGreaterThanOrEqual(0.90);

    console.log('[bleed] PASS — menu is clean after returning from gameplay');
  });
});
