import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL       = 'http://localhost:8080/ra.html';
const ASSET_URL      = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

async function waitForOutput(page: any, substring: string, timeoutMs = 600_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,
    { timeout: timeoutMs },
  );
}

async function canvasStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fill: 0, uniqueColors: 0, w: 0, h: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, uniqueColors: 0, w: canvas.width, h: canvas.height };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / (data.length / 4) * 100), uniqueColors: colorSet.size, w, h };
  });
}

const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

test('TIM-772 — Capture difficulty selector without auto-accept', async ({ page }) => {
  test.setTimeout(900_000);

  const consoleLogs: string[] = [];
  page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

  console.log(`[TIM-772] Loading (no auto-accept): ${menuUrl}`);
  await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 120_000 },
  );
  console.log('[TIM-772] Preloader done');

  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
  console.log('[TIM-772] Init_Bulk_Data done');

  const colorDiag = await page.evaluate(() => {
    try {
      const FS = (window as any).FS;
      if (FS && FS.analyzePath) {
        const info = FS.analyzePath('/game/COLOR_DIAG.TXT');
        if (info && info.exists) {
          const data = FS.readFile('/game/COLOR_DIAG.TXT', { encoding: 'utf8' });
          return data;
        }
      }
      return null;
    } catch (e) {
      return 'ERROR: ' + String(e);
    }
  });
  console.log(`[TIM-772-DIAG] COLOR_DIAG.TXT: ${colorDiag || 'NOT FOUND'}`);

  await waitForOutput(page, '[TIM-616] menu_cs=', 600_000);
  await page.waitForTimeout(4_000);
  console.log('[TIM-772] Menu ready after VQAs');

  const s1 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim772-noauto-01-menu.png') });
  console.log(`[TIM-772] Menu: ${s1.w}x${s1.h} fill=${s1.fill}% colors=${s1.uniqueColors}`);

  console.log('[TIM-772] Clicking "Start New Game" at (161, 103)');
  await page.click('#canvas', { position: { x: 161, y: 103 } });

  await waitForOutput(page, '[DIFF] dialog ready', 30_000);
  await page.waitForTimeout(2_000);
  console.log('[TIM-772] Difficulty dialog ready');

  const s2 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim772-noauto-02-difficulty.png') });
  console.log(`[TIM-772] Difficulty: ${s2.w}x${s2.h} fill=${s2.fill}% colors=${s2.uniqueColors}`);

  console.log('[TIM-772] Clicking OK on difficulty at (237, 122)');
  await page.click('#canvas', { position: { x: 237, y: 122 } });

  await waitForOutput(page, '[INIT] faction dialog ready', 30_000);
  await page.waitForTimeout(2_000);
  console.log('[TIM-772] Faction dialog ready');

  const s3 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim772-noauto-03-faction.png') });
  console.log(`[TIM-772] Faction: ${s3.w}x${s3.h} fill=${s3.fill}% colors=${s3.uniqueColors}`);

  const jsErrors = consoleLogs.filter(l =>
    l.startsWith('[pageerror]') && !l.includes('ResizeObserver'));
  expect(jsErrors, 'no JS errors').toHaveLength(0);
  expect(s2.fill, 'difficulty dialog has content').toBeGreaterThan(5);
  expect(s2.uniqueColors, 'difficulty dialog has colors').toBeGreaterThan(5);
  expect(s3.fill, 'faction dialog has content').toBeGreaterThan(5);
  expect(s3.uniqueColors, 'faction dialog has colors').toBeGreaterThan(5);
});
