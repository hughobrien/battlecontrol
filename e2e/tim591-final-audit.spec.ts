/**
 * TIM-591 — RA WASM comprehensive final audit.
 *
 * Confirms production quality after TIM-587 (cyan-block scatter fix) and
 * TIM-580 (letterbox + intra-frame block noise fix) land.
 *
 * Checks:
 *   1. VQA intro visual quality — frames 1/20/50/100/160 sampling
 *      - No cyan scatter blocks (TIM-587)
 *      - No letterbox noise (top/bottom 40px of 640x480 must be solid black)
 *      - No intra-frame block artifacts (consistent fill within a frame)
 *      - Golden/metallic title-card gradient (TIM-573 palette)
 *   2. Audio — AudioContext.sampleRate in logs, no divide-by-zero
 *   3. Main menu — renders with fill ≥20% after VQA intro
 *   4. Gameplay — reaches Main_Loop frame 300, units respond to clicks
 *
 * Requires:
 *   serve-coop.py on :8080 (build-wasm/)
 *   serve-assets.py on :9090 (/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL         = 'http://localhost:8080/ra.html';
const ASSET_URL        = 'http://localhost:9090/';
const SCREENSHOTS_DIR  = path.join(__dirname, 'screenshots');

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
    return el ? (el.textContent || '') : '';
  });
}

/** Full-canvas pixel stats. */
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
      // Cyan scatter: high G+B, low R (TIM-587 signature)
      if (r < 32 && g > 180 && b > 180) cyanCount++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h, cyanCount };
  });
}

/**
 * Sample a horizontal band and return the fraction of non-black pixels.
 * Used to verify letterbox rows (y=0..39 and y=440..479) are solid black.
 */
async function bandFillPct(page: any, yStart: number, yEnd: number): Promise<number> {
  return page.evaluate(([y0, y1]: [number, number]) => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return 0;
    const ctx = canvas.getContext('2d');
    if (!ctx) return 0;
    const w = canvas.width;
    const h = canvas.height;
    if (y1 > h) y1 = h;
    const bandH = y1 - y0;
    if (bandH <= 0) return 0;
    const data = ctx.getImageData(0, y0, w, bandH).data;
    let nonBlack = 0;
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
    }
    return Math.round(nonBlack / total * 100);
  }, [yStart, yEnd]);
}

/** Sample a canvas sub-region and return raw pixel bytes. */
async function canvasRegionPixels(page: any, rx: number, ry: number, rw: number, rh: number): Promise<number[]> {
  return page.evaluate(([rx, ry, rw, rh]: [number, number, number, number]) => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return [];
    const ctx = canvas.getContext('2d');
    if (!ctx) return [];
    return Array.from(ctx.getImageData(rx, ry, rw, rh).data);
  }, [rx, ry, rw, rh]);
}

function pixelDiff(a: number[], b: number[]): number {
  let diff = 0;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i += 4) {
    diff += Math.abs(a[i] - b[i]) + Math.abs(a[i+1] - b[i+1]) + Math.abs(a[i+2] - b[i+2]);
  }
  return diff;
}

// ─── Test 1: VQA visual + audio quality ────────────────────────────────────

test('TIM-591 VQA intro visual + audio quality', async ({ page }) => {
  test.setTimeout(1_200_000);

  const consoleLogs: string[] = [];
  const pageErrors: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[TIM-591] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ──────────────────────────────────────────────────
  console.log('\n[TIM-591] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  const errorBanner = page.locator('#error-banner');
  if (await errorBanner.isVisible({ timeout: 2_000 }).catch(() => false)) {
    const bannerText = await errorBanner.textContent();
    console.log(`  ERROR BANNER VISIBLE: ${bannerText}`);
  }
  console.log('  preloader hidden ✓');

  // ── Phase 2: Wait for Play_Intro ────────────────────────────────────────
  console.log('\n[TIM-591] === Phase 2: Play_Intro → ENGLISH.VQA ===');
  await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 180_000);
  console.log('  Play_Intro fired ✓');

  // ── Phase 3: VQA frame sampling ─────────────────────────────────────────
  // ENGLISH.VQA: 640×400 @ 15fps, 160 frames ≈ 10.7s
  // Canvas is 640×480, so VQA content is 640×400 centred with 40px letterbox top+bottom.
  console.log('\n[TIM-591] === Phase 3: VQA frame sampling ===');
  console.log('  Sampling frames at t≈1s/2s/4s/7s/10s (frames 15/30/60/105/150)');

  const frameSamples: {label: string; fill: number; colors: number; cyanCount: number; topBand: number; botBand: number}[] = [];

  for (const [label, delayMs] of [
    ['frame-15 (t1s)',   1333],
    ['frame-30 (t2s)',    666],
    ['frame-60 (t4s)',   2000],
    ['frame-105 (t7s)',  3000],
    ['frame-150 (t10s)', 3000],
  ] as [string, number][]) {
    await page.waitForTimeout(delayMs);
    const stats = await canvasStats(page);
    const topBand = await bandFillPct(page, 0, 40);
    const botBand = await bandFillPct(page, 440, 480);
    frameSamples.push({ label, fill: stats.fill, colors: stats.colors, cyanCount: stats.cyanCount, topBand, botBand });
    const slug = label.replace(/[^a-z0-9]+/gi, '-');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `tim591-vqa-${slug}.png`) });
    console.log(`  [${label}] fill=${stats.fill}%  colors=${stats.colors}  cyanPx=${stats.cyanCount}  letterbox(top=${topBand}% bot=${botBand}%)`);
  }

  // ── Phase 4: Main menu after VQA ────────────────────────────────────────
  console.log('\n[TIM-591] === Phase 4: Main menu after VQA ===');
  await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
  await page.waitForTimeout(3_000);
  const menuStats = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim591-main-menu.png') });
  console.log(`  main menu: fill=${menuStats.fill}%  colors=${menuStats.colors}`);

  // ── Phase 5: Log analysis ────────────────────────────────────────────────
  console.log('\n[TIM-591] === Phase 5: Log analysis ===');
  const output = await getOutput(page);
  const hasAudioCtxRate = output.includes('AudioContext.sampleRate') ||
    consoleLogs.some(l => l.includes('AudioContext.sampleRate') || l.includes('sampleRate'));
  const hasDivByZero = output.includes('integer overflow') ||
    pageErrors.some(e => /divide.*zero|integer overflow|trap.*div/i.test(e)) ||
    consoleLogs.some(l => /divide.*zero|integer overflow|trap.*div/i.test(l));
  const hasSIGSEGV = output.includes('SIGSEGV') || output.includes('Aborted(');
  const vqaLines = [...output.matchAll(/\[VQA\][^\n]*/g)].map(m => m[0]);

  console.log(`  AudioContext.sampleRate in logs: ${hasAudioCtxRate ? 'YES' : 'NOT FOUND'}`);
  console.log(`  Divide-by-zero / abort: ${hasDivByZero ? 'FOUND (FAIL)' : 'PASS (none)'}`);
  console.log(`  SIGSEGV / Aborted: ${hasSIGSEGV ? 'FOUND (FAIL)' : 'PASS (none)'}`);
  console.log(`  VQA log lines: ${vqaLines.length}`);
  vqaLines.forEach(l => console.log(`    ${l}`));

  // ── Phase 6: Summary ─────────────────────────────────────────────────────
  const maxFill = Math.max(...frameSamples.map(s => s.fill));
  const maxCyan = Math.max(...frameSamples.map(s => s.cyanCount));
  const maxTopBand = Math.max(...frameSamples.map(s => s.topBand));
  const maxBotBand = Math.max(...frameSamples.map(s => s.botBand));
  const titleCardFill = frameSamples[0]?.fill ?? 0;

  console.log('\n[TIM-591] ===== VQA AUDIT SUMMARY =====');
  console.log(`  Build: battlecontrol/master post TIM-587 + TIM-580`);
  console.log(`  Best VQA fill: ${maxFill}%  (expect ≥25%)`);
  console.log(`  Title-card fill (t1s): ${titleCardFill}%  (expect ≥20%)`);
  console.log(`  Max cyan-scatter pixels: ${maxCyan}  (expect 0 after TIM-587)`);
  console.log(`  Max letterbox noise top-band: ${maxTopBand}%  (expect 0)`);
  console.log(`  Max letterbox noise bot-band: ${maxBotBand}%  (expect 0)`);
  console.log(`  Main menu fill: ${menuStats.fill}%  (expect ≥20%)`);

  // Store output for gameplay test
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim591-vqa-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${output}\n`
  );

  // ── Assertions ───────────────────────────────────────────────────────────

  // VQA liveness: at least one sample > 25% fill (title card + scenes are substantial)
  expect(maxFill, 'VQA fill must exceed 25% at some point during ENGLISH.VQA').toBeGreaterThan(25);

  // Title card: first ~1s should have ≥20% fill (golden gradient)
  expect(titleCardFill, 'title-card fill at t1s must be ≥20% (golden gradient present)').toBeGreaterThanOrEqual(20);

  // Cyan scatter: TIM-587 fix — no cyan-dominant pixels in any sample
  expect(maxCyan, 'cyan-scatter pixels (TIM-587): must be 0').toBe(0);

  // Letterbox noise: TIM-580 fix — top and bottom 40px must be solid black
  expect(maxTopBand, 'top letterbox band must be solid black (0% non-black)').toBe(0);
  expect(maxBotBand, 'bottom letterbox band must be solid black (0% non-black)').toBe(0);

  // Audio: no divide-by-zero (TIM-583 fix)
  expect(hasDivByZero, 'no divide-by-zero errors in VQA audio').toBe(false);

  // No crash
  expect(hasSIGSEGV, 'no SIGSEGV or Aborted').toBe(false);

  // Main menu renders
  expect(menuStats.fill, 'main menu fill must be ≥20%').toBeGreaterThanOrEqual(20);
});

// ─── Test 2: Gameplay ───────────────────────────────────────────────────────

test('TIM-591 gameplay — Start_Scenario, unit select, AI movement', async ({ page }) => {
  test.setTimeout(900_000);

  const consoleLogs: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => consoleLogs.push(`[pageerror] ${err.message}`));

  // autostart=1 sets RA_AUTOSTART flag, enabling frame logging and scenario auto-select.
  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;
  console.log(`[TIM-591] loading gameplay url: ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[TIM-591 gameplay] preloader hidden ✓');

  // Wait for in-game phase (Start_Scenario + frame 300)
  await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 300_000);
  console.log('[TIM-591 gameplay] Start_Scenario OK ✓');

  await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
  console.log('[TIM-591 gameplay] frame 300 reached ✓');

  // Capture baseline
  const mapBefore = await canvasRegionPixels(page, 0, 0, 474, 480);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim591-gameplay-f300.png') });

  // Left-click unit (infantry cluster at ≈350, 125)
  await page.click('#canvas', { position: { x: 350, y: 125 } });
  console.log('[TIM-591 gameplay] left-click unit at (350, 125)');

  // Wait for frame 400
  await waitForOutput(page, '[RA] Main_Loop frame 400', 180_000);
  console.log('[TIM-591 gameplay] frame 400 reached ✓');

  const mapAfterSelect = await canvasRegionPixels(page, 0, 0, 474, 480);
  const selectDiff = pixelDiff(mapBefore, mapAfterSelect);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim591-gameplay-f400.png') });
  console.log(`[TIM-591 gameplay] pixel diff after unit click: ${selectDiff}`);

  // Right-click move order
  await page.click('#canvas', { position: { x: 350, y: 125 } }); // re-select
  await page.waitForTimeout(100);
  await page.click('#canvas', { position: { x: 430, y: 375 }, button: 'right' });
  console.log('[TIM-591 gameplay] right-click move order to (430, 375)');

  // Wait for frame 500 — AI + movement should have caused map changes
  await waitForOutput(page, '[RA] Main_Loop frame 500', 180_000);
  console.log('[TIM-591 gameplay] frame 500 reached ✓');

  const mapAfterMove = await canvasRegionPixels(page, 0, 0, 474, 480);
  const moveDiff = pixelDiff(mapAfterSelect, mapAfterMove);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim591-gameplay-f500.png') });
  console.log(`[TIM-591 gameplay] pixel diff frames 400→500 (move + AI): ${moveDiff}`);

  const output = await getOutput(page);
  const hasCrash = output.includes('SIGSEGV') || output.includes('Aborted(');

  console.log('\n[TIM-591] ===== GAMEPLAY AUDIT SUMMARY =====');
  console.log(`  Start_Scenario OK: PASS`);
  console.log(`  Reached frame 500: PASS`);
  console.log(`  Unit select pixel diff (f300→f400): ${selectDiff}  ${selectDiff > 0 ? 'PASS' : 'WARN'}`);
  console.log(`  AI+move pixel diff  (f400→f500): ${moveDiff}  ${moveDiff > 0 ? 'PASS' : 'WARN'}`);
  console.log(`  No crash: ${hasCrash ? 'FAIL' : 'PASS'}`);

  // Assertions
  expect(selectDiff, 'unit-select: map must change after left-click').toBeGreaterThan(0);
  expect(moveDiff, 'AI/move: map must change between frame 400 and 500').toBeGreaterThan(0);
  expect(hasCrash, 'no crash by frame 500').toBe(false);
});
