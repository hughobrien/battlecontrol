/**
 * TIM-812 — WASM parity captures for RA Soviet M2 and TD GDI M2.
 *
 * Validates visual parity between the WASM browser port and Wine OG reference
 * for missions beyond M1 using the ?scenario= URL parameter (TIM-812).
 *
 * Tier 1 (WASM-only, always runs):
 *   - RA Soviet M2: frame-500 capture, fill ≥5%, no cyan-scatter, 640×480
 *   - TD GDI M2:   frame-500 capture, fill ≥5%, no cyan-scatter, 640×400
 *
 * Tier 2 (Wine OG parity, requires WINE_RA_READY=1):
 *   - RA Soviet M2 frame-500 SSIM ≥ 0.90 vs e2e/goldens/soviet-m2-wineog-f500.png
 *
 * TD GDI M2 Wine OG parity is blocked (TIM-803: strategic map only shows M1
 * from a fresh game; binary patch needed for Select_Game Scenario=2).
 *
 * ─── URL param mechanism (TIM-812) ────────────────────────────────────────────
 * The preloader and C++ INIT.CPP now support ?scenario=<NAME> which creates
 * {RA|TD}_AUTOSTART_SCENARIO.FLAG with the scenario name.  This is read in
 * Select_Game() to override the autostart mission:
 *   - RA: ?autostart=1&scenario=SCU02EA  → Soviet M2 (SCU02EA.INI)
 *   - TD: ?autostart=1&scenario=SCG02EA  → GDI M2 (SCG02EA)
 *
 * ─── Setup ───────────────────────────────────────────────────────────────────
 *   serve-coop.py on :8080   (WASM bundle from build-wasm/)
 *   serve-assets.py on :9090  (RA CD1 MIX files) or RA_ASSETS_URL
 *   serve-assets.py on :9091  (TD CD1 MIX files) or TD_ASSETS_URL
 *
 * ─── Run ─────────────────────────────────────────────────────────────────────
 *   npx playwright test e2e/tim812-wasm-m2-parity.spec.ts
 *   WINE_RA_READY=1 npx playwright test e2e/tim812-wasm-m2-parity.spec.ts
 *
 * ─── Related ─────────────────────────────────────────────────────────────────
 *   TIM-803 — RA Soviet M2 Wine OG capture + TD GDI M2 blocked analysis
 *   TIM-776 — RA Soviet L1 Wine OG capture (precedent)
 *   TIM-780 — RA Soviet L1 WASM capture + Wine OG parity
 *   TIM-710 — RA WASM parity suite (Allied L1, Soviet L1, VQA)
 *   TIM-711 — TD WASM parity suite (GDI L1)
 */

import { test, expect } from '@playwright/test';
import * as child_process from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const RA_WASM_URL      = 'http://localhost:8080/ra.html';
const TD_WASM_URL      = 'http://localhost:8080/td.html';
const RA_ASSET_URL     = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
const TD_ASSET_URL     = process.env['TD_ASSETS_URL'] || 'http://localhost:9091/';
const SCREENSHOTS_DIR  = path.join(__dirname, 'screenshots');
const REPO_ROOT        = path.resolve(__dirname, '..');

const WINE_RA_READY    = process.env.WINE_RA_READY === '1';

const SOVIET_M2_GOLDEN = path.join(__dirname, 'goldens', 'soviet-m2-wineog-f500.png');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Shared helpers
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

async function waitForTdReady(page: any) {
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 },
  );
  await waitForOutput(page, 'WASM_READY', 120_000);
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

// Run scripts/parity-compare.py and return parsed JSON result.
function runParityCompare(
  pathA: string,
  pathB: string,
  opts: { label?: string; thresholdSsim?: number; diffOut?: string; cropBottom?: number } = {},
): { status: string; ssim: number; p99Diff: number; fillA: number; fillB: number; error?: string } {
  const argv = [
    path.join(REPO_ROOT, 'scripts', 'parity-compare.py'),
    pathA, pathB,
    '--label', opts.label ?? 'comparison',
    '--threshold-ssim', String(opts.thresholdSsim ?? 0.90),
    '--json',
  ];
  if (opts.diffOut) argv.push('--diff-out', opts.diffOut);
  if (opts.cropBottom) { argv.push('--crop-bottom', String(opts.cropBottom)); }

  const proc = child_process.spawnSync('python3', argv, {
    encoding: 'utf-8',
    timeout: 30_000,
  });

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
// RA Soviet M2 — WASM capture
// ---------------------------------------------------------------------------

test.describe('Tier 1 — RA Soviet M2 frame 500 (WASM)', () => {
  test.setTimeout(1_200_000);

  test('Soviet Mission 2: autostart via ?scenario=SCU02EA → frame-500 capture', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    // Log console output for debugging (suppressed in normal runs)
    page.on('console', () => {});

    const url = `${RA_WASM_URL}?src=${encodeURIComponent(RA_ASSET_URL)}&autostart=1&scenario=SCU02EA.INI&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await waitForGameReady(page);

    // Wait for game loop to reach frame 500.
    await waitForOutput(page, '[RA] Main_Loop frame 500', 600_000);
    await page.waitForTimeout(300);

    const shotPath = path.join(SCREENSHOTS_DIR, 'soviet-m2-wasm-f500.png');
    await page.screenshot({ path: shotPath });

    const stats500 = await canvasStats(page);
    console.log(`[RA-SOV-M2] frame 500: fill=${stats500.fill}% colors=${stats500.colors} cyan=${stats500.cyanCount} w=${stats500.w} h=${stats500.h}`);

    expect(stats500.fill, 'Soviet M2 frame 500 fill ≥5%').toBeGreaterThanOrEqual(5);
    expect(stats500.cyanCount, 'no cyan-scatter (TIM-590 gate)').toBeLessThan(50);
    expect(stats500.w, 'canvas width 640').toBe(640);
    expect(stats500.h, 'canvas height 480').toBe(480);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during Soviet M2',
    ).toHaveLength(0);

    console.log(`[RA-SOV-M2] Soviet M2 frame 500 captured at ${shotPath}`);
  });
});

// ---------------------------------------------------------------------------
// RA Soviet M2 — WASM vs Wine OG SSIM parity
// ---------------------------------------------------------------------------

test.describe('Tier 2 — RA Soviet M2 WASM vs Wine OG parity [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(
      !WINE_RA_READY,
      'Tier 2 requires WINE_RA_READY=1; run bash scripts/wine-soviet-m2.sh first',
    );
  });

  test('Soviet M2 frame 500: SSIM ≥ 0.90 vs Wine OG golden', async ({}, testInfo) => {
    const wasmShot = path.join(SCREENSHOTS_DIR, 'soviet-m2-wasm-f500.png');
    test.skip(!fs.existsSync(SOVIET_M2_GOLDEN), 'soviet-m2-wineog-f500.png missing — golden not in e2e/goldens/');
    test.skip(!fs.existsSync(wasmShot), 'soviet-m2-wasm-f500.png missing — run Tier 1 Soviet M2 test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim812-diff-soviet-m2-f500.png');
    const cmp = runParityCompare(SOVIET_M2_GOLDEN, wasmShot, {
      label: 'soviet-m2-f500', thresholdSsim: 0.90, diffOut,
    });
    console.log(
      `Soviet M2 f500 parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} `
      + `fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`
    );
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))           await testInfo.attach('diff-soviet-m2-f500.png',       { path: diffOut,       contentType: 'image/png' });
      if (fs.existsSync(SOVIET_M2_GOLDEN))  await testInfo.attach('soviet-m2-wineog-f500.png',     { path: SOVIET_M2_GOLDEN, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))          await testInfo.attach('soviet-m2-wasm-f500.png',       { path: wasmShot,      contentType: 'image/png' });
    }

    expect(cmp.ssim, `Soviet M2 frame 500 SSIM ≥0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });
});

// ---------------------------------------------------------------------------
// TD GDI M2 — WASM capture
// ---------------------------------------------------------------------------

test.describe('Tier 1 — TD GDI M2 frame 500 (WASM)', () => {
  test.setTimeout(900_000);

  test('GDI Mission 2: autostart via ?scenario=SCG02EA → frame-500 capture', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    const url = `${TD_WASM_URL}?src=${encodeURIComponent(TD_ASSET_URL)}&autostart=1&scenario=SCG02EA&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await waitForTdReady(page);

    // Wait for TD_AUTOSTART to activate and the game loop to reach frame 500.
    await waitForOutput(page, '[TD] Main_Loop frame 500', 420_000);
    await page.waitForTimeout(300);

    const shotPath = path.join(SCREENSHOTS_DIR, 'gdi-m2-wasm-f500.png');
    await page.screenshot({ path: shotPath });

    const stats500 = await canvasStats(page);
    console.log(`[TD-GDI-M2] frame 500: fill=${stats500.fill}% colors=${stats500.colors} cyan=${stats500.cyanCount} w=${stats500.w} h=${stats500.h}`);

    expect(stats500.fill, 'TD GDI M2 frame 500 fill ≥5%').toBeGreaterThanOrEqual(5);
    expect(stats500.cyanCount, 'no cyan-scatter (TIM-590 gate)').toBeLessThan(50);
    expect(stats500.w, 'canvas width 640').toBe(640);
    expect(stats500.h, 'canvas height 400').toBe(400);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during GDI M2',
    ).toHaveLength(0);

    console.log(`[TD-GDI-M2] GDI M2 frame 500 captured at ${shotPath}`);
  });
});
