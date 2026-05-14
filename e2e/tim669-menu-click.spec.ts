/**
 * TIM-669 — RA WASM menu-click regression spec (TIM-664 KEY.CPP fix).
 *
 * Regression gate for TIM-664: verifies that real SDL mouse events correctly
 * route through the event pipeline and trigger menu button actions in WASM.
 *
 * Root cause of TIM-664: SDL_Process_Input_Events added WWKEY_VK_BIT (0x1000)
 * to mouse button codes, storing 0x1001 instead of VK_LBUTTON (0x01).
 * GadgetClass::Input() compares key==KN_LMOUSE where KN_LMOUSE==0x01, so
 * 0x1001==0x01 always failed — no menu button was ever activated by clicks.
 * Fix: remove `vk |= WWKEY_VK_BIT` from the mouse branch in KEY.CPP.
 *
 * This spec confirms the fix applies in the WASM build:
 *   1. Load ra.html without ?autostart=1 (no synthetic injection).
 *   2. Wait for Init_Bulk_Data done + [TIM-616] menu_cs= (menu rendered).
 *   3. Sample canvas pixels before the click.
 *   4. page.click('#canvas', {position:{x:322,y:183}}) — "New Campaign".
 *   5. Assert canvas changes (pixelDiff > 0).
 *
 * VQA intro: if ENGLISH.VQA is present the intro plays first.  The
 * vqa_install_abort_listeners() hook (mousedown on canvas) handles any early
 * click; we simply wait for [TIM-616] menu_cs= which only fires once the menu
 * gadgets are on screen.
 *
 * Button positions (640×480, ENGLISH build, no expansion packs):
 *   starty=174, ystep=28, center_offset=9
 *   New Campaign  → (322, 183)
 *   Load Game     → (322, 211)
 *   Multiplayer   → (322, 239)
 *   Introduction  → (322, 267)
 *   Exit          → (322, 295)
 *
 * Servers required (started externally):
 *   serve-coop.py  on :8080  — WASM bundle from build-wasm/
 *   serve-assets.py on :9090  — RA MIX files from CD1/
 *
 * URL: http://localhost:8080/ra.html?src=http://localhost:9090/&debug=1
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

/** Sample RGB pixels from the full 640×480 canvas; returns a flat number[]. */
async function sampleCanvas(page: any): Promise<number[]> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return [];
    const ctx = canvas.getContext('2d');
    if (!ctx) return [];
    const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const out: number[] = [];
    // Sample every 4th pixel for speed (stride 16 bytes = every 4 RGBA pixels).
    for (let i = 0; i < d.length; i += 16) {
      out.push(d[i], d[i + 1], d[i + 2]);
    }
    return out;
  });
}

/** Count pixels where any channel differs by more than a small threshold. */
function pixelDiff(a: number[], b: number[]): number {
  let diff = 0;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i += 3) {
    if (Math.abs(a[i] - b[i]) > 8 ||
        Math.abs(a[i+1] - b[i+1]) > 8 ||
        Math.abs(a[i+2] - b[i+2]) > 8) {
      diff++;
    }
  }
  return diff;
}

test.describe('TIM-669 — RA WASM menu-click regression (TIM-664 KEY.CPP fix)', () => {
  test.setTimeout(420_000);

  const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

  test('New Campaign click causes canvas change — no synthetic injection', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // ── 1. WASM boot ──────────────────────────────────────────────────────────
    console.log('[tim669] waiting for Init_Bulk_Data…');
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 300_000);
    console.log('[tim669] Init_Bulk_Data done');

    // ── 2. Menu up ────────────────────────────────────────────────────────────
    // [TIM-616] menu_cs= fires from MENUS.CPP once the button gadgets are live.
    // This is the earliest safe point for real mouse clicks on the menu.
    await waitForOutput(page, '[TIM-616] menu_cs=', 30_000);
    console.log('[tim669] main menu confirmed up');

    // Short settle: let the game render at least one menu frame.
    await page.waitForTimeout(1_000);

    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'tim669-before-click.png'),
      fullPage: true,
    });

    // ── 3. Pre-click pixel sample ─────────────────────────────────────────────
    const before = await sampleCanvas(page);
    console.log(`[tim669] pre-click pixels sampled: ${before.length / 3}`);

    // ── 4. Real mouse click ───────────────────────────────────────────────────
    // (322, 183) is the centre of the "New Campaign" button.
    // No RA_AUTOSTART flag, no synthetic LCLICK injection — pure Playwright click.
    // This exercises the TIM-664 KEY.CPP fix: VK_LBUTTON (0x01) stored in the
    // keyboard buffer so GadgetClass::Input() matches KN_LMOUSE correctly.
    await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
    console.log('[tim669] clicked New Campaign at (322, 183)');

    // ── 5. Wait for response ──────────────────────────────────────────────────
    // The click should open the mission/difficulty selection screen.
    // Give the game up to 8s to render the new state.
    await page.waitForTimeout(5_000);

    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'tim669-after-click.png'),
      fullPage: true,
    });

    // ── 6. Post-click pixel sample and diff ───────────────────────────────────
    const after  = await sampleCanvas(page);
    const diff   = pixelDiff(before, after);
    const output = await getOutput(page);
    const noPageError = !consoleLogs.some(l => l.startsWith('[pageerror]'));

    console.log(`[tim669] pixel diff: ${diff} pixels changed`);

    console.log('\n[tim669] ===== SUMMARY =====');
    console.log(`  Init_Bulk_Data:     PASS`);
    console.log(`  Main menu up:       PASS`);
    console.log(`  Click method:       real Playwright click (no synthetic injection)`);
    console.log(`  Pixel diff:         ${diff} (must be > 0)`);
    console.log(`  No crash:           ${!output.includes('SIGSEGV') && !output.includes('Aborted(') ? 'PASS' : 'FAIL'}`);
    console.log(`  No page error:      ${noPageError ? 'PASS' : 'FAIL'}`);
    console.log('  Screenshots:        tim669-before-click.png, tim669-after-click.png');

    expect(output, 'no SIGSEGV').not.toContain('SIGSEGV');
    expect(output, 'no Aborted').not.toContain('Aborted(');
    expect(noPageError, 'no page error').toBe(true);
    // Primary regression gate: canvas must change after a real mouse click.
    // Pre-TIM-664 this always failed (diff == 0) because WWKEY_VK_BIT prevented
    // GadgetClass::Input() from matching KN_LMOUSE.
    expect(diff, 'canvas must change after New Campaign click (TIM-664 regression gate)').toBeGreaterThan(0);
  });
});
