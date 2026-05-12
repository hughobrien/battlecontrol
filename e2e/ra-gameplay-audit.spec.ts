/**
 * TIM-480 — RA WASM in-game gameplay audit.
 *
 * Tests run against a live WASM bundle served by serve-coop.py (port 8080),
 * with MIX assets served by serve-assets.py (port 9090).
 *
 * Gameplay systems under audit:
 *   1. Sidebar       — renders with icons; clicking structure/unit tabs responds
 *   2. Unit control  — left-click selects a unit; right-click issues move order
 *   3. Enemy AI      — map changes between frames (unit movement / attack)
 *   4. Fog of war    — fog patches present and updating
 *   5. Win/loss      — no premature victory/defeat triggers
 *
 * Canvas coordinate system (640x480):
 *   Map area     : x=0..474, y=0..479
 *   Sidebar      : x=475..639, y=0..479
 *     Radar      : x≈480..560, y≈0..80
 *     Tabs       : x≈480..640, y≈80..130
 *     Icons col1 : x≈485..545, y≈130..395
 *     Icons col2 : x≈555..615, y≈130..395
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL  = 'http://localhost:8080/ra.html';
const ASSET_URL = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

/** Append text to #output and return the full string. */
async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent || '' : '';
  });
}

/** Wait for a substring in #output. */
async function waitForOutput(page: any, substring: string, timeoutMs = 180_000) {
  await page.waitForFunction(
    (s: string) => {
      const el = document.getElementById('output');
      return el !== null && el.textContent !== null && el.textContent.includes(s);
    },
    substring,
    { timeout: timeoutMs }
  );
}

/** Sample a rectangular region of the canvas and return pixel statistics. */
async function sampleCanvasRegion(
  page: any,
  rx: number, ry: number, rw: number, rh: number
): Promise<{ nonBlack: number; total: number; fillPct: number; uniqueColors: number }> {
  return page.evaluate(
    ([rx, ry, rw, rh]: [number, number, number, number]) => {
      const canvas = document.getElementById('canvas') as HTMLCanvasElement;
      if (!canvas) return { nonBlack: 0, total: 0, fillPct: 0, uniqueColors: 0 };
      const ctx = canvas.getContext('2d');
      if (!ctx) return { nonBlack: 0, total: 0, fillPct: 0, uniqueColors: 0 };
      const d = ctx.getImageData(rx, ry, rw, rh).data;
      let nb = 0;
      const cs = new Set<number>();
      for (let i = 0; i < d.length; i += 4) {
        const r = d[i], g = d[i + 1], b = d[i + 2];
        if (r > 15 || g > 15 || b > 15) nb++;
        cs.add((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4));
      }
      const total = d.length / 4;
      return { nonBlack: nb, total, fillPct: Math.round(nb / total * 100), uniqueColors: cs.size };
    },
    [rx, ry, rw, rh]
  );
}

/** Read raw pixel data (as flat RGBA array) for a region — used for diff comparisons. */
async function canvasRegionPixels(
  page: any,
  rx: number, ry: number, rw: number, rh: number
): Promise<number[]> {
  return page.evaluate(
    ([rx, ry, rw, rh]: [number, number, number, number]) => {
      const canvas = document.getElementById('canvas') as HTMLCanvasElement;
      if (!canvas) return [];
      const ctx = canvas.getContext('2d');
      if (!ctx) return [];
      return Array.from(ctx.getImageData(rx, ry, rw, rh).data);
    },
    [rx, ry, rw, rh]
  );
}

/** Count pixels that differ between two RGBA arrays (by threshold). */
function pixelDiff(a: number[], b: number[], threshold = 20): number {
  if (a.length !== b.length) return -1;
  let diff = 0;
  for (let i = 0; i < a.length; i += 4) {
    if (Math.abs(a[i] - b[i]) > threshold ||
        Math.abs(a[i+1] - b[i+1]) > threshold ||
        Math.abs(a[i+2] - b[i+2]) > threshold) {
      diff++;
    }
  }
  return diff;
}

// ---------------------------------------------------------------------------
// Game enters in-game phase with RA_AUTOSTART.
// Sidebar starts in "Structure" build mode by default.
// ---------------------------------------------------------------------------

const gameUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&autostart=1`;

test.describe('TIM-480 — RA WASM gameplay audit', () => {
  test.setTimeout(600_000);   // 10 min: frame 600 takes ~60s after ~4min asset load

  test('gameplay audit: sidebar, unit control, AI, fog, win/loss', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(gameUrl, { waitUntil: 'domcontentloaded' });

    // -----------------------------------------------------------------------
    // Phase 0 — wait for in-game phase (Start_Scenario OK + frame 300)
    // -----------------------------------------------------------------------
    console.log('[audit] waiting for Start_Scenario OK…');
    await waitForOutput(page, '[RA] Select_Game: Start_Scenario OK', 240_000);
    await waitForOutput(page, '[RA] Main_Loop frame 300', 300_000);
    console.log('[audit] frame 300 reached — in-game phase confirmed');

    // Baseline screenshot
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-baseline-frame300.png'), fullPage: true });

    // Verify no crash
    let output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // -----------------------------------------------------------------------
    // Audit 1 — SIDEBAR
    // Check sidebar has non-black content (icons rendered)
    // -----------------------------------------------------------------------
    console.log('\n[audit] === SIDEBAR ===');

    // Radar area: canvas x=480..559, y=0..79
    const radarStats = await sampleCanvasRegion(page, 480, 0, 80, 80);
    console.log(`  Radar region   fill=${radarStats.fillPct}%  uniqueColors=${radarStats.uniqueColors}`);

    // Icon area: canvas x=480..639, y=130..395
    const iconStats = await sampleCanvasRegion(page, 480, 130, 160, 265);
    console.log(`  Icon area      fill=${iconStats.fillPct}%  uniqueColors=${iconStats.uniqueColors}`);

    const sidebarHasContent = iconStats.fillPct > 5;
    console.log(`  Sidebar has content: ${sidebarHasContent ? 'YES' : 'NO'}`);

    // Click on first construction icon (structure build mode, icon 1 of column 1)
    // Canvas coords: x≈495, y≈165 — should be the first structure icon
    console.log('  Clicking sidebar structure icon at canvas (495, 165)…');
    const sidebarBefore = await canvasRegionPixels(page, 480, 130, 160, 265);
    await page.click('#canvas', { position: { x: 495, y: 165 } });
    await page.waitForTimeout(500);
    await page.click('#canvas', { position: { x: 495, y: 165 } });
    await page.waitForTimeout(500);

    // Wait 2 more frames for game to process the click
    const nextFrame300 = parseInt((output.match(/Main_Loop frame (\d+)/g) || ['300']).pop()!.split(' ').pop()!) + 2;
    await page.waitForTimeout(400);
    const sidebarAfter = await canvasRegionPixels(page, 480, 130, 160, 265);
    const sidebarDiff = pixelDiff(sidebarBefore, sidebarAfter);
    console.log(`  Sidebar pixel diff after icon click: ${sidebarDiff} pixels changed`);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-sidebar-after-click.png'), fullPage: true });

    // Click the second column (often Infantry/Units tab in RA)
    console.log('  Clicking sidebar unit tab icon at canvas (560, 165)…');
    const sidebar2Before = await canvasRegionPixels(page, 480, 130, 160, 265);
    await page.click('#canvas', { position: { x: 560, y: 165 } });
    await page.waitForTimeout(600);
    const sidebar2After = await canvasRegionPixels(page, 480, 130, 160, 265);
    const sidebar2Diff = pixelDiff(sidebar2Before, sidebar2After);
    console.log(`  Sidebar pixel diff after unit tab click: ${sidebar2Diff} pixels changed`);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-sidebar-unit-tab.png'), fullPage: true });

    // -----------------------------------------------------------------------
    // Audit 2 — UNIT CONTROL
    // Left-click on a unit to select it, right-click for move order
    // -----------------------------------------------------------------------
    console.log('\n[audit] === UNIT CONTROL ===');

    // Infantry cluster visible around canvas (350, 155) in SCG01EA
    // Left-click to select
    console.log('  Left-clicking unit at canvas (350, 155)…');
    const unitRegionBefore = await canvasRegionPixels(page, 320, 130, 80, 60);
    await page.click('#canvas', { position: { x: 350, y: 155 } });
    await page.waitForTimeout(600);
    const unitRegionAfter = await canvasRegionPixels(page, 320, 130, 80, 60);
    const unitSelDiff = pixelDiff(unitRegionBefore, unitRegionAfter);
    console.log(`  Unit region pixel diff after left-click: ${unitSelDiff} pixels changed`);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-unit-selected.png'), fullPage: true });

    // Right-click to issue move order (target: open terrain ~canvas (420, 370))
    console.log('  Right-clicking move target at canvas (420, 370)…');
    await page.click('#canvas', { position: { x: 420, y: 370 }, button: 'right' });
    await page.waitForTimeout(600);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-move-order.png'), fullPage: true });

    // Try a second unit (near a vehicle at roughly canvas (340, 185))
    console.log('  Left-clicking vehicle at canvas (340, 185)…');
    await page.click('#canvas', { position: { x: 340, y: 185 } });
    await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-vehicle-selected.png'), fullPage: true });

    // -----------------------------------------------------------------------
    // Audit 3 — ENEMY AI + FOG OF WAR
    // Wait for frame 600, compare map region pixel diff to detect movement
    // -----------------------------------------------------------------------
    console.log('\n[audit] === ENEMY AI + FOG OF WAR ===');

    // Capture map at frame 300 (already done above as baseline)
    // Now record map at ~frame 400 for first snapshot
    const mapSnap1 = await canvasRegionPixels(page, 0, 0, 475, 400);
    const fogSnap1 = await sampleCanvasRegion(page, 0, 0, 475, 400);
    console.log(`  Map at frame ~300+: fill=${fogSnap1.fillPct}%  uniqueColors=${fogSnap1.uniqueColors}`);

    // Wait for frame 600
    console.log('  Waiting for frame 600…');
    await waitForOutput(page, '[RA] Main_Loop frame 600', 300_000);
    console.log('  Frame 600 reached');

    await page.waitForTimeout(300);
    const mapSnap2 = await canvasRegionPixels(page, 0, 0, 475, 400);
    const fogSnap2  = await sampleCanvasRegion(page, 0, 0, 475, 400);

    const mapDiff600 = pixelDiff(mapSnap1, mapSnap2);
    console.log(`  Map pixel diff (frame ~300 → frame 600): ${mapDiff600} pixels changed`);
    console.log(`  Map at frame 600: fill=${fogSnap2.fillPct}%  uniqueColors=${fogSnap2.uniqueColors}`);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-frame600.png'), fullPage: true });

    // Fog change: if fog is updating we expect some pixel diff in foggy areas
    const fogRegionSnap1 = await canvasRegionPixels(page, 0, 0, 200, 150); // top-left map corner (typically fogged)
    // (already captured mapSnap2 covers this implicitly — use map diff as proxy)
    const aiMovement = mapDiff600 > 500;
    console.log(`  AI/unit movement detected (>500 changed pixels): ${aiMovement ? 'YES' : 'NO'}`);

    // Wait for frame 900 to check further
    console.log('  Waiting for frame 900…');
    await waitForOutput(page, '[RA] Main_Loop frame 900', 300_000);
    await page.waitForTimeout(300);
    const mapSnap3 = await canvasRegionPixels(page, 0, 0, 475, 400);
    const mapDiff900 = pixelDiff(mapSnap2, mapSnap3);
    console.log(`  Map pixel diff (frame 600 → frame 900): ${mapDiff900} pixels changed`);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'audit-frame900.png'), fullPage: true });

    // -----------------------------------------------------------------------
    // Audit 4 — WIN/LOSS
    // Check the output for any victory/defeat strings
    // -----------------------------------------------------------------------
    console.log('\n[audit] === WIN/LOSS ===');
    output = await getOutput(page);
    const hasVictory  = /victory|mission.*complete|won/i.test(output);
    const hasDefeat   = /defeat|mission.*failed|lost/i.test(output);
    const hasEnd      = /game.*over|scenario.*end/i.test(output);
    console.log(`  Victory triggered:  ${hasVictory}`);
    console.log(`  Defeat triggered:   ${hasDefeat}`);
    console.log(`  Game over / end:    ${hasEnd}`);

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    console.log('\n[audit] ===== SUMMARY =====');
    console.log(`  1. Sidebar renders (fill>${5}%):        ${sidebarHasContent ? 'PASS' : 'FAIL'}`);
    console.log(`  1. Sidebar responds to click:           ${sidebarDiff > 0 ? 'PASS' : 'FAIL (0 diff)'}`);
    console.log(`  2. Unit region changes on click:        ${unitSelDiff > 0 ? 'PASS' : 'FAIL (0 diff)'}`);
    console.log(`  3. AI/unit movement frames 300→600:     ${aiMovement ? 'PASS' : 'FAIL'}`);
    console.log(`  3. Further movement frames 600→900:     ${mapDiff900 > 500 ? 'PASS' : 'FAIL'}`);
    console.log(`  4. No premature win/loss:               ${!hasVictory && !hasDefeat && !hasEnd ? 'PASS' : 'WARN'}`);
    console.log(`  5. No crash by frame 900:               PASS (if we reached here)`);

    // Hard assertions
    expect(sidebarHasContent).toBe(true);
    output = await getOutput(page);
    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');
  });
});
