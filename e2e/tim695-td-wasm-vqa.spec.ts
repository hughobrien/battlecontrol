/**
 * TIM-695 — Verify TD WASM intro VQA (LOGO.VQA) plays in the browser.
 *
 * Companion to TIM-600 (RA ENGLISH.VQA): asserts the TD build of vqa_player.cpp
 * + the WebAudio bypass (TIM-604 pattern) decode frames, push audio through the
 * AudioContext, and complete without a null-function trap.
 *
 * Trigger: TIBERIANDAWN/INIT.CPP::Play_Intro is now live on non-MSVC builds
 * (TIM-695 patch), so booting td.html without ?autostart=1 fires
 * Play_Movie("LOGO", THEME_NONE, false) during Init_Game.  LOGO.VQA is not
 * bundled in any of the eight TD MIX files we preload, so the preloader's
 * new ?vqa=LOGO param drops a standalone copy into MEMFS.
 *
 * Servers required:
 *   - serve-coop.py on :8082   (build-wasm/, COOP+COEP for SharedArrayBuffer)
 *   - serve-assets.py on :9091 (TD CD1 with LOGO.VQA standalone alongside MIX)
 *
 * Acceptance (mirrors TIM-600 / TIM-602 / TIM-604):
 *   1. No pageerror, no null-function trap (5/5 cold-cache, see TIM-600 note)
 *   2. WebAudio open log emitted: "[VQA] WebAudio: source=N Hz device=M Hz channels=K"
 *   3. Canvas fill > 0 during VQA playback (active frame, not just the title card)
 *   4. Playback completes: "[VQA] 'LOGO.VQA' done (N/M frames)"
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = process.env.TIM695_WASM_URL  || 'http://localhost:8082/td.html';
const ASSET_URL       = process.env.TIM695_ASSET_URL || 'http://localhost:9091/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

// Detect whether TD assets are reachable.  CI runs without copyrighted MIX
// files (TD MOVIES.MIX is ~425MB and cannot live in the repo), so the spec
// auto-skips when the asset server returns 404 for LOGO.VQA.  Set
// TIM695_REQUIRE_ASSETS=1 to fail instead of skipping (used by local audits).
async function assetsReachable(): Promise<boolean> {
  try {
    const res = await fetch(`${ASSET_URL}LOGO.VQA`, { method: 'HEAD' });
    return res.ok;
  } catch {
    return false;
  }
}

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

async function getOutput(page: any): Promise<string> {
  return page.evaluate(() => {
    const el = document.getElementById('output');
    return el ? (el.textContent || '') : '';
  });
}

async function canvasFillPct(page: any): Promise<number> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return 0;
    const ctx = canvas.getContext('2d');
    if (!ctx) return 0;
    const w = canvas.width, h = canvas.height;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
    }
    return Math.round(nonBlack / total * 100);
  });
}

test('TIM-695 TD WASM intro VQA — LOGO.VQA decodes + audio + completes', async ({ page }) => {
  test.setTimeout(360_000);

  if (!(await assetsReachable())) {
    const requireAssets = process.env.TIM695_REQUIRE_ASSETS === '1';
    const msg = `LOGO.VQA not reachable at ${ASSET_URL} — set TIM695_ASSET_URL to a directory containing TD MIX files + standalone LOGO.VQA, or pass TIM695_REQUIRE_ASSETS=1 to fail instead of skip.`;
    if (requireAssets) throw new Error(msg);
    test.skip(true, msg);
    return;
  }

  const consoleLogs: string[] = [];
  const pageErrors: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // ?vqa=LOGO tells preloader.js to also fetch LOGO.VQA standalone from ?src=.
  // No ?autostart=1 → Play_Intro runs → Play_Movie("LOGO", ...).
  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&vqa=LOGO&debug=1`;
  console.log(`[TIM-695] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ──────────────────────────────────────────────────
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('  preloader hidden ✓');

  // ── Phase 2: LOGO.VQA start ──────────────────────────────────────────────
  // Init_Game in TD takes longer than RA — give it generous headroom.
  await waitForOutput(page, "[VQA] Playing 'LOGO.VQA'", 180_000);
  console.log('  LOGO.VQA opened ✓');

  // ── Phase 3: Confirm WebAudio open ──────────────────────────────────────
  // [VQA] WebAudio: source=N Hz device=M Hz channels=K — proves
  // AudioContext.sampleRate query succeeded under PROXY_TO_PTHREAD.
  await waitForOutput(page, '[VQA] WebAudio:', 30_000);
  console.log('  WebAudio audio context opened ✓');

  // ── Phase 4: Sample canvas during playback ──────────────────────────────
  // LOGO.VQA = 320x200, blockH=2, 15 fps, 418 frames (~27 s).  Sample at
  // 2 s and 5 s into playback to catch the Westwood logo card (bright).
  const samples: { label: string; fillPct: number }[] = [];
  for (const [label, delayMs] of [['t2s', 2000], ['t5s', 3000]] as const) {
    await page.waitForTimeout(delayMs);
    const fillPct = await canvasFillPct(page);
    samples.push({ label, fillPct });
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `tim695-td-logo-${label}.png`) });
    console.log(`  [${label}] canvas fill = ${fillPct}%`);
  }

  // ── Phase 5: Wait for completion ────────────────────────────────────────
  await waitForOutput(page, "[VQA] 'LOGO.VQA' done", 60_000);
  const output = await getOutput(page);
  const doneMatch = output.match(/\[VQA\] 'LOGO\.VQA' done \((\d+)\/(\d+) frames\)/);
  const playedFrames = doneMatch ? parseInt(doneMatch[1], 10) : 0;
  const totalFrames  = doneMatch ? parseInt(doneMatch[2], 10) : 0;
  console.log(`  LOGO.VQA done: ${playedFrames}/${totalFrames} frames`);

  // ── Phase 6: Log analysis ───────────────────────────────────────────────
  let audioDevRate = 0;
  const webAudioMatch = output.match(/\[VQA\] WebAudio: source=(\d+) Hz device=(\d+) Hz/);
  let audioSrcRate = 0;
  if (webAudioMatch) {
    audioSrcRate = parseInt(webAudioMatch[1], 10);
    audioDevRate = parseInt(webAudioMatch[2], 10);
  }
  const hasNullFunc =
    pageErrors.some(e => /null function|table index|invalid function/i.test(e)) ||
    consoleLogs.some(l => /null function|table index|invalid function/i.test(l)) ||
    output.includes('Aborted(') || output.includes('SIGSEGV') || output.includes('null function');

  const maxFill = Math.max(...samples.map(s => s.fillPct));

  console.log('\n[TIM-695] ===== TD WASM VQA AUDIT SUMMARY =====');
  console.log(`  Played frames:        ${playedFrames}/${totalFrames}`);
  console.log(`  WebAudio source rate: ${audioSrcRate} Hz`);
  console.log(`  WebAudio device rate: ${audioDevRate} Hz`);
  console.log(`  Max canvas fill:      ${maxFill}%`);
  console.log(`  Page errors:          ${pageErrors.length}`);
  console.log(`  Null-function trap:   ${hasNullFunc ? 'YES (FAIL)' : 'no'}`);

  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim695-td-logo-vqa-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${output}\n`
  );

  // ── Assertions ──────────────────────────────────────────────────────────
  expect(pageErrors, `no pageerror — got: ${pageErrors.slice(0, 3).join('; ')}`).toHaveLength(0);
  expect(hasNullFunc, 'no null-function trap during VQA').toBe(false);

  expect(audioDevRate, 'WebAudio device rate (browser native, ≥22050)').toBeGreaterThanOrEqual(22050);
  expect(audioSrcRate, 'WebAudio source rate (VQA encoded rate)').toBeGreaterThan(0);

  expect(maxFill, 'canvas fill > 0 during VQA playback').toBeGreaterThan(0);

  expect(playedFrames, 'VQA frames played').toBeGreaterThan(0);
  expect(playedFrames, 'all declared frames decoded').toBe(totalFrames);
});
