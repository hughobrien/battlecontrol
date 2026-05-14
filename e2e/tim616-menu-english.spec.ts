/**
 * TIM-616 — RA main menu English language verification.
 *
 * Before this fix, WOLSTRNG.CPP compiled the French language block because
 * ENGLISH was not defined globally — only in a few per-TU pins. The two
 * expansion mission buttons showed French text:
 *   "MISSIONS EXTRAITES DE MISSIONS TAIGA"    (should be "Counterstrike Missions")
 *   "MISSIONS EXTRAITES DE MISSIONS M.A.D."   (should be "Aftermath Missions")
 *
 * Fix: DEFINES.H now enables #define ENGLISH 1 for all TUs.
 *
 * Verification: a runtime log line printed by MENUS.CPP Main_Menu() confirms
 * the English strings are compiled in.
 *
 * Servers required (started externally before this spec):
 *   - serve-coop.py on port 8080 (WASM bundle from build-wasm/)
 *   - serve-assets.py on port 9090 (RA MIX files)
 *
 * URL: http://localhost:8080/ra.html?src=http://localhost:9090/&debug=1
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

async function waitForOutput(page: any, substring: string, timeoutMs = 240_000) {
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

test.describe('TIM-616 — RA main menu English text', () => {
  test.setTimeout(420_000);

  const menuUrl = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;

  test('expansion buttons show English text (not French)', async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on('console', msg => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', err => consoleLogs.push(`[pageerror] ${err.message}`));

    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    // Wait for full game init before menu renders.
    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);

    // MENUS.CPP Main_Menu() logs the expansion button text when the menu opens.
    await waitForOutput(page, '[TIM-616] menu_cs=', 30_000);

    const output = await getOutput(page);
    const menuLine = output.split('\n').find(l => l.includes('[TIM-616] menu_cs='));

    console.log('=== TIM-616 menu text probe ===');
    console.log('  Log line:', menuLine);

    // Capture screenshot for visual verification.
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim616-menu-english.png'), fullPage: true });
    console.log('  Screenshot: tim616-menu-english.png');

    expect(output).not.toContain('SIGSEGV');
    expect(output).not.toContain('Aborted(');

    // English strings expected.
    expect(menuLine).toContain("menu_cs='Counterstrike Missions'");
    expect(menuLine).toContain("menu_am='Aftermath Missions'");

    // French strings must NOT appear.
    expect(menuLine).not.toContain('EXTRAITES');
    expect(menuLine).not.toContain('TAIGA');
    expect(menuLine).not.toContain('M.A.D');
  });

  test('no debug/editor UI in main menu', async ({ page }) => {
    await page.goto(menuUrl, { waitUntil: 'domcontentloaded' });

    await waitForOutput(page, '[RA] Init_Game: Init_Bulk_Data done', 240_000);
    await waitForOutput(page, '[TIM-616] menu_cs=', 30_000);

    const output = await getOutput(page);

    // SCENARIO_EDITOR requires INTERNAL_VERSION which is commented out.
    // Debug_Map and CHEAT_KEYS are also inactive in release builds.
    // The menu log line must not contain any editor/debug button text.
    expect(output).not.toContain('Scenario Editor');
    expect(output).not.toContain('Map Editor');
    expect(output).not.toContain('[TIM-616] DEBUG');

    console.log('No debug/editor UI confirmed (SCENARIO_EDITOR inactive).');
  });
});
