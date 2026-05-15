/**
 * TIM-711 — Tiberian Dawn OG binary baseline comparison tests.
 *
 * Mirrors tim699-ra-compare.spec.ts for Red Alert but targets the TD WASM port
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
 *
 * Tier 3 (Wine — skipped unless WINE_TD_READY=1 + C&C95.EXE present):
 *   - OG title-screen screenshot present (wine-td-title.png > 5 KB)
 *   - OG menu screenshot present (wine-td-menu.png > 5 KB)
 *   - WASM menu fill ≥ 30 % (parity sanity)
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
 *
 * Reference data:
 *   scripts/td-data-verify.py   — MIX checksum verification
 *   scripts/wine-td-setup.sh    — C&C95.EXE extraction from IS v3 Z archive
 *   scripts/wine-td.sh          — Wine prefix setup + OG screenshot capture
 */

import { test, expect } from '@playwright/test';
import * as child_process from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const WASM_BASE_URL   = 'http://localhost:8080/td.html';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const REPO_ROOT       = path.resolve(__dirname, '..');
const DATA_DIR        = '/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1';

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
    { timeout: timeoutMs }
  );
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
    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=0`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);

    // Wait for intro / title to clear and menu to render.
    await waitForOutput(page, '[TD] Main_Loop frame', 90_000);
    await page.waitForTimeout(3_000);

    const menuStats = await canvasStats(page);
    console.log(`Menu canvas: fill=${menuStats.fill}% colors=${menuStats.colors}`);
    expect(menuStats.fill, 'menu fill ≥30%').toBeGreaterThanOrEqual(30);

    const shot = path.join(SCREENSHOTS_DIR, 'tim711-wasm-menu.png');
    await page.screenshot({ path: shot });
    console.log(`Screenshot: ${shot}`);
  });
});

// ─── Tier 3: Wine / OG comparison (skipped unless WINE_TD_READY=1) ───────────

test.describe('Tier 3 — Wine OG comparison [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(!WINE_TD_READY,
      'Wine tier requires WINE_TD_READY=1 + wine32 + C&C95.EXE at /opt/tiberiandawn/C&C95.EXE');
  });

  test('OG title screen captured by wine-td.sh', () => {
    const shot = path.join(SCREENSHOTS_DIR, 'wine-td-title.png');
    expect(
      fs.existsSync(shot),
      `wine-td-title.png not found — run: bash scripts/wine-td.sh`
    ).toBe(true);

    const size = fs.statSync(shot).size;
    console.log(`wine-td-title.png: ${size} bytes`);
    expect(size, 'screenshot should be > 5 KB (non-trivial frame)').toBeGreaterThan(5_000);
  });

  test('OG menu screenshot present and WASM parity', async ({ page }) => {
    const ogShot = path.join(SCREENSHOTS_DIR, 'wine-td-menu.png');
    test.skip(!fs.existsSync(ogShot), 'wine-td-menu.png missing — run wine-td.sh first');
    test.skip(!HAS_ASSETS,
      'WASM comparison skipped — no game assets');

    await page.goto(`${WASM_BASE_URL}?${WASM_PARAMS}autostart=0`, { timeout: 120_000 });
    await waitForOutput(page, 'WASM_READY', 120_000);
    await waitForOutput(page, '[TD] Main_Loop frame', 60_000);
    await page.waitForTimeout(3_000);

    const wasmStats = await canvasStats(page);
    console.log(`WASM menu fill: ${wasmStats.fill}%`);

    const ogSize = fs.statSync(ogShot).size;
    console.log(`OG menu screenshot: ${ogSize} bytes`);
    expect(ogSize, 'OG menu screenshot should be > 5 KB').toBeGreaterThan(5_000);
    expect(wasmStats.fill, 'WASM menu fill should be ≥30%').toBeGreaterThanOrEqual(30);
  });
});
