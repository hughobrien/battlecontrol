/**
 * TIM-657 — WASM UI chrome: controls-hint text and mouse-button forwarding.
 *
 * Two parts:
 *
 * Part A — Controls-hint text (static shell chrome):
 *   Verifies that both shells (RA: ra.html, TD: td.html) present a visible
 *   #controls-hint element containing explicit LMB / RMB action labels.
 *   Acceptance criteria: "LMB = select/move, RMB = attack/cancel"
 *
 * Part B — Mouse-button forwarding mechanism:
 *   Verifies the two browser-level wiring points that allow LMB / RMB events
 *   to reach the Emscripten/SDL2 layer:
 *     1. Canvas gains focus on mousedown (required for SDL keyboard routing).
 *     2. Right-click on canvas does NOT trigger the browser context menu
 *        (oncontextmenu="event.preventDefault()" must fire before the event
 *        propagates to the Emscripten event bridge).
 *
 * Full SDL_BUTTON_LEFT / SDL_BUTTON_RIGHT round-trip with in-game unit-count
 * verification is covered by the existing TIM-537 test (tim537-click.spec.ts).
 *
 * Requires: serve-coop.py on :8080 serving the built WASM bundle (ra.html
 * and td.html). No game assets or game-loop execution needed.
 */

import { test, expect } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

const RA_URL          = 'http://localhost:8080/ra.html';
const TD_URL          = 'http://localhost:8080/td.html';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Part A — Controls-hint presence and content
// ---------------------------------------------------------------------------

test.describe('TIM-657 Part A — controls-hint text', () => {
  test.setTimeout(15_000);

  test('RA shell: #controls-hint visible with LMB and RMB labels', async ({ page }) => {
    await page.goto(RA_URL, { waitUntil: 'domcontentloaded' });

    const hint = page.locator('#controls-hint');
    await expect(hint).toBeVisible({ timeout: 5_000 });

    const hintText = (await hint.textContent()) ?? '';
    console.log(`[TIM-657] RA controls-hint: "${hintText.trim()}"`);

    // Must contain "LMB" and "RMB" (case-insensitive for robustness)
    expect(hintText, 'controls-hint must mention LMB').toMatch(/lmb/i);
    expect(hintText, 'controls-hint must mention RMB').toMatch(/rmb/i);

    // LMB side must explain select or move action
    expect(hintText, 'controls-hint must explain select or move').toMatch(/select|move/i);

    // RMB side must explain attack or cancel action
    expect(hintText, 'controls-hint must explain attack or cancel').toMatch(/attack|cancel/i);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim657-ra-controls-hint.png') });
    console.log(`[TIM-657] RA Part A: PASS`);
  });

  test('TD shell: #controls-hint visible with LMB and RMB labels', async ({ page }) => {
    await page.goto(TD_URL, { waitUntil: 'domcontentloaded' });

    const hint = page.locator('#controls-hint');
    await expect(hint).toBeVisible({ timeout: 5_000 });

    const hintText = (await hint.textContent()) ?? '';
    console.log(`[TIM-657] TD controls-hint: "${hintText.trim()}"`);

    expect(hintText, 'controls-hint must mention LMB').toMatch(/lmb/i);
    expect(hintText, 'controls-hint must mention RMB').toMatch(/rmb/i);
    expect(hintText, 'controls-hint must explain select or move').toMatch(/select|move/i);
    expect(hintText, 'controls-hint must explain attack or cancel').toMatch(/attack|cancel/i);

    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim657-td-controls-hint.png') });
    console.log(`[TIM-657] TD Part A: PASS`);
  });
});

// ---------------------------------------------------------------------------
// Part B — Canvas mouse-button forwarding wiring
// ---------------------------------------------------------------------------

test.describe('TIM-657 Part B — canvas mouse-button forwarding wiring', () => {
  test.setTimeout(15_000);

  // LMB — canvas gets keyboard focus on mousedown so SDL key events follow
  test('RA canvas: LMB click gives the canvas browser focus', async ({ page }) => {
    await page.goto(RA_URL, { waitUntil: 'domcontentloaded' });

    const canvas = page.locator('#canvas');
    await expect(canvas).toBeVisible({ timeout: 5_000 });

    // Left-click triggers the 'mousedown' → canvas.focus() listener in shell.html
    await canvas.click({ position: { x: 10, y: 10 } });

    const hasFocus = await page.evaluate(() => {
      return document.activeElement === document.getElementById('canvas');
    });
    console.log(`[TIM-657] RA canvas hasFocus after LMB: ${hasFocus}`);
    expect(hasFocus, 'canvas must have focus after LMB so SDL keyboard events fire').toBe(true);
  });

  // RMB — context menu must be suppressed so the right-click reaches the SDL layer
  test('RA canvas: RMB does not open browser context menu (defaultPrevented)', async ({ page }) => {
    await page.goto(RA_URL, { waitUntil: 'domcontentloaded' });

    // Register a capture-phase listener so we can read defaultPrevented *after*
    // the inline oncontextmenu="event.preventDefault()" has already run.
    await page.evaluate(() => {
      const canvas = document.getElementById('canvas');
      if (canvas) {
        canvas.addEventListener('contextmenu', (e) => {
          (window as any).__ctxDefaultPrevented = e.defaultPrevented;
        });
      }
    });

    const canvas = page.locator('#canvas');
    await canvas.click({ button: 'right', position: { x: 320, y: 240 } });

    const prevented = await page.evaluate(() => (window as any).__ctxDefaultPrevented);
    console.log(`[TIM-657] RA canvas contextmenu defaultPrevented: ${prevented}`);
    expect(prevented, 'RMB context menu must be prevented so right-click reaches SDL').toBe(true);
  });

  // Same focus check for TD
  test('TD canvas: LMB click gives the canvas browser focus', async ({ page }) => {
    await page.goto(TD_URL, { waitUntil: 'domcontentloaded' });

    const canvas = page.locator('#canvas');
    await expect(canvas).toBeVisible({ timeout: 5_000 });

    await canvas.click({ position: { x: 10, y: 10 } });

    const hasFocus = await page.evaluate(() => {
      return document.activeElement === document.getElementById('canvas');
    });
    console.log(`[TIM-657] TD canvas hasFocus after LMB: ${hasFocus}`);
    expect(hasFocus, 'canvas must have focus after LMB so SDL keyboard events fire').toBe(true);
  });

  // Same context-menu suppression check for TD
  test('TD canvas: RMB does not open browser context menu (defaultPrevented)', async ({ page }) => {
    await page.goto(TD_URL, { waitUntil: 'domcontentloaded' });

    await page.evaluate(() => {
      const canvas = document.getElementById('canvas');
      if (canvas) {
        canvas.addEventListener('contextmenu', (e) => {
          (window as any).__ctxDefaultPrevented = e.defaultPrevented;
        });
      }
    });

    const canvas = page.locator('#canvas');
    await canvas.click({ button: 'right', position: { x: 320, y: 240 } });

    const prevented = await page.evaluate(() => (window as any).__ctxDefaultPrevented);
    console.log(`[TIM-657] TD canvas contextmenu defaultPrevented: ${prevented}`);
    expect(prevented, 'RMB context menu must be prevented so right-click reaches SDL').toBe(true);
  });
});
