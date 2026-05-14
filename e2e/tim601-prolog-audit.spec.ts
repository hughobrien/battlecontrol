/**
 * TIM-601 — RA WASM PROLOG.VQA (Trinity/prologue) verification.
 *
 * Boots ra.html without RA_AUTOSTART so Play_Intro runs the full sequence:
 *   1. ENGLISH.VQA  (160 frames @ 15fps ≈ 10.7s)
 *   2. PROLOG.VQA   (2856 frames @ 15fps ≈ 190s — Trinity nuclear-test prologue)
 *
 * Waits for `[VQA] Playing 'PROLOG.VQA'`, then samples mid-playback frames.
 *
 * Acceptance:
 *   1. No banding / cyan-block scatter (TIM-587 signature)
 *   2. No black squares / missing regions (frame fill % stays substantial)
 *   3. Audio opens at AudioContext.sampleRate, no divide-by-zero (TIM-583)
 *   4. Playback completes — "[VQA] 'PROLOG.VQA' done (2856/2856 frames)"
 *   5. No SIGSEGV / Aborted
 *   6. Mid-playback screenshot recognisable as Trinity prologue footage
 *
 * Requires servers running:
 *   serve-coop.py on :8080 (build-wasm/ or build-wasm-fresh/)
 *   serve-assets.py on :9090 (/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
 */

import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const ASSET_URL       = 'http://localhost:9090/';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOTS_DIR)) fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

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
      // Cyan-scatter signature (TIM-587): high G+B, low R
      if (r < 32 && g > 180 && b > 180) cyanCount++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h, cyanCount };
  });
}

/**
 * Sample largest 32x32 region of pure black inside the active VQA viewport
 * (excluding letterbox). "black squares" symptom from TIM-590 manifests as
 * 32x32 (or larger) chunks of solid 0,0,0 in regions that should have content.
 * Returns the largest contiguous 32x32 fully-black block count.
 *
 * For 320×156 PROLOG.VQA scaled 2x = 640×312, centred in 640×480 canvas,
 * top letterbox = (480-312)/2 = 84px, so VQA content occupies y ∈ [84, 396).
 */
async function blackSquareCount(page: any): Promise<number> {
  return page.evaluate(() => {
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    if (!canvas) return 0;
    const ctx = canvas.getContext('2d');
    if (!ctx) return 0;
    const w = canvas.width, h = canvas.height;
    // VQA viewport for 320×156 scaled 2x: y in [84,396)
    const y0 = 84, y1 = Math.min(396, h);
    const x0 = 0, x1 = w;
    const data = ctx.getImageData(x0, y0, x1 - x0, y1 - y0).data;
    const W = x1 - x0, H = y1 - y0;
    const BLK = 32;
    let blackBlocks = 0;
    for (let by = 0; by + BLK <= H; by += BLK) {
      for (let bx = 0; bx + BLK <= W; bx += BLK) {
        let allBlack = true;
        outer: for (let dy = 0; dy < BLK; dy++) {
          for (let dx = 0; dx < BLK; dx++) {
            const i = ((by + dy) * W + (bx + dx)) * 4;
            if (data[i] > 5 || data[i+1] > 5 || data[i+2] > 5) { allBlack = false; break outer; }
          }
        }
        if (allBlack) blackBlocks++;
      }
    }
    return blackBlocks;
  });
}

test('TIM-601 PROLOG.VQA visual + audio verification', async ({ page }) => {
  test.setTimeout(900_000);  // 15 min — ENGLISH (10s) + PROLOG (190s) + margin

  const consoleLogs: string[] = [];
  const pageErrors: string[] = [];
  page.on('console', (msg: any) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
  page.on('pageerror', (err: Error) => pageErrors.push(err.message));

  const url = `${WASM_URL}?src=${encodeURIComponent(ASSET_URL)}&debug=1`;
  console.log(`[TIM-601] loading ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  // ── Phase 1: Preloader ─────────────────────────────────────────────────
  console.log('\n[TIM-601] === Phase 1: Preloader ===');
  await page.waitForFunction(
    () => {
      const overlay = document.getElementById('preloader-overlay');
      return overlay !== null && overlay.style.display === 'none';
    },
    null,
    { timeout: 180_000 }
  );
  console.log('  preloader hidden ✓');

  // ── Phase 2: Wait for ENGLISH.VQA to finish ────────────────────────────
  console.log('\n[TIM-601] === Phase 2: ENGLISH.VQA → done ===');
  await waitForOutput(page, "[VQA] 'ENGLISH.VQA' done", 300_000);
  console.log('  ENGLISH.VQA done ✓');

  // ── Phase 3: Wait for PROLOG.VQA to start ──────────────────────────────
  console.log('\n[TIM-601] === Phase 3: PROLOG.VQA start ===');
  await waitForOutput(page, "[VQA] Playing 'PROLOG.VQA'", 60_000);
  const prologStartMs = Date.now();
  console.log('  PROLOG.VQA Playing fired ✓');

  // ── Phase 4: Mid-playback frame sampling ───────────────────────────────
  // PROLOG.VQA: 320×156 @ 15fps, 2856 frames → 190s total.
  // Sample at t≈3s/20s/60s/120s/180s into PROLOG to cover early/mid/late.
  console.log('\n[TIM-601] === Phase 4: PROLOG.VQA frame sampling ===');
  const samples: {label: string; offsetMs: number; fill: number; colors: number; cyanCount: number; blackBlocks: number}[] = [];

  const schedule: [string, number][] = [
    ['early-t3s',   3_000],
    ['mid-t20s',   20_000],
    ['mid-t60s',   60_000],
    ['mid-t120s', 120_000],
    ['late-t180s',180_000],
  ];

  for (const [label, targetMs] of schedule) {
    const waitMs = targetMs - (Date.now() - prologStartMs);
    if (waitMs > 0) await page.waitForTimeout(waitMs);
    const t = Date.now() - prologStartMs;
    const stats = await canvasStats(page);
    const blackBlocks = await blackSquareCount(page);
    samples.push({ label, offsetMs: t, ...stats, blackBlocks });
    const slug = label.replace(/[^a-z0-9]+/gi, '-');
    await page.screenshot({ path: path.join(SCREENSHOTS_DIR, `tim601-prolog-${slug}.png`) });
    console.log(`  [${label} @ t=${(t/1000).toFixed(1)}s] fill=${stats.fill}%  colors=${stats.colors}  cyanPx=${stats.cyanCount}  blackBlocks(32×32)=${blackBlocks}`);
  }

  // ── Phase 5: Wait for PROLOG.VQA done ──────────────────────────────────
  console.log('\n[TIM-601] === Phase 5: PROLOG.VQA done ===');
  await waitForOutput(page, "[VQA] 'PROLOG.VQA' done", 120_000);
  const prologEndMs = Date.now();
  const playbackDurationS = (prologEndMs - prologStartMs) / 1000;
  console.log(`  PROLOG.VQA done ✓  (wall-clock playback ${playbackDurationS.toFixed(1)}s — expected ~190s for 2856 frames @ 15fps)`);

  // ── Phase 6: Log analysis ──────────────────────────────────────────────
  console.log('\n[TIM-601] === Phase 6: Log analysis ===');
  const output = await getOutput(page);
  const vqaLines = [...output.matchAll(/\[VQA\][^\n]*/g)].map(m => m[0]);
  const hasAudioCtxRate = vqaLines.some(l => l.includes('WASM audio: opening at'));
  const audioOpenLine = vqaLines.find(l => l.includes('WASM audio: opening at') && Number.isFinite(prologStartMs));
  const audioOpenRate = audioOpenLine ? (audioOpenLine.match(/at (\d+) Hz/)?.[1] ?? null) : null;
  const prologPlayLine = vqaLines.find(l => l.includes("Playing 'PROLOG.VQA'"));
  const prologSourceHz = prologPlayLine ? (prologPlayLine.match(/hz=(\d+)/)?.[1] ?? null) : null;
  const prologDoneLine = vqaLines.find(l => l.includes("'PROLOG.VQA' done"));
  const playedFrames = prologDoneLine ? (prologDoneLine.match(/\((\d+)\/(\d+) frames\)/) ?? null) : null;

  const hasDivByZero = output.includes('integer overflow') ||
    pageErrors.some(e => /divide.*zero|integer overflow|trap.*div/i.test(e)) ||
    consoleLogs.some(l => /divide.*zero|integer overflow|trap.*div/i.test(l));
  const hasSIGSEGV = output.includes('SIGSEGV') || output.includes('Aborted(');
  const hasNullFunc = pageErrors.some(e => /null function|null function or function signature mismatch/i.test(e)) ||
    consoleLogs.some(l => /null function/i.test(l));

  console.log(`  PROLOG source hz: ${prologSourceHz}`);
  console.log(`  Audio device rate: ${audioOpenRate} Hz`);
  console.log(`  Frames played: ${playedFrames ? playedFrames[0] : 'NOT FOUND'}`);
  console.log(`  Divide-by-zero / abort: ${hasDivByZero ? 'FOUND (FAIL)' : 'PASS (none)'}`);
  console.log(`  SIGSEGV / Aborted: ${hasSIGSEGV ? 'FOUND (FAIL)' : 'PASS (none)'}`);
  console.log(`  Null-function trap: ${hasNullFunc ? 'FOUND (FAIL)' : 'PASS (none)'}`);
  console.log(`  VQA log lines: ${vqaLines.length}`);
  vqaLines.forEach(l => console.log(`    ${l}`));

  // Save console log
  fs.writeFileSync(
    path.join(SCREENSHOTS_DIR, 'tim601-prolog-console.log'),
    `=== console ===\n${consoleLogs.join('\n')}\n=== pageErrors ===\n${pageErrors.join('\n')}\n=== #output ===\n${output}\n`
  );

  // ── Phase 7: Summary ────────────────────────────────────────────────────
  const maxFill = Math.max(...samples.map(s => s.fill));
  const maxCyan = Math.max(...samples.map(s => s.cyanCount));
  const maxBlackBlocks = Math.max(...samples.map(s => s.blackBlocks));
  const midSampleFill = samples.find(s => s.label === 'mid-t60s')?.fill ?? 0;

  console.log('\n[TIM-601] ===== PROLOG.VQA AUDIT SUMMARY =====');
  console.log(`  PROLOG hz=${prologSourceHz}  device=${audioOpenRate} Hz  (ratio=${prologSourceHz && audioOpenRate ? (Number(audioOpenRate)/Number(prologSourceHz)).toFixed(2) : 'n/a'})`);
  console.log(`  Wall-clock playback: ${playbackDurationS.toFixed(1)}s  (expected ~190s — drift = ${(playbackDurationS - 190).toFixed(1)}s)`);
  console.log(`  Frames: ${playedFrames ? playedFrames[0] : 'NOT FOUND'}`);
  console.log(`  Max VQA fill across samples: ${maxFill}%`);
  console.log(`  Mid-playback fill (t60s): ${midSampleFill}%`);
  console.log(`  Max cyan-scatter pixels:   ${maxCyan}  (expect 0 after TIM-587)`);
  console.log(`  Max 32x32 black-block count in VQA viewport: ${maxBlackBlocks}  (high count = missing-region symptom)`);
  console.log(`  Audio open: ${hasAudioCtxRate ? 'YES' : 'NO'}  Divide-by-zero: ${hasDivByZero ? 'FAIL' : 'PASS'}  SIGSEGV: ${hasSIGSEGV ? 'FAIL' : 'PASS'}  Null-fn: ${hasNullFunc ? 'FAIL' : 'PASS'}`);

  // ── Assertions ─────────────────────────────────────────────────────────
  // PROLOG.VQA must play to completion (acceptance #5)
  expect(playedFrames?.[1], 'PROLOG.VQA frames played').toBe('2856');
  expect(playedFrames?.[2], 'PROLOG.VQA total frames').toBe('2856');

  // No cyan scatter (acceptance #1)
  expect(maxCyan, 'cyan-scatter pixels (TIM-587 / TIM-590): must be 0').toBe(0);

  // Audio device opened (acceptance #3 — sampling-rate query must succeed)
  expect(hasAudioCtxRate, 'audio device opened with sampleRate logged (TIM-583)').toBe(true);
  expect(hasDivByZero, 'no divide-by-zero (TIM-583 fix)').toBe(false);
  expect(hasNullFunc, 'no null-function trap (TIM-593 fix)').toBe(false);
  expect(hasSIGSEGV, 'no SIGSEGV / Aborted (acceptance #5)').toBe(false);

  // Playback pacing — wall-clock close to expected duration (acceptance #4)
  // If audio runs at 2x speed it would drag video pacing or finish early; expect ±20% of 190s
  expect(playbackDurationS, 'PROLOG wall-clock duration roughly 190s ±20%').toBeGreaterThan(150);
  expect(playbackDurationS, 'PROLOG wall-clock duration roughly 190s ±20%').toBeLessThan(240);

  // Visual liveness — at least one mid sample with substantial fill (acceptance #2/#6)
  expect(maxFill, 'PROLOG VQA must produce visible content at some point').toBeGreaterThan(15);
});
