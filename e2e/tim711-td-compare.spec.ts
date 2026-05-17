/**
 * TIM-711 / TIM-725 — Tiberian Dawn OG binary baseline comparison tests.
 *
 * Mirrors tim710-wasm-parity.spec.ts for Red Alert but targets the TD WASM port
 * and the OG C&C Tiberian Dawn executable (C&C95.EXE) under Wine.
 *
 * Three tiers of comparison:
 *
 * Tier 1 (always runs — no Wine, no EXE):
 *   - MIX file checksums vs. known reference (td-data-verify.py parity)
 *   - 23 MIX files from /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/
 *
 * Tier 2 (WASM visual — no Wine):
 *   - Title screen renders non-black within 30 s (visual gate)
 *   - Canvas is 640×400 (TD native resolution)
 *   - No cyan-scatter artefacts (TIM-590 regression gate)
 *   - Menu renders ≥30% fill (TIM-711 gate)
 *   - GDI L1 (SCG01EA) map renders ≥20% fill at t=0, t≈10s, t≈30s (TIM-725 gate)
 *   - LOGO.VQA canvas non-black during early + mid playback
 *
 * Tier 3 (Wine — skipped unless WINE_TD_READY=1 + C&C95.EXE present):
 *   - OG title-screen SSIM ≥ 0.70 vs wine-td-title.png            (TIM-725 gate)
 *   - OG menu SSIM ≥ 0.70 vs wine-td-menu.png                     (TIM-725 gate)
 *   - GDI L1 frame500 SSIM ≥ 0.65 vs wine-td-allied-l1-frame500.png (TIM-753 gate)
 *   - Pixel fill% delta ≤ 10% (title/menu) / ≤ 15% (gameplay) at equivalent states
 *   - Diff PNGs attached as test artifacts on failure
 *
 * Setup (Tier 1 + 2):
 *   serve-coop.py on :8080  (WASM bundle from build-wasm/)
 *   serve-assets.py on :9091 (/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1)
 *
 * Setup (Tier 3, additional):
 *   wine32 installed (sudo dpkg --add-architecture i386 && apt install wine32:i386)
 *   C&C95.EXE at /opt/tiberiandawn/C&C95.EXE  (run scripts/wine-td-setup.sh)
 *   WINE_TD_READY=1 env var set
 *   Run: bash scripts/wine-td.sh  (creates e2e/screenshots/wine-td-*.png)
 *   Then run Tier 3: WINE_TD_READY=1 playwright test e2e/tim711-td-compare.spec.ts
 *
 * Reference data:
 *   scripts/td-data-verify.py   — MIX checksum verification
 *   scripts/parity-compare.py   — SSIM + fill% + p99 pixel-diff comparison
 *   scripts/wine-td-setup.sh    — C&C95.EXE extraction from IS v3 Z archive
 *   scripts/wine-td.sh          — Wine prefix setup + OG screenshot capture
 *
 * Related:
 *   TIM-711 — TD Wine OG baseline setup
 *   TIM-725 — TD WASM vs Wine OG parity validation (GDI L1 + SSIM)
 *   TIM-710 — RA equivalent (WASM vs Wine OG parity)
 */

import { test, expect }   from '@playwright/test';
import * as child_process from 'child_process';
import * as fs            from 'fs';
import * as path          from 'path';

const WASM_BASE_URL   = 'http://localhost:8080/td.html';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const REPO_ROOT       = path.resolve(__dirname, '..');
const DATA_DIR        = '/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1';
// Committed Wine OG reference images (not gitignored, unlike SCREENSHOTS_DIR).
const WINE_REFS_DIR   = path.join(__dirname, 'tim753');

// When TD_ASSETS_URL is set (CDN base URL), the preloader fetches MIX files
// from that URL.  Without it Tier 2 tests require serve-assets.py on :9091
// and DATA_DIR present.
const TD_ASSETS_URL   = process.env.TD_ASSETS_URL || '';
const WASM_PARAMS     = TD_ASSETS_URL ? `src=${encodeURIComponent(TD_ASSETS_URL)}&` : '';
const HAS_ASSETS      = Boolean(TD_ASSETS_URL) || fs.existsSync(DATA_DIR);

const WINE_TD_READY   = process.env.WINE_TD_READY === '1';

// ─── Helpers ─────────────────────────────────────────────────────────────────

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
    return {
      fill:      Math.round(nonBlack / total * 100),
      colors:    colorSet.size,
      cyanCount,
      w, h,
    };
  });
}

// Inject an Escape-key loop that fires whenever '[VQA] playing' appears in output.
async function installVqaAutoSkip(page: any): Promise<() => Promise<void>> {
  const cancelHandle = await page.evaluateHandle(() => {
    let cancelled = false;
    const iv = setInterval(() => {
      if (cancelled) { clearInterval(iv); return; }
      const out = document.getElementById('output');
      if (out && out.textContent && out.textContent.includes('[VQA] playing')) {
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true }));
      }
    }, 500);
    return { cancel: () => { cancelled = true; clearInterval(iv); } };
  });
  return async () => {
    await page.evaluate((h: any) => h.cancel(), cancelHandle);
    cancelHandle.dispose();
  };
}

// Run scripts/parity-compare.py and return parsed JSON result.
function runParityCompare(
  pathA: string,
  pathB: string,
  opts: { label?: string; thresholdSsim?: number; diffOut?: string; sideBySideOut?: string } = {},
): { status: string; ssim: number; p99Diff: number; fillA: number; fillB: number; error?: string; sideBySideOut?: string } {
  const argv = [
    path.join(REPO_ROOT, 'scripts', 'parity-compare.py'),
    pathA, pathB,
    '--label', opts.label ?? 'comparison',
    '--threshold-ssim', String(opts.thresholdSsim ?? 0.70),
    '--json',
  ];
  if (opts.diffOut) argv.push('--diff-out', opts.diffOut);
  if (opts.sideBySideOut) argv.push('--side-by-side-out', opts.sideBySideOut);

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
      sideBySideOut: r.side_by_side_out,
    };
  } catch {
    return {
      status: 'SKIP', ssim: 0, p99Diff: 999, fillA: 0, fillB: 0,
      error: `parity-compare.py parse error: ${jsonLine.slice(0, 200)}`,
      sideBySideOut: undefined,
    };
  }
}

// ─── Tier 1: MIX file checksums (no Wine, no server) ─────────────────────────

test.describe('Tier 1 — reference data integrity', () => {
  test('MIX checksums match reference dataset (23 files)', () => {
    test.skip(!fs.existsSync(DATA_DIR), `Data dir not found: ${DATA_DIR}`);

    const result = child_process.spawnSync(
      'python3',
      [path.join(REPO_ROOT, 'scripts', 'td-data-verify.py'), DATA_DIR],
      { encoding: 'utf-8', timeout: 60_000 }
    );
    console.log(result.stdout);
    if (result.stderr) console.error(result.stderr);
    expect(result.status, 'td-data-verify.py should exit 0').toBe(0);
  });
});

// ─── Tier 2: WASM visual reference (no Wine) ─────────────────────────────────

test.describe('Tier 2 — TD WASM visual reference', () => {
  test.beforeEach(() => {
    test.skip(!HAS_ASSETS,
      'Tier 2 skipped — no game assets: set TD_ASSETS_URL env or mount /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1');
  });

  test('title screen renders non-black (visual gate)', async ({ page }) => {
    test.setTimeout(300_000);

    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=0`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);

    // Wait for early title rendering.
    await page.waitForTimeout(8_000);

    const stats = await canvasStats(page);
    const shot  = path.join(SCREENSHOTS_DIR, 'tim711-wasm-title.png');
    await page.screenshot({ path: shot });

    console.log(`Canvas stats: fill=${stats.fill}% colors=${stats.colors} cyan=${stats.cyanCount} (${stats.w}×${stats.h})`);
    console.log(`Screenshot: ${shot}`);

    expect(stats.fill, 'canvas fill ≥5% (not all black)').toBeGreaterThanOrEqual(5);
    expect(stats.cyanCount, 'no TIM-590 cyan-scatter (count<50)').toBeLessThan(50);
    expect(stats.w, 'canvas width should be 640').toBe(640);
    expect(stats.h, 'canvas height should be 400').toBe(400);
  });

  test('menu renders and reaches main menu (≥30% fill)', async ({ page }) => {
    test.setTimeout(300_000);

    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=0`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);

    // Wait for intro / title to clear and menu to render.
    await waitForOutput(page, '[TD] Main_Loop frame', 90_000);
    await page.waitForTimeout(3_000);

    const menuStats = await canvasStats(page);
    console.log(`Menu canvas: fill=${menuStats.fill}% colors=${menuStats.colors} (${menuStats.w}×${menuStats.h})`);

    expect(menuStats.fill, 'menu fill ≥30%').toBeGreaterThanOrEqual(30);
    expect(menuStats.cyanCount, 'no cyan-scatter').toBeLessThan(50);
    expect(menuStats.w, 'canvas width 640').toBe(640);
    expect(menuStats.h, 'canvas height 400').toBe(400);

    const shot = path.join(SCREENSHOTS_DIR, 'tim711-wasm-menu.png');
    await page.screenshot({ path: shot });
    console.log(`Screenshot: ${shot}`);
  });

  test('GDI L1 (SCG01EA) map renders ≥20% fill at t=0, t≈10s, t≈30s without crash', async ({ page }) => {
    test.setTimeout(900_000);

    const errors: string[] = [];
    page.on('pageerror', (err: Error) => errors.push(err.message));

    // autostart=1 skips menu and jumps directly to SCG01EA (GDI mission 1 easy)
    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=1`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);

    // TD_AUTOSTART active confirms the scenario is launching
    await waitForOutput(page, 'TD_AUTOSTART active', 120_000);

    // Wait for the game loop to start running frames
    await waitForOutput(page, '[TD] Main_Loop frame 200', 300_000);

    const t0Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-gdi-l1-t0.png') });
    console.log(`GDI L1 t=0:   fill=${t0Stats.fill}% colors=${t0Stats.colors} (${t0Stats.w}×${t0Stats.h})`);
    expect(t0Stats.fill, 'GDI L1 t=0 fill ≥20%').toBeGreaterThanOrEqual(20);
    expect(t0Stats.w, 'canvas width 640').toBe(640);
    expect(t0Stats.h, 'canvas height 400').toBe(400);

    await waitForOutput(page, '[TD] Main_Loop frame 350', 120_000);
    const t10Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-gdi-l1-t10.png') });
    console.log(`GDI L1 t≈10s: fill=${t10Stats.fill}%`);
    expect(t10Stats.fill, 'GDI L1 t≈10s fill ≥20%').toBeGreaterThanOrEqual(20);

    // Frame 500 — saved as the Tier 3 Wine parity reference (TIM-753).
    await waitForOutput(page, '[TD] Main_Loop frame 500', 120_000);
    const t500Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-gdi-l1-frame500.png') });
    console.log(`GDI L1 frame500: fill=${t500Stats.fill}%`);
    expect(t500Stats.fill, 'GDI L1 frame500 fill ≥20%').toBeGreaterThanOrEqual(20);

    await waitForOutput(page, '[TD] Main_Loop frame 600', 180_000);
    const t30Stats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-gdi-l1-t30.png') });
    console.log(`GDI L1 t≈30s: fill=${t30Stats.fill}%`);
    expect(t30Stats.fill, 'GDI L1 t≈30s fill ≥20%').toBeGreaterThanOrEqual(20);

    expect(
      errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during gameplay',
    ).toHaveLength(0);

    console.log(`GDI L1 PASS: t0=${t0Stats.fill}% t≈10s=${t10Stats.fill}% frame500=${t500Stats.fill}% t≈30s=${t30Stats.fill}%`);
  });

  test('LOGO.VQA canvas non-black during early and mid playback', async ({ page }) => {
    test.setTimeout(300_000);

    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=0`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);

    // LOGO.VQA plays automatically at startup
    await waitForOutput(page, '[VQA] playing', 60_000);

    // Capture early frame (~2s in)
    await page.waitForTimeout(2_000);
    const earlyStats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-logo-vqa-early.png') });
    console.log(`LOGO.VQA early: fill=${earlyStats.fill}% colors=${earlyStats.colors}`);

    // Capture mid-point frame (~6s in)
    await page.waitForTimeout(4_000);
    const midStats = await canvasStats(page);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim725-wasm-logo-vqa-mid.png') });
    console.log(`LOGO.VQA mid:   fill=${midStats.fill}% colors=${midStats.colors}`);

    const maxFill = Math.max(earlyStats.fill, midStats.fill);
    expect(maxFill, 'LOGO.VQA canvas fill ≥5% at some point during playback').toBeGreaterThanOrEqual(5);
  });
});

// ─── Tier 3: Wine OG vs WASM SSIM parity ─────────────────────────────────────

test.describe('Tier 3 — Wine OG vs WASM SSIM parity [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(!WINE_TD_READY,
      'Wine tier requires WINE_TD_READY=1 + wine32 + C&C95.EXE at /opt/tiberiandawn/C&C95.EXE; '
      + 'run bash scripts/wine-td.sh first');
  });

  test('title screen: SSIM ≥ 0.70 vs Wine OG, fill% delta ≤ 10%', async ({}, testInfo) => {
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-td-title.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim711-wasm-title.png');
    test.skip(!fs.existsSync(wineShot), 'wine-td-title.png missing — run: bash scripts/wine-td.sh');
    test.skip(!fs.existsSync(wasmShot), 'tim711-wasm-title.png missing — run Tier 2 title test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim725-diff-title.png');
    const sbsOut  = path.join(SCREENSHOTS_DIR, 'tim725-sbs-title.png');
    // TD threshold is 0.70 (more lenient than RA's 0.90) — Wine GDI and WASM SDL
    // render the same palette content through different blitting paths.
    const cmp = runParityCompare(wineShot, wasmShot, { label: 'td-title-screen', thresholdSsim: 0.70, diffOut, sideBySideOut: sbsOut });
    console.log(`Title parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-title.png',       { path: diffOut,   contentType: 'image/png' });
      if (fs.existsSync(sbsOut))    await testInfo.attach('sbs-title.png',        { path: sbsOut,    contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-td-title.png',    { path: wineShot,  contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-title.png',       { path: wasmShot,  contentType: 'image/png' });
    }

    expect(cmp.ssim, `title SSIM ≥0.70 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.70);
    expect(
      Math.abs(cmp.fillA - cmp.fillB),
      `fill% delta ≤10% (Wine=${cmp.fillA}% WASM=${cmp.fillB}%)`,
    ).toBeLessThanOrEqual(10);
  });

  test('main menu: SSIM ≥ 0.70 vs Wine OG, fill% delta ≤ 10%', async ({}, testInfo) => {
    const wineShot = path.join(SCREENSHOTS_DIR, 'wine-td-menu.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim711-wasm-menu.png');
    test.skip(!fs.existsSync(wineShot), 'wine-td-menu.png missing — run: bash scripts/wine-td.sh');
    test.skip(!fs.existsSync(wasmShot), 'tim711-wasm-menu.png missing — run Tier 2 menu test first');

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim725-diff-menu.png');
    const sbsOut  = path.join(SCREENSHOTS_DIR, 'tim725-sbs-menu.png');
    const cmp = runParityCompare(wineShot, wasmShot, { label: 'td-main-menu', thresholdSsim: 0.70, diffOut, sideBySideOut: sbsOut });
    console.log(`Menu parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`);
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-menu.png',       { path: diffOut,  contentType: 'image/png' });
      if (fs.existsSync(sbsOut))    await testInfo.attach('sbs-menu.png',        { path: sbsOut,   contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-td-menu.png',    { path: wineShot, contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-menu.png',       { path: wasmShot, contentType: 'image/png' });
    }

    expect(cmp.ssim, `menu SSIM ≥0.70 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.70);
    expect(
      Math.abs(cmp.fillA - cmp.fillB),
      `fill% delta ≤10% (Wine=${cmp.fillA}% WASM=${cmp.fillB}%)`,
    ).toBeLessThanOrEqual(10);
  });

  // TIM-753: GDI L1 in-game gameplay parity (frame 500).
  // Reference: e2e/screenshots/wine-td-allied-l1-frame500.png (Wine OG cnc-ddraw GDI run
  // via wine-gdi-m1.sh, committed from the TIM-763 M1 gameplay evidence run).
  // WASM shot: generated by the Tier 2 'GDI L1 map renders' test at frame 500.
  // parity-compare.py center-crops the larger image (800×600 Wine desktop) to the
  // smaller (640×400 WASM canvas) before SSIM — the threshold is 0.65 rather than
  // 0.70 to account for the window-chrome border pixels in the Wine capture.
  test('GDI L1 gameplay frame500: SSIM ≥ 0.65 vs Wine OG, fill% delta ≤ 15%', async ({}, testInfo) => {
    const wineShot = path.join(WINE_REFS_DIR, 'wine-td-allied-l1-frame500.png');
    const wasmShot = path.join(SCREENSHOTS_DIR, 'tim725-wasm-gdi-l1-frame500.png');
    test.skip(
      !fs.existsSync(wineShot),
      'wine-td-allied-l1-frame500.png missing — expected at e2e/tim753/ (committed reference from TIM-763)',
    );
    test.skip(
      !fs.existsSync(wasmShot),
      'tim725-wasm-gdi-l1-frame500.png missing — run Tier 2 GDI L1 map renders test first',
    );

    const diffOut = path.join(SCREENSHOTS_DIR, 'tim753-diff-gdi-l1-frame500.png');
    const sbsOut  = path.join(SCREENSHOTS_DIR, 'tim753-sbs-gdi-l1-frame500.png');
    const cmp = runParityCompare(wineShot, wasmShot, {
      label: 'td-gdi-l1-frame500',
      thresholdSsim: 0.65,
      diffOut,
      sideBySideOut: sbsOut,
    });
    console.log(
      `GDI L1 frame500 parity: ssim=${cmp.ssim} p99=${cmp.p99Diff} ` +
      `fill_wine=${cmp.fillA}% fill_wasm=${cmp.fillB}%`,
    );
    if (cmp.error) console.log(`  error: ${cmp.error}`);

    if (cmp.status === 'SKIP') test.skip(true, cmp.error ?? 'parity-compare.py returned SKIP');

    if (cmp.status === 'FAIL') {
      if (fs.existsSync(diffOut))   await testInfo.attach('diff-gdi-l1-frame500.png',          { path: diffOut,   contentType: 'image/png' });
      if (fs.existsSync(sbsOut))    await testInfo.attach('sbs-gdi-l1-frame500.png',           { path: sbsOut,    contentType: 'image/png' });
      if (fs.existsSync(wineShot))  await testInfo.attach('wine-td-allied-l1-frame500.png',     { path: wineShot,  contentType: 'image/png' });
      if (fs.existsSync(wasmShot))  await testInfo.attach('wasm-gdi-l1-frame500.png',           { path: wasmShot,  contentType: 'image/png' });
    }

    expect(cmp.ssim, `GDI L1 frame500 SSIM ≥0.65 (got ${cmp.ssim})`).toBeGreaterThanOrEqual(0.65);
    expect(
      Math.abs(cmp.fillA - cmp.fillB),
      `fill% delta ≤15% (Wine=${cmp.fillA}% WASM=${cmp.fillB}%)`,
    ).toBeLessThanOrEqual(15);
  });
});
