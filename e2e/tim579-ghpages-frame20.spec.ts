/**
 * TIM-579 — Live check of the deployed WASM build at
 * https://hughobrien.github.io/battlecontrol/ — capture frame 20 of the
 * Red Alert intro VQA (ENGLISH.VQA) and report on palette quality.
 *
 * Strategy: load the live ra.html, intercept asset fetches and serve local
 * MIX files via Playwright's context.route(). COOP/COEP headers are added to
 * the top-level navigation response so SharedArrayBuffer works on first load
 * (bypasses the COI service-worker double-reload).
 *
 * ENGLISH.VQA is 15 fps → frame 20 = ~1.333s after Play_Intro fires.
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const ASSET_DIR = '/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1';
// Fake asset base — every request matching the prefix is fulfilled from local disk.
const FAKE_ASSET_BASE = 'https://hughobrien.github.io/battlecontrol/__assets__/';

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

async function canvasStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fill: 0, colors: 0, w: 0, h: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, colors: 0, w: canvas.width, h: canvas.height };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h };
  });
}

test('TIM-579 — live gh-pages WASM: capture frame 20 of ENGLISH.VQA', async ({ page, context }) => {
  test.setTimeout(420_000);

  // ── Intercept asset fetches from the fake base URL ────────────────────────
  await context.route(`${FAKE_ASSET_BASE}*`, async (route) => {
    const url = new URL(route.request().url());
    const filename = path.basename(url.pathname);
    const filepath = path.join(ASSET_DIR, filename);
    try {
      const buf = fs.readFileSync(filepath);
      await route.fulfill({
        status: 200,
        contentType: 'application/octet-stream',
        body: buf,
        headers: {
          'access-control-allow-origin': '*',
          'cross-origin-resource-policy': 'cross-origin',
          'cache-control': 'no-cache',
        },
      });
    } catch (e: any) {
      await route.fulfill({ status: 404, body: 'not found: ' + filename });
    }
  });

  // ── Inject COOP/COEP headers on the top-level navigation ──────────────────
  // The live gh-pages site relies on coi-serviceworker for SharedArrayBuffer.
  // To avoid the SW double-reload dance in a fresh Playwright context, we
  // splice COOP/COEP onto the ra.html response directly. The WASM bytes
  // themselves remain unmodified — we're only changing headers.
  await context.route('https://hughobrien.github.io/battlecontrol/ra.html*', async (route) => {
    const response = await route.fetch();
    const headers = { ...response.headers() };
    headers['cross-origin-opener-policy'] = 'same-origin';
    headers['cross-origin-embedder-policy'] = 'require-corp';
    await route.fulfill({
      response,
      headers,
    });
  });
  // Same for the JS/wasm/preloader so COEP doesn't reject them.
  await context.route(/^https:\/\/hughobrien\.github\.io\/battlecontrol\/.*\.(js|wasm)$/, async (route) => {
    const response = await route.fetch();
    const headers = { ...response.headers() };
    headers['cross-origin-resource-policy'] = 'cross-origin';
    await route.fulfill({ response, headers });
  });

  // Console + output capture for forensics.
  const consoleLines: string[] = [];
  page.on('console', (msg: any) => consoleLines.push(`[console:${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => consoleLines.push(`[pageerror] ${err.message}`));

  const url = `https://hughobrien.github.io/battlecontrol/ra.html?src=${encodeURIComponent(FAKE_ASSET_BASE)}&debug=1`;
  console.log(`[TIM-579] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // Wait for the preloader to hide (i.e. MIX files fetched and mounted).
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('[TIM-579] preloader hidden — assets mounted');

  // Wait for Play_Intro (which starts ENGLISH.VQA).
  await waitForOutput(page, '[RA] Init_Game: calling Play_Intro', 180_000);
  const playIntroAtMs = Date.now();
  console.log(`[TIM-579] Play_Intro fired at t=${playIntroAtMs}`);

  // ── Frame 20 timing ───────────────────────────────────────────────────────
  // ENGLISH.VQA is 15 fps. Frame 20 lands at 20/15 = 1.333s after VQA start.
  // Add a small cushion for the VQA player to actually start emitting frames
  // (chunk parsing, codebook init, first paint).
  await page.waitForTimeout(1333);

  const sFrame20 = await canvasStats(page);
  const frame20Path = path.join(SCREENSHOTS_DIR, 'tim579-ghpages-vqa-frame20.png');
  await page.screenshot({ path: frame20Path });
  console.log(`[TIM-579] frame 20 (~t=1.333s): fill=${sFrame20.fill}% colors=${sFrame20.colors} (${sFrame20.w}x${sFrame20.h})`);

  // Capture a couple of reference frames for context.
  await page.waitForTimeout(666); // → t=2s
  const sT2 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim579-ghpages-vqa-t2s.png') });
  console.log(`[TIM-579] t2s: fill=${sT2.fill}% colors=${sT2.colors}`);

  await page.waitForTimeout(3000); // → t=5s
  const sT5 = await canvasStats(page);
  await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim579-ghpages-vqa-t5s.png') });
  console.log(`[TIM-579] t5s: fill=${sT5.fill}% colors=${sT5.colors}`);

  // Dump the stderr output (visible in #output because debug=1) to a log for
  // forensic comparison if anything looks off.
  const outputText = await page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? el.textContent : '';
  });
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim579-ghpages-output.log'),
    `=== console ===\n${consoleLines.join('\n')}\n\n=== #output ===\n${outputText}\n`,
  );

  // Basic liveness — frame 20 should not be all-black if VQA is decoding.
  expect(sFrame20.colors).toBeGreaterThan(2); // any palette = >1 color
  console.log('[TIM-579] frame 20 captured — see screenshots for visual quality verdict');
});
