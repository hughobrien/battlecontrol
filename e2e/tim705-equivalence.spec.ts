/**
 * TIM-705 — Wine OG Red Alert vs Linux Port equivalence tests.
 *
 * Part A — Cinematic midpoint comparison (6+ VQAs):
 *   Invokes scripts/cinematic-compare.py which:
 *   - Scans MAIN.MIX for VQA blobs (raw byte scan, Blowfish-encrypted index bypassed)
 *   - For each VQA, decodes midpoint frame with our Python decoder (port)
 *     and with ffmpeg (proxy for the Westwood decoder used by RA95.EXE under Wine)
 *   - Computes p99 pixel-channel delta + SSIM
 *   - PASS criterion: p99 ≤ 8, SSIM ≥ 0.85 if computable
 *   - Requires 6+ VQAs to pass for the suite to pass
 *
 * Part B — Allied L1 gameplay comparison (WASM port):
 *   - Navigates WASM port to Allied Mission 1 (SCG01EA.INI)
 *   - Captures screenshots at t=0 (mission load), t=10s, t=30s in-game
 *   - Validates canvas fill ≥ 20% at each checkpoint (non-black = game is rendering)
 *   - No crash within 30s of gameplay
 *
 * Part B — Allied L1 gameplay comparison (Wine OG, requires WINE_RA_READY=1):
 *   - Runs scripts/wine-gameplay.sh (Xvfb + xdotool navigation)
 *   - Validates 4+ screenshots are > 5KB (non-blank frames)
 *   - Compares fill% parity with WASM port screenshots
 *
 * Environment:
 *   WINE_RA_READY=1            enable Wine gameplay tests (requires wine32 + RA95.EXE)
 *   RA_EXE_PATH                override RA95.EXE path (default: /opt/redalert/RA95.EXE)
 *   DATA_DIR                   override CD1 data dir
 *
 * Servers required for WASM tests:
 *   serve-coop.py   on :8080   (WASM bundle)
 *   serve-assets.py on :9090   (CD1 MIX files)
 *
 * Navigation flow (WASM port, confirmed in TIM-697):
 *   1. Click "New Campaign" at canvas (322, 183)
 *   2. Wait for [DIFF] dialog ready → click difficulty OK at (470, 244)
 *   3. Wait for [INIT] faction dialog ready → click Allied at (258, 268)
 *   4. Wait for Start_Scenario log
 *   5. Screenshots at frame 200, frame 400, frame 600
 */

import { test, expect }     from '@playwright/test';
import * as child_process   from 'child_process';
import * as fs              from 'fs';
import * as path            from 'path';

const WASM_URL        = 'http://localhost:8080/ra.html';
const SCREENSHOTS_DIR = path.join(__dirname, 'screenshots');
const REPO_ROOT       = path.resolve(__dirname, '..');
const DATA_DIR        = process.env.DATA_DIR
                        || '/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1';
const MAIN_MIX        = path.join(DATA_DIR, 'MAIN.MIX');

const WINE_RA_READY   = process.env.WINE_RA_READY === '1';

if (!fs.existsSync(SCREENSHOTS_DIR)) {
  fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

async function waitForOutput(page: any, substring: string, timeoutMs = 300_000) {
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
    if (!canvas) return { fill: 0, colors: 0, w: 0, h: 0 };
    const ctx = canvas.getContext('2d');
    if (!ctx) return { fill: 0, colors: 0, w: canvas.width, h: canvas.height };
    const { width: w, height: h } = canvas;
    const data = ctx.getImageData(0, 0, w, h).data;
    let nonBlack = 0;
    const colorSet = new Set<number>();
    const total = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i+1], b = data[i+2];
      if (r > 15 || g > 15 || b > 15) nonBlack++;
      colorSet.add((r >> 3) << 10 | (g >> 3) << 5 | (b >> 3));
    }
    return { fill: Math.round(nonBlack / total * 100), colors: colorSet.size, w, h };
  });
}

// Install VQA auto-skip via console injection (mirrors TIM-697 pattern).
async function installVqaAutoSkip(page: any): Promise<() => Promise<void>> {
  const cancelHandle = await page.evaluateHandle(() => {
    const origPlay = (window as any).__vqaPlay;
    let cancelled = false;
    const iv = setInterval(() => {
      if (cancelled) { clearInterval(iv); return; }
      const out = document.getElementById('output');
      if (out && out.textContent && out.textContent.includes('[VQA] playing')) {
        const canvas = document.getElementById('canvas') as HTMLCanvasElement;
        if (canvas) canvas.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true }));
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true }));
      }
    }, 500);
    return { cancel: () => { cancelled = true; clearInterval(iv); } };
  });
  return async () => {
    await page.evaluate((h: any) => h.cancel(), cancelHandle);
    cancelHandle.dispose();
  };
}

// ---------------------------------------------------------------------------
// Part A — Cinematic midpoint comparison
// ---------------------------------------------------------------------------

test.describe('Part A — Cinematic midpoint comparison (port vs Wine OG)', () => {

  test('6+ VQA midpoints pass p99 ≤ 8 and SSIM ≥ 0.85 [requires MAIN.MIX + ffmpeg]',
    { tag: ['@vqa', '@cinematic'] },
    () => {
      test.skip(!fs.existsSync(MAIN_MIX),
        `MAIN.MIX not found at ${MAIN_MIX} — skipping cinematic comparison`);

      // Check ffmpeg
      const ffmpegCheck = child_process.spawnSync('ffmpeg', ['-version'], { encoding: 'utf-8' });
      test.skip(ffmpegCheck.status !== 0, 'ffmpeg not available — skipping cinematic comparison');

      const outDir = path.join(REPO_ROOT, 'e2e', 'cinematic-compare');
      const script = path.join(REPO_ROOT, 'scripts', 'cinematic-compare.py');

      const result = child_process.spawnSync(
        'python3',
        [script, MAIN_MIX, '--out-dir', outDir, '--threshold', '8', '--max-vqas', '8'],
        { encoding: 'utf-8', timeout: 600_000 },  // 10 min for 8 VQAs
      );

      console.log('=== cinematic-compare.py stdout ===');
      console.log(result.stdout);
      if (result.stderr) {
        console.log('=== cinematic-compare.py stderr ===');
        console.log(result.stderr);
      }

      // Load JSON report
      const reportPath = path.join(outDir, 'report.json');
      let report: any = null;
      if (fs.existsSync(reportPath)) {
        report = JSON.parse(fs.readFileSync(reportPath, 'utf-8'));
        console.log('=== Report summary ===');
        console.log(JSON.stringify(report.summary, null, 2));
        console.log('=== Per-VQA results ===');
        for (const r of report.results) {
          const ssimStr = r.ssim !== undefined ? ` ssim=${r.ssim.toFixed(4)}` : '';
          console.log(`  [${r.status}] ${r.label}: frames=${r.num_frames} midpoint=${r.midpoint} p99=${r.p99 ?? '?'} mean=${r.mean ?? '?'}${ssimStr}`);
        }
      }

      // Exit code 2 = SKIP (no data), not a failure
      if (result.status === 2) {
        test.skip(true, `cinematic-compare.py returned SKIP: ${result.stderr || result.stdout}`);
      }

      expect(result.status, 'cinematic-compare.py should exit 0 or 1').toBeLessThanOrEqual(1);
      expect(report, 'report.json should be generated').not.toBeNull();

      const passCount = report?.summary?.pass ?? 0;
      const failList  = (report?.results ?? []).filter((r: any) => r.status === 'FAIL');

      // Log failures with diff artifacts
      if (failList.length > 0) {
        console.log('=== FAILED VQAs ===');
        for (const f of failList) {
          console.log(`  FAIL: ${f.label} — p99=${f.p99} mean=${f.mean} diff=${f.diff_image ?? 'n/a'}`);
        }
      }

      expect(passCount, '≥ 6 cinematics must pass the p99 ≤ 8 threshold').toBeGreaterThanOrEqual(6);
    }
  );
});

// ---------------------------------------------------------------------------
// Part B — Allied L1 gameplay comparison (WASM port)
// ---------------------------------------------------------------------------

test.describe('Part B — Allied L1 gameplay (WASM port)', () => {
  test.setTimeout(900_000);

  test('WASM port reaches Allied L1, map renders non-black for 30s without crash',
    { tag: ['@gameplay', '@wasm'] },
    async ({ page }) => {
      const consoleLines: string[] = [];
      const errors: string[] = [];
      page.on('console', msg => consoleLines.push(`[${msg.type()}] ${msg.text()}`));
      page.on('pageerror', err => errors.push(`[pageerror] ${err.message}`));

      await page.goto(`${WASM_URL}?autostart=0`, { timeout: 120_000 });
      await waitForOutput(page, 'WASM_READY', 120_000);
      console.log('WASM ready');

      // Skip VQAs quickly
      const cancelSkip = await installVqaAutoSkip(page);

      // Wait for main menu
      await waitForOutput(page, '[RA] Main_Loop frame', 90_000);
      await page.waitForTimeout(3_000);

      const menuStats = await canvasStats(page);
      console.log(`Menu: fill=${menuStats.fill}% colors=${menuStats.colors}`);
      expect(menuStats.fill, 'main menu fill ≥ 30%').toBeGreaterThanOrEqual(30);

      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'tim705-wasm-menu.png'),
        fullPage: true,
      });

      // Navigate to Allied L1
      // Step 1: New Campaign
      await page.locator('#canvas').click({ position: { x: 322, y: 183 } });
      console.log('Clicked New Campaign at (322, 183)');

      await waitForOutput(page, '[MENU] input=0x', 30_000);

      // Step 2: Difficulty dialog
      await waitForOutput(page, '[DIFF] dialog ready', 30_000);
      await page.waitForTimeout(500);
      await page.locator('#canvas').click({ position: { x: 470, y: 244 } });
      console.log('Accepted difficulty dialog at (470, 244)');

      // Step 3: Faction dialog → Allied
      await waitForOutput(page, '[INIT] faction dialog ready', 30_000);
      await page.waitForTimeout(500);
      await page.locator('#canvas').click({ position: { x: 258, y: 268 } });
      console.log('Selected Allied faction at (258, 268)');

      await cancelSkip();

      // Step 4: Wait for Start_Scenario (mission load)
      await waitForOutput(page, 'Start_Scenario', 120_000);
      console.log('Start_Scenario logged — mission loaded');

      // Wait for first in-game frame after scenario start
      await waitForOutput(page, 'frame 200', 120_000);

      // Screenshot t=0 (mission loaded)
      const t0Stats = await canvasStats(page);
      console.log(`t=0: fill=${t0Stats.fill}% colors=${t0Stats.colors}`);
      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'tim705-wasm-allied-l1-t0.png'),
        fullPage: true,
      });

      expect(t0Stats.fill, 'Allied L1 t=0 fill ≥ 20% (map rendered)').toBeGreaterThanOrEqual(20);
      expect(t0Stats.w, 'canvas width should be 640').toBe(640);
      expect(t0Stats.h, 'canvas height should be 480').toBe(480);

      // Wait ~10s in-game (frame advance)
      await waitForOutput(page, 'frame 350', 60_000);
      const t10Stats = await canvasStats(page);
      console.log(`t≈10s: fill=${t10Stats.fill}%`);
      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'tim705-wasm-allied-l1-t10.png'),
        fullPage: true,
      });
      expect(t10Stats.fill, 'Allied L1 t≈10s fill ≥ 20%').toBeGreaterThanOrEqual(20);

      // Wait ~30s in-game
      await waitForOutput(page, 'frame 600', 120_000);
      const t30Stats = await canvasStats(page);
      console.log(`t≈30s: fill=${t30Stats.fill}%`);
      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'tim705-wasm-allied-l1-t30.png'),
        fullPage: true,
      });
      expect(t30Stats.fill, 'Allied L1 t≈30s fill ≥ 20%').toBeGreaterThanOrEqual(20);

      // No crashes
      expect(errors.filter(e => !e.includes('ResizeObserver')),
        'no uncaught JS errors in gameplay').toHaveLength(0);

      console.log(`Allied L1 gameplay test PASS: t0=${t0Stats.fill}% t10=${t10Stats.fill}% t30=${t30Stats.fill}%`);
    }
  );
});

// ---------------------------------------------------------------------------
// Part B — Allied L1 gameplay comparison (Wine OG)
// ---------------------------------------------------------------------------

test.describe('Part B — Allied L1 gameplay (Wine OG) [tag:wine]', () => {
  test.beforeEach(() => {
    test.skip(!WINE_RA_READY,
      'Skipped: set WINE_RA_READY=1 and ensure wine32 + RA95.EXE are installed');
  });

  test('Wine OG captures 4+ non-blank screenshots navigating to Allied L1',
    { tag: ['@gameplay', '@wine'] },
    () => {
      test.setTimeout(300_000);  // 5 min — Wine gameplay is slow

      const shotDir = SCREENSHOTS_DIR;
      const script  = path.join(REPO_ROOT, 'scripts', 'wine-gameplay.sh');

      const result = child_process.spawnSync(
        'bash',
        [script, process.env.RA_EXE_PATH || '/opt/redalert/RA95.EXE', DATA_DIR, shotDir],
        { encoding: 'utf-8', timeout: 280_000 },
      );

      console.log('=== wine-gameplay.sh stdout ===');
      console.log(result.stdout);
      if (result.stderr) {
        console.log('=== wine-gameplay.sh stderr ===');
        console.log(result.stderr.slice(0, 2000));
      }

      // Exit code 2 = SKIP
      if (result.status === 2) {
        test.skip(true, 'wine-gameplay.sh returned SKIP — Wine not available');
      }

      // Verify screenshots
      const expectedShots = [
        'wine-allied-l1-t0.png',
        'wine-allied-l1-t5.png',
        'wine-allied-l1-t30.png',
        'wine-allied-l1-t60.png',
        'wine-allied-l1-t120.png',
      ];

      let passCount = 0;
      for (const name of expectedShots) {
        const p = path.join(shotDir, name);
        if (fs.existsSync(p)) {
          const sz = fs.statSync(p).size;
          console.log(`  ${name}: ${sz} bytes`);
          if (sz > 5_000) passCount++;
        } else {
          console.log(`  MISS: ${name}`);
        }
      }

      expect(passCount, 'at least 4 non-blank Wine gameplay screenshots required').toBeGreaterThanOrEqual(4);
      expect(result.status, 'wine-gameplay.sh should exit 0').toBe(0);
    }
  );

  test('Wine t=0 screenshot fill% comparable to WASM t=0 (both ≥ 20%)',
    { tag: ['@gameplay', '@wine', '@parity'] },
    async ({ page }) => {
      test.setTimeout(600_000);

      // Check Wine screenshot exists from prior test
      const wineShot = path.join(SCREENSHOTS_DIR, 'wine-allied-l1-t0.png');
      test.skip(!fs.existsSync(wineShot),
        'wine-allied-l1-t0.png not found — run Wine gameplay test first');

      // Check WASM screenshot
      const wasmShot = path.join(SCREENSHOTS_DIR, 'tim705-wasm-allied-l1-t0.png');
      test.skip(!fs.existsSync(wasmShot),
        'tim705-wasm-allied-l1-t0.png not found — run WASM gameplay test first');

      // Both files exist — compute fill% comparison via Python
      const result = child_process.spawnSync(
        'python3', ['-c', `
import sys, struct, zlib
def read_png(p):
    d = open(p,'rb').read()
    pos,w,h,idat = 8,0,0,b''
    while pos < len(d):
        sz = struct.unpack_from('>I',d,pos)[0]
        tag = d[pos+4:pos+8]
        body = d[pos+8:pos+8+sz]
        if tag == b'IHDR': w,h = struct.unpack_from('>II',body,0)
        elif tag == b'IDAT': idat += body
        pos += 12 + sz
    raw = zlib.decompress(idat)
    row_sz = 1 + w*3
    pixels = bytearray()
    for y in range(h): pixels += raw[1+y*row_sz:(y+1)*row_sz]
    return w,h,pixels

def fill_pct(path):
    w,h,px = read_png(path)
    nb = sum(1 for i in range(0,len(px),3) if px[i]>15 or px[i+1]>15 or px[i+2]>15)
    return round(nb / (w*h) * 100, 1)

wine = fill_pct(sys.argv[1])
wasm = fill_pct(sys.argv[2])
print(f'Wine t=0 fill: {wine}%')
print(f'WASM t=0 fill: {wasm}%')
print('PASS' if wine >= 20 and wasm >= 20 else 'FAIL')
`,
          wineShot, wasmShot,
        ],
        { encoding: 'utf-8', timeout: 30_000 },
      );

      console.log(result.stdout);
      expect(result.stdout).toContain('PASS');
    }
  );
});
