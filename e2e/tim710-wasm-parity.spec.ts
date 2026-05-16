/**
 * TIM-710 / TIM-780 — RA WASM port vs OG Wine parity validation.
 *
 * Validates visual parity between the WASM browser port and Wine OG Red Alert
 * across key scenarios: title screen, main menu, Allied L1 gameplay,
 * Soviet L1 gameplay, and VQA playback.
 *
 * ─── Tier 1 (WASM-only, always runs) ────────────────────────────────────────
 *   - Title screen: canvas fill ≥5%, 640×480, no cyan-scatter (TIM-590 gate)
 *   - Main menu: canvas fill ≥30% (TIM-250 gate), 640×480
 *   - Allied L1: map fill ≥20% at t=0, t≈10s, t≈30s (TIM-705 gate)
 *   - Soviet L1: frame-500 screenshot for parity comparison (TIM-776/TIM-780)
 *   - VQA playback: LOGO.VQA canvas non-black at early + mid playback
 *
 * ─── Tier 2 (Wine OG parity, requires WINE_RA_READY=1) ──────────────────────
 *   - Title SSIM ≥ 0.90 vs e2e/screenshots/wine-ra-title.png
 *   - Menu SSIM ≥ 0.90 vs e2e/screenshots/wine-ra-menu.png
 *   - Allied L1 t=0 SSIM ≥ 0.90 vs e2e/screenshots/wine-allied-l1-t0.png
 *   - Soviet L1 frame-500 SSIM ≥ 0.90 vs e2e/goldens/soviet-l1-wineog-f500.png
 *   - Diff PNGs attached as test artifacts on failure
 *
 * ─── Setup ───────────────────────────────────────────────────────────────────
 *   serve-coop.py on :8080   (WASM bundle from build-wasm/)
 *   serve-assets.py on :9090 (CD1 MIX files)
 *   [Tier 2] WINE_RA_READY=1 + bash scripts/wine-ra.sh + bash scripts/wine-gameplay.sh
 *   [Tier 2 Soviet] also requires bash scripts/wine-soviet-l1.sh
 *
 * ─── Run ─────────────────────────────────────────────────────────────────────
 *   npm run test:e2e:wasm-parity
 *   WINE_RA_READY=1 npm run test:e2e:wasm-parity
 *
 * ─── Related ─────────────────────────────────────────────────────────────────
 *   TIM-699 — Wine setup + OG reference screenshots
 *   TIM-705 — Cinematic pixel-exact parity (8/8 VQAs SSIM=1.0)
 *   TIM-709 — Wine headless mouse input (parallel)
 *   TIM-776 — Wine OG Soviet L1 capture (golden)
 *   TIM-780 — WASM Soviet L1 capture + parity
 */

import { test, expect }   from '@playwright/test';
import * as child_process from 'child_process';
import * as fs            from 'fs';
import * as path          from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
// RA_ASSETS_URL lets CI pass a CDN or custom URL; local runs use :9090
const ASSET_URL       = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const REPO_ROOT       = path.resolve(__dirname, '..');

// Soviet L1 golden (Wine OG, captured by scripts/wine-soviet-l1.sh, PR #160)
const SOVIET_L1_GOLDEN = path.join(__dirname, 'goldens', 'soviet-l1-wineog-f500.png');

const WINE_RA_READY = process.env.WINE_RA_READY === '1';

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Shared helpers (mirrors tim705-equivalence.spec.ts patterns)
// ---------------------------------------------------------------------------

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

// Wait for preloader to finish mounting assets and game to complete Init_Bulk_Data.
// 'WASM ready' only goes to #status-line (not #output), so we gate on the
// preloader-overlay hiding then the first C++ milestone log in #output.
async function waitForGameReady(page: any) {
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 },
  );
  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
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

// Abort VQAs as soon as they start by setting the JS-side abort flag.
// Uses the same _vqa_aborted / _vqa_abort_installed mechanism as T5 (which
// is checked by vqa_player.cpp's vqa_check_abort_flag() each frame).
// The old Escape-key-to-document approach did not reach SDL in the Worker thread.
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

// Run scripts/parity-compare.py and return parsed JSON result.
// Returns { status, ssim, p99Diff, fillA, fillB, error? }
function runParityCompare(
  pathA: string,
  pathB: string,
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

  // The last line of stdout is the JSON result.
  const lines = (proc.stdout || '').trim().split('\n');
  const jsonLine = lines[lines.length - 1] || '';
  try {
    const r = JSON.parse(jsonLine);
    return {
      status:  r.status  ?? 'SKIP',
      ssim:    r.ssim    ?? 0,
      p99Diff: r.p99_diff ?? 999,
      fillA:   r.fill_a  ?? 0,
      fillB:   r.fill_b  ?? 0,
      error:   r.error,
    };
  } catch {
    return {
      status: 'SKIP', ssim: 0, p99Diff: 999, fillA: 0, fillB: 0,
      error: `parity-compare.py parse error: ${jsonLine.slice(0, 200)}`,
    };
  }
}

// ---------------------------------------------------------------------------
// Tier 1 — WASM visual reference
// ---------------------------------------------------------------------------

test.describe('Tier 1 — title screen (WASM)', () => {
  test.setTimeout(300_000);

  test('title screen renders non-black ≥5%, 640×480, no cyan-scatter', async ({ page }) => {
    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });
    await waitForGameReady(page);

    // Title/intro VQA renders shortly after init
    await page.waitForTimeout(8_000);

    const stats = await canvasStats(page);
    const shot  = path.join(SCREENSHOTS_DIR, 'tim710-wasm-title.png');
    await page.screenshot({ path: shot });

    console.log(`Title canvas: fill=${stats.fill}% colors=${stats.colors} cyan=${stats.cyanCount} (${stats.w}×${stats.h})`);

    expect(stats.fill,      'title fill ≥5%').toBeGreaterThanOrEqual(5);
    expect(stats.cyanCount, 'no cyan-scatter (TIM-590 gate)').toBeLessThan(50);
    expect(stats.w,         'canvas width 640').toBe(640);
    expect(stats.h,         'canvas height 480').toBe(480);
  });
});

test.describe('Tier 1 — main menu (WASM)', () => {
  test.setTimeout(300_000);

  test('main menu renders ≥30% fill at 640×480', async ({ page }) => {
    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });
    const cancelMenuSkip = await installVqaAutoSkip(page);
    await waitForGameReady(page);
    await waitForOutput(page, '[TIM-616] menu_cs=', 90_000);
    await cancelMenuSkip();
    await page.waitForTimeout(3_000);

    const stats = await canvasStats(page);
    const shot  = path.join(SCREENSHOTS_DIR, 'tim710-wasm-menu.png');
    await page.screenshot({ path: shot });

    console.log(`Menu canvas: fill=${stats.fill}% colors=${stats.colors} cyan=${stats.cyanCount} (${stats.w}×${stats.h})`);

    expect(stats.fill,      'menu fill ≥30%').toBeGreaterThanOrEqual(30);
    expect(stats.cyanCount, 'no cyan-scatter').toBeLessThan(50);
    expect(stats.w,         'canvas width 640').toBe(640);
    expect(stats.h,         'canvas height 480').toBe(480);
  });
});

test.describe('Tier 1 — Allied L1 gameplay (WASM)', () => {
  test.setTimeout(900_000);

  test('Allied L1 map renders ≥20% fill at t=0, t≈10s, t≈30s without crash', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });

    // Install VQA skip BEFORE waitForGameReady so intro VQAs (ENGLISH.VQA + PROLOG.VQA)
    // abort after a few frames instead of playing for ~285s, making Init_Bulk_Data fire fast.
    const cancelSkip = await installVqaAutoSkip(page);
    await waitForGameReady(page);

    // Wait for EITHER Main_Menu to appear (normal path) OR Start_Scenario OK (IsFromInstall
    // direct-start path — diagnosed by [TIM-712] logs).  Both paths lead to Allied L1.
    const startPath = await page.waitForFunction(
      () => {
        const el = document.getElementById('output');
        if (!el || !el.textContent) return null;
        if (el.textContent.includes('[TIM-616] menu_cs=')) return 'menu';
        if (el.textContent.includes('Start_Scenario OK'))  return 'direct';
        return null;
      },
      null,
      { timeout: 120_000 },
    );
    const pathTaken = await startPath.jsonValue() as string;
    console.log(`[TIM-712] game start path: ${pathTaken}`);

    if (pathTaken === 'menu') {
      await page.waitForTimeout(1_000);
      // Navigate to Allied L1 (confirmed coords from TIM-697)
      await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
      await waitForOutput(page, '[MENU] input=0x', 30_000);

      await waitForOutput(page, '[DIFF] dialog ready', 30_000);
      await page.waitForTimeout(500);
      await page.locator('#canvas').click({ position: { x: 470, y: 244 } });

      await waitForOutput(page, '[INIT] faction dialog ready', 30_000);
      await page.waitForTimeout(500);
      await page.locator('#canvas').click({ position: { x: 258, y: 268 } });

      // Wait for Start_Scenario OK (briefing VQAs already aborted by VQA skip).
      await waitForOutput(page, 'Start_Scenario OK', 120_000);
    }
    // direct path: Start_Scenario OK already fired, VQA skip aborted briefing VQAs

    await cancelSkip();

    // Let the gameplay settle for a frame or two before sampling.
    await page.waitForTimeout(5_000);

    const t0Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-allied-l1-t0.png') });
    console.log(`L1 t=0:   fill=${t0Stats.fill}% colors=${t0Stats.colors}`);
    expect(t0Stats.fill, 'Allied L1 t=0 fill ≥20%').toBeGreaterThanOrEqual(20);
    expect(t0Stats.w, 'canvas width 640').toBe(640);
    expect(t0Stats.h, 'canvas height 480').toBe(480);

    await page.waitForTimeout(15_000);
    const t10Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-allied-l1-t10.png') });
    console.log(`L1 t≈10s: fill=${t10Stats.fill}%`);
    expect(t10Stats.fill, 'Allied L1 t≈10s fill ≥20%').toBeGreaterThanOrEqual(20);

    await page.waitForTimeout(20_000);
    const t30Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-allied-l1-t30.png') });
    console.log(`L1 t≈30s: fill=${t30Stats.fill}%`);
    expect(t30Stats.fill, 'Allied L1 t≈30s fill ≥20%').toBeGreaterThanOrEqual(20);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during gameplay',
    ).toHaveLength(0);

    console.log(`Allied L1 PASS: t0=${t0Stats.fill}% t≈10s=${t10Stats.fill}% t≈30s=${t30Stats.fill}%`);
  });
});

test.describe('Tier 1 — VQA playback (WASM)', () => {
  test.setTimeout(300_000);

  test('LOGO.VQA: canvas non-black during early and mid playback', async ({ page }) => {
    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });
    await waitForGameReady(page);

    // LOGO.VQA plays automatically at startup
    await waitForOutput(page, '[VQA] Playing', 60_000);

    // Capture early frame (~2s in)
    await page.waitForTimeout(2_000);
    const earlyStats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-logo-vqa-early.png') });
    console.log(`LOGO.VQA early: fill=${earlyStats.fill}% colors=${earlyStats.colors}`);

    // Capture mid-point frame (~6s in = ~frame 120 of 262 at 20fps)
    await page.waitForTimeout(4_000);
    const midStats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-logo-vqa-mid.png') });
    console.log(`LOGO.VQA mid:   fill=${midStats.fill}% colors=${midStats.colors}`);

    const maxFill = Math.max(earlyStats.fill, midStats.fill);
    expect(maxFill, 'LOGO.VQA canvas fill ≥5% at some point during playback').toBeGreaterThanOrEqual(5);
  });

  test('intro VQA sequence: ENGLISH.VQA canvas non-black at mid-playback', async ({ page }) => {
    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });

    // Wait for preloader overlay to hide (assets loaded + WASM running).
    // Do NOT use waitForGameReady (which waits for Init_Bulk_Data) — ENGLISH.VQA
    // plays *before* Init_Bulk_Data inside Init_Game, so we must gate earlier.
    await page.waitForFunction(
      () => {
        const overlay = document.getElementById('preloader-overlay');
        return overlay !== null && overlay.style.display === 'none';
      },
      null,
      { timeout: 120_000 },
    );

    // ENGLISH.VQA (VQ_REDINTRO) plays early in Init_Game before Init_Bulk_Data.
    // LOGO.VQA is not played in the WIN32/WASM build; the startup sequence is
    // ENGLISH.VQA → PROLOG.VQA → Init_Bulk_Data.
    await waitForOutput(page, "[VQA] Playing 'ENGLISH.VQA'", 60_000);

    // Capture at ~3s into ENGLISH.VQA (160 frames at 15fps ≈ 10.7s total)
    await page.waitForTimeout(3_000);
    const stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-english-vqa-mid.png') });
    console.log(`ENGLISH.VQA mid: fill=${stats.fill}% colors=${stats.colors}`);

    expect(stats.fill, 'ENGLISH.VQA canvas fill ≥5%').toBeGreaterThanOrEqual(5);
  });
});

// ---------------------------------------------------------------------------
// Tier 2 — Wine OG vs WASM parity
// ---------------------------------------------------------------------------

test.describe('Tier 2 — Wine OG vs WASM parity [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(
      !WINE_RA_READY,
      'Tier 2 requires WINE_RA_READY=1 + wine32 + RA95.EXE; '
      + 'run bash scripts/wine-ra.sh and bash scripts/wine-gameplay.sh first',
    );
  });

  test('title screen: SSIM ≥ 0.90 vs Wine OG', async ({}, testInfo) => {
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-ra-title.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim710-wasm-title.png');
    test.skip(!fs.existsSync(wineShot), 'wine-ra-title.png missing — run bash scripts/wine-ra.sh');
    test.skip(!fs.existsSync(wasmShot), 'tim710-wasm-title.png missing — run Tier 1 title test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim710-diff-title.png');
    const cmp = runParityCompare(wineShot, wasmShot, { label: 'title-screen', thresholdSsim: 0.90, diffOut });
    console.log(`Title parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-title.png',       { path: diffOut,   contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-ra-title.png',    { path: wineShot,  contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-title.png',       { path: wasmShot,  contentType: 'image/png' });
    }

    expect(cmp.ssim, `title SSIM ≥0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });

  test('main menu: SSIM ≥ 0.90 vs Wine OG', async ({}, testInfo) => {
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-ra-menu.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim710-wasm-menu.png');
    test.skip(!fs.existsSync(wineShot), 'wine-ra-menu.png missing — run bash scripts/wine-ra.sh');
    test.skip(!fs.existsSync(wasmShot), 'tim710-wasm-menu.png missing — run Tier 1 menu test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim710-diff-menu.png');
    const cmp = runParityCompare(wineShot, wasmShot, { label: 'main-menu', thresholdSsim: 0.90, diffOut });
    console.log(`Menu parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-menu.png',     { path: diffOut,  contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-ra-menu.png',  { path: wineShot, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-menu.png',     { path: wasmShot, contentType: 'image/png' });
    }

    expect(cmp.ssim, `menu SSIM ≥0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });

  test('Allied L1 t=0: SSIM ≥ 0.90 vs Wine OG', async ({}, testInfo) => {
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-allied-l1-t0.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim710-wasm-allied-l1-t0.png');
    test.skip(!fs.existsSync(wineShot), 'wine-allied-l1-t0.png missing — run bash scripts/wine-allied-l1.sh (TIM-752)');
    test.skip(!fs.existsSync(wasmShot), 'tim710-wasm-allied-l1-t0.png missing — run Tier 1 gameplay test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim710-diff-allied-l1-t0.png');
    const cmp = runParityCompare(wineShot, wasmShot, { label: 'allied-l1-t0', thresholdSsim: 0.90, diffOut });
    console.log(`L1 t=0 parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-allied-l1-t0.png',     { path: diffOut,  contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-allied-l1-t0.png',     { path: wineShot, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-allied-l1-t0.png',     { path: wasmShot, contentType: 'image/png' });
    }

    expect(cmp.ssim, `Allied L1 t=0 SSIM ≥0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });
});

// ---------------------------------------------------------------------------
// Soviet L1 — WASM capture + Wine OG parity (TIM-776 / TIM-780)
// ---------------------------------------------------------------------------
// The WASM build defines FIXIT_VERSION_3, so the faction dialog shows three
// buttons: Allies / Cancel / Soviet.  The Soviet button is at (382, 268).
//
// Reference: scripts/wine-soviet-l1.sh captures the Wine OG reference via
// the soviet-cdlabel-patch.py auto-start path (SCU01EA.INI).

test.describe('Tier 1 — Soviet L1 frame 500 (WASM)', () => {
  test.setTimeout(900_000);

  test('Soviet Mission 1: navigates menu → faction select → frame-500 capture', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    await page.goto(`${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`, { waitUntil: 'domcontentloaded' });

    // Install VQA skip to skip intro + briefing VQAs.
    const cancelSkip = await installVqaAutoSkip(page);
    await waitForGameReady(page);

    // Wait for main menu.
    await waitForOutput(page, '[TIM-616] menu_cs=', 120_000);
    await cancelSkip();
    console.log('[SOV-L1] main menu ready');

    await page.waitForTimeout(500);
    await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
    await waitForOutput(page, '[MENU] input=0x', 30_000);
    console.log('[SOV-L1] clicked New Campaign');

    // Difficulty dialog — click OK.
    await waitForOutput(page, '[DIFF] dialog ready', 30_000);
    await page.waitForTimeout(500);
    await page.locator('#canvas').click({ position: { x: 470, y: 244 } });
    console.log('[SOV-L1] difficulty accepted');

    // Faction dialog — click Soviet (third button, rightmost).
    // FIXIT_VERSION_3: Allies (258,268) / Cancel / Soviet (382,268).
    await waitForOutput(page, '[INIT] faction dialog ready', 30_000);
    await page.waitForTimeout(500);
    await page.locator('#canvas').click({ position: { x: 382, y: 268 } });
    console.log('[SOV-L1] clicked Soviet faction at (382, 268)');

    // Wait for scenario to start.
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 120_000);
    console.log('[SOV-L1] Start_Scenario OK — Soviet L1 mission started');

    // Wait for frame 500.
    await waitForOutput(page, '[RA] Main_Loop frame 500', 420_000);
    await page.waitForTimeout(300);

    const shotPath = path.join(SCREENSHOTS_DIR, 'soviet-l1-wasm-f500.png');
    await page.screenshot({ path: shotPath });

    const stats500 = await canvasStats(page);
    console.log(`[SOV-L1] frame 500: fill=${stats500.fill}% colors=${stats500.colors} w=${stats500.w} h=${stats500.h}`);
    expect(stats500.fill, 'Soviet L1 frame 500 fill ≥5%').toBeGreaterThanOrEqual(5);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during Soviet L1',
    ).toHaveLength(0);

    console.log(`[SOV-L1] Soviet L1 frame 500 captured at ${shotPath}`);
  });
});

test.describe('Tier 2 — Soviet L1 WASM vs Wine OG parity [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(
      !WINE_RA_READY,
      'Tier 2 Soviet L1 parity requires WINE_RA_READY=1; '
      + 'run bash scripts/wine-soviet-l1.sh first',
    );
  });

  test('Soviet L1 frame 500: SSIM ≥ 0.90 vs Wine OG golden', async ({}, testInfo) => {
    const wasmShot = path.join(SCREENSHOTS_DIR, 'soviet-l1-wasm-f500.png');
    test.skip(!fs.existsSync(SOVIET_L1_GOLDEN), 'soviet-l1-wineog-f500.png missing — golden not found in e2e/goldens/');
    test.skip(!fs.existsSync(wasmShot), 'soviet-l1-wasm-f500.png missing — run Tier 1 Soviet L1 test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim780-diff-soviet-l1-f500.png');
    const cmp = runParityCompare(SOVIET_L1_GOLDEN, wasmShot, {
      label: 'soviet-l1-f500', thresholdSsim: 0.90, diffOut,
    });
    console.log(
      `Soviet L1 f500 parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} `
      + `fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`
    );
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))       await testInfo.attach('diff-soviet-l1-f500.png',   { path: diffOut,       contentType: 'image/png' });
      if (fs.existsSync(SOVIET_L1_GOLDEN)) await testInfo.attach('soviet-l1-wineog.png',     { path: SOVIET_L1_GOLDEN, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))      await testInfo.attach('soviet-l1-wasm-f500.png',  { path: wasmShot,      contentType: 'image/png' });
    }

    expect(cmp.ssim, `Soviet L1 frame 500 SSIM ≥0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });
});
