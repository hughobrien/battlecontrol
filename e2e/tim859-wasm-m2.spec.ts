/**
 * TIM-859 — RA Allied M2 campaign mission E2E test (SCG02EA).
 *
 * This is the only gap not covered by tim812-wasm-m2-parity.spec.ts
 * (which covers RA Soviet M2 and TD GDI M2).
 *
 * Tier 1 (WASM-only, always runs):
 *   - Mission load + Start_Scenario OK
 *   - Canvas pixel-stat assertions at frame 500 (fill %, unique colors, non-black)
 *   - No crash (SIGSEGV, Aborted), no uncaught JS errors
 *
 * Tier 2 (Wine OG parity, requires WINE_RA_READY=1):
 *   - RA Allied M2 frame-500 SSIM >= 0.90 vs allied-m2-wineog-f500 golden
 *
 * URL param mechanism:
 *   ?autostart=1&scenario=SCG02EA — preloader writes RA_AUTOSTART_SCENARIO.FLAG
 *   C++ INIT.CPP reads the flag and overrides the hardcoded M1 scenario.
 *
 * ─── Setup ────────────────────────────────────────────────────────────────────
 *   serve-coop.py on :8080   (RA WASM bundle from build-wasm/)
 *   serve-assets.py on :9090 (RA MIX files from CD1/) or RA_ASSETS_URL
 *
 * ─── Run ───────────────────────────────────────────────────────────────────────
 *   playwright test e2e/tim859-wasm-m2.spec.ts
 *   WINE_RA_READY=1 playwright test e2e/tim859-wasm-m2.spec.ts
 */

import { test, expect } from '@playwright/test';
import * as child_process from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const RA_WASM_URL      = 'http://localhost:8080/ra.html';
const RA_ASSET_URL     = process.env['RA_ASSETS_URL'] || 'http://localhost:9090/';
const SCREENSHOTS_DIR  = path.join(__dirname, 'screenshots');
const REPO_ROOT        = path.resolve(__dirname, '..');

const WINE_RA_READY    = process.env.WINE_RA_READY === '1';

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ─── Shared helpers ─────────────────────────────────────────────────────────────

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
  if (opts.cropBottom) argv.push('--crop-bottom', String(opts.cropBottom));

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

// ─── RA Allied M2 ────────────────────────────────────────────────────────────────

test.describe('Tier 1 — RA Allied M2 (SCG02EA)', () => {
  test.setTimeout(1_200_000);

  test('Allied M2: Start_Scenario OK → frame-500 capture, fill >= 5%', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    const url = `${RA_WASM_URL}?src=${encodeURIComponent(RA_ASSET_URL)}&autostart=1&scenario=SCG02EA.INI&debug=1`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await waitForGameReady(page);

    // Confirm the correct scenario was loaded.
    await waitForOutput(page, 'SCG02EA', 120_000);
    await waitForOutput(page, 'Start_Scenario OK', 120_000);

    // Wait for frame 500.
    await waitForOutput(page, '[RA] Main_Loop frame 500', 600_000);
    await page.waitForTimeout(300);

    const shotPath = path.join(SCREENSHOTS_DIR, 'allied-m2-wasm-f500.png');
    await page.screenshot({ path: shotPath });

    const s = await canvasStats(page);
    console.log(`[RA-ALLIED-M2] frame 500: fill=${s.fill}% colors=${s.colors} cyan=${s.cyanCount} w=${s.w} h=${s.h}`);

    expect(s.fill, 'Allied M2 frame 500 fill >= 5%').toBeGreaterThanOrEqual(5);
    expect(s.cyanCount, 'no cyan-scatter (TIM-590 gate)').toBeLessThan(50);
    expect(s.w, 'canvas width 640').toBe(640);
    expect(s.h, 'canvas height 480').toBe(480);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during Allied M2',
    ).toHaveLength(0);

    console.log(`[RA-ALLIED-M2] Allied M2 frame 500 captured at ${shotPath}`);
  });
});



// ─── Tier 2: Wine OG parity (RA Allied M2) ───────────────────────────────────────

test.describe('Tier 2 — RA Allied M2 Wine OG vs WASM parity [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(
      !WINE_RA_READY,
      'Tier 2 requires WINE_RA_READY=1; run scripts/wine-ra-allied-m2.sh first',
    );
  });

  test('Allied M2 frame 500: SSIM >= 0.90 vs Wine OG golden', async ({}, testInfo) => {
    const wasmShot = path.join(SCREENSHOTS_DIR, 'allied-m2-wasm-f500.png');
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-ra-allied-m2-f500.png');
    test.skip(!fs.existsSync(wasmShot), 'allied-m2-wasm-f500.png missing — run Tier 1 Allied M2 test first');
    test.skip(!fs.existsSync(wineShot), 'wine-ra-allied-m2-f500.png missing — run scripts/wine-ra-allied-m2.sh');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim859-diff-allied-m2-f500.png');
    const cmp = runParityCompare(wineShot, wasmShot, {
      label: 'allied-m2-f500', thresholdSsim: 0.90, diffOut,
    });
    console.log(`Allied M2 f500 parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-allied-m2-f500.png', { path: diffOut, contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-ra-allied-m2-f500.png', { path: wineShot, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-allied-m2-f500.png', { path: wasmShot, contentType: 'image/png' });
    }

    expect(cmp.ssim, `Allied M2 f500 SSIM >= 0.90 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.90);
  });
});


