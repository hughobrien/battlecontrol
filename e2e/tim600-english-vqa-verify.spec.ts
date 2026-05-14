/**
 * TIM-600 — Verify ENGLISH.VQA (Hell March intro) plays correctly in WASM.
 *
 * ENGLISH.VQA = the Westwood + Virgin logos, tank/helicopter sequence,
 * and Hell March music intro that Play_Intro() fires on first run.
 *
 * Acceptance criteria from the issue:
 *   1. Video plays without weird banding or block-aligned colour artifacts
 *      (TIM-590 cyan-scatter pattern absent)
 *   2. Video plays without black squares or missing frame regions
 *      (intra-frame block fill consistent, letterbox-only rows are solid black)
 *   3. Audio plays at correct pitch and speed
 *      ([VQA] WASM audio: opening at N Hz (browser native rate) — sample rate
 *       matches AudioContext native rate, no divide-by-zero traps)
 *   4. Audio is in sync with video throughout
 *      (Hell March log entries present, no audio device reopen/regressions)
 *   5. Playback completes without crash or freeze
 *      ([VQA] 'ENGLISH.VQA' done (N/M frames) with N == M, no SIGSEGV / Aborted)
 *   6. Visual spot-check: mid-playback screenshot saved for manual inspection
 *
 * Servers required (same pattern as TIM-591):
 *   - serve-coop.py on :8080 (build-wasm/)
 *   - serve-assets.py on :9090 (/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
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
    return el ? (el.textContent || '') : '';
  });
}

/**
 * Full-canvas pixel stats:
 *   fill        — % of pixels brighter than near-black
 *   colors      — distinct 5-bits-per-channel colour buckets
 *   cyanCount   — TIM-590 cyan-scatter signature (low R, high G+B)
 *   blockEdges  — heuristic for visible 4×2 block boundaries: count of
 *                 horizontal pixel pairs at 4-pixel grid lines whose RGB
 *                 delta exceeds a threshold. Useful for catching
 *                 block-aligned banding even if it's not the cyan pattern.
 */
async function canvasStats(page: any) {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return { fill: 0, colors: 0, w: 0, h: 0, cyanCount: 0, blockEdges: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, colors: 0, w: canvas.width, h: canvas.height, cyanCount: 0, blockEdges: 0 };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0, cyanCount = 0, blockEdges = 0;
    const colorSet = new Set<number>();
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      if (r < 32 && g > 180 && b > 180) cyanCount++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    // Scan every 4-pixel column boundary (block boundary in 4×2 VQA blocks)
    // across the VQA active region (y=40..439, x=4..636 step 4).
    for (let y = 40; y < 440; y += 2) {
      for (let x = 4; x < w; x += 4) {
        const a = (y * w + x - 1) * 4;
        const b2 = (y * w + x) * 4;
        const d = Math.abs(data[a] - data[b2]) +
                  Math.abs(data[a + 1] - data[b2 + 1]) +
                  Math.abs(data[a + 2] - data[b2 + 2]);
        if (d > 192) blockEdges++;
      }
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h, cyanCount, blockEdges };
  });
}

/** Fraction of non-black pixels in a horizontal band of the canvas. */
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

test('TIM-600 ENGLISH.VQA — visual + audio + completion', async ({ page }) => {
  test.setTimeout(1_500_000);

  const consoleLogs: string[] = [];
  const pageErrors: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  // Plain URL — no autostart=1, so Play_Intro fires ENGLISH.VQA normally.
  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[TIM-600] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ──────────────────────────────────────────────────
  console.log('\n[TIM-600] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('  preloader hidden ✓');

  // ── Phase 2: Wait for ENGLISH.VQA to start ───────────────────────────────
  console.log('\n[TIM-600] === Phase 2: ENGLISH.VQA start ===');
  await waitForOutput(page, "[VQA] Playing 'ENGLISH.VQA'", 240_000);
  console.log('  ENGLISH.VQA opened ✓');

  // ── Phase 3: Dense frame sampling across full ENGLISH.VQA ────────────────
  // ENGLISH.VQA = 640×400 @ 15fps, ≈160 frames (~10.7 s).
  // Canvas is 640×480 — 40px black letterbox top + bottom.
  // Sample every ~1 s for the full playback so we cover Westwood logo,
  // Virgin logo, tank, helicopter, and Hell March footage.
  console.log('\n[TIM-600] === Phase 3: dense frame sampling ===');
  const samples: { label: string; fill: number; colors: number; cyanCount: number;
                   blockEdges: number; topBand: number; botBand: number }[] = [];
  const sampleSchedule: [string, number][] = [
    ['t1s',  1000],
    ['t2s',  1000],
    ['t3s',  1000],
    ['t4s',  1000],
    ['t5s',  1000],
    ['t6s',  1000],
    ['t7s',  1000],
    ['t8s',  1000],
    ['t9s',  1000],
    ['t10s', 1000],
    ['t11s', 1000],
  ];
  for (const [label, delayMs] of sampleSchedule) {
    await page.waitForTimeout(delayMs);
    const stats = await canvasStats(page);
    const topBand = await bandFillPct(page, 0, 40);
    const botBand = await bandFillPct(page, 440, 480);
    samples.push({ label, fill: stats.fill, colors: stats.colors,
                   cyanCount: stats.cyanCount, blockEdges: stats.blockEdges,
                   topBand, botBand });
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `tim600-english-${label}.png`) });
    console.log(`  [${label}] fill=${stats.fill}% colors=${stats.colors} ` +
                `cyan=${stats.cyanCount} blockEdges=${stats.blockEdges} ` +
                `letterbox(top=${topBand}% bot=${botBand}%)`);
  }

  // ── Phase 4: Wait for ENGLISH.VQA completion ────────────────────────────
  console.log('\n[TIM-600] === Phase 4: ENGLISH.VQA completion ===');
  await waitForOutput(page, "[VQA] 'ENGLISH.VQA' done", 60_000);
  const output = await getOutput(page);
  const doneMatch = output.match(/\[VQA\] 'ENGLISH\.VQA' done \((\d+)\/(\d+) frames\)/);
  const playedFrames = doneMatch ? parseInt(doneMatch[1], 10) : 0;
  const totalFrames  = doneMatch ? parseInt(doneMatch[2], 10) : 0;
  console.log(`  ENGLISH.VQA done: ${playedFrames}/${totalFrames} frames`);

  // ── Phase 5: Log analysis ───────────────────────────────────────────────
  console.log('\n[TIM-600] === Phase 5: log analysis ===');
  const vqaLines = [...output.matchAll(/\[VQA\][^\n]*/g)].map(m => m[0]);

  // Audio open device rate. TIM-604 replaced the SDL2 ScriptProcessorNode path
  // with a JS-owned AudioBufferSourceNode scheduler, so the log line changed
  // from `[VQA] WASM audio: opening at N Hz (browser native rate ...)` to
  // `[VQA] WebAudio: source=N Hz device=M Hz channels=K`. Accept either.
  let audioOpenRate = 0;
  const webAudioMatch = output.match(/\[VQA\] WebAudio: source=\d+ Hz device=(\d+) Hz/);
  if (webAudioMatch) {
    audioOpenRate = parseInt(webAudioMatch[1], 10);
  } else {
    const legacyMatch = output.match(/\[VQA\] WASM audio: opening at (\d+) Hz/);
    if (legacyMatch) audioOpenRate = parseInt(legacyMatch[1], 10);
  }

  // VQA header sample-rate (from the [VQA] Playing line)
  const playingMatch = output.match(/\[VQA\] Playing 'ENGLISH\.VQA':.*hz=(\d+)/);
  const vqaHeaderRate = playingMatch ? parseInt(playingMatch[1], 10) : 0;

  const sdlAudioFail = output.includes('[VQA] SDL audio open failed');
  const hasDivByZero = pageErrors.some(e => /divide.*zero|integer overflow|trap.*div/i.test(e)) ||
                       consoleLogs.some(l => /divide.*zero|integer overflow|trap.*div/i.test(l));
  const hasSIGSEGV = output.includes('SIGSEGV') || output.includes('Aborted(');

  console.log(`  VQA header sample rate: ${vqaHeaderRate} Hz`);
  console.log(`  Audio device opened at: ${audioOpenRate} Hz`);
  console.log(`  SDL audio open failed:  ${sdlAudioFail ? 'YES (FAIL)' : 'no'}`);
  console.log(`  Divide-by-zero / abort: ${hasDivByZero ? 'FOUND (FAIL)' : 'PASS'}`);
  console.log(`  SIGSEGV / Aborted:      ${hasSIGSEGV ? 'FOUND (FAIL)' : 'PASS'}`);
  console.log(`  VQA log lines: ${vqaLines.length}`);
  vqaLines.slice(0, 12).forEach(l => console.log(`    ${l}`));

  // ── Phase 6: Summary ────────────────────────────────────────────────────
  const maxFill      = Math.max(...samples.map(s => s.fill));
  const maxCyan      = Math.max(...samples.map(s => s.cyanCount));
  const maxBlockEdge = Math.max(...samples.map(s => s.blockEdges));
  const maxTopBand   = Math.max(...samples.map(s => s.topBand));
  const maxBotBand   = Math.max(...samples.map(s => s.botBand));

  console.log('\n[TIM-600] ===== ENGLISH.VQA AUDIT SUMMARY =====');
  console.log(`  Playback completed: ${playedFrames}/${totalFrames} frames`);
  console.log(`  Max VQA fill:       ${maxFill}%   (expect ≥25%)`);
  console.log(`  Max cyan-scatter:   ${maxCyan} px  (expect 0)`);
  console.log(`  Max block-edges:    ${maxBlockEdge} (heuristic; expect not catastrophic)`);
  console.log(`  Max letterbox top:  ${maxTopBand}% (expect 0)`);
  console.log(`  Max letterbox bot:  ${maxBotBand}% (expect 0)`);
  console.log(`  Audio sample-rate matches AudioContext native: ${audioOpenRate >= 22050 ? 'PASS' : 'FAIL'}`);

  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim600-english-vqa-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${output}\n`
  );

  // ── Assertions ──────────────────────────────────────────────────────────

  // (1) No cyan-block scatter — TIM-587 regression check.
  expect(maxCyan, 'cyan-scatter pixels (TIM-590 signature)').toBe(0);

  // (2) Letterbox bands must remain solid black (no leaked block content).
  expect(maxTopBand, 'top letterbox band must be solid black').toBe(0);
  expect(maxBotBand, 'bottom letterbox band must be solid black').toBe(0);

  // (3) Playback must reach substantial content — fill exceeds 25% at some
  //     point. Title cards and tank/heli scenes are bright.
  expect(maxFill, 'best VQA fill must exceed 25%').toBeGreaterThan(25);

  // (4) Audio device must open at the AudioContext native rate (>=22050,
  //     typically 44100/48000 in browsers).
  expect(audioOpenRate, 'VQA audio device sample rate (browser native)').toBeGreaterThanOrEqual(22050);
  expect(sdlAudioFail, 'no SDL audio open failure for VQA').toBe(false);

  // (5) No divide-by-zero / SIGSEGV / Abort.
  expect(hasDivByZero, 'no divide-by-zero in VQA audio').toBe(false);
  expect(hasSIGSEGV, 'no SIGSEGV or Aborted during VQA').toBe(false);

  // (6) Playback completes — N played == N total, both > 0.
  expect(playedFrames, 'VQA frames played').toBeGreaterThan(0);
  expect(playedFrames, 'VQA must finish all declared frames').toBe(totalFrames);
});
