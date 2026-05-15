import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

/**
 * TIM-708 — Capture WASM Allied L1 screenshots for Wine OG vs WASM comparison.
 *
 * Drives the WASM bundle in `?src=<asset-url>&autostart=1` mode, which fetches
 * MIX files over HTTP and boots straight into Allied Mission 1.  No "WASM_READY"
 * console text is emitted in this autostart path — we just wait long enough for
 * the bundle to compile, fetch MIX files, and render game content, then capture
 * snapshots at three timed checkpoints.
 *
 * Companion to scripts/wine-allied-l1.sh — see e2e/tim708/allied-l1/notes.md.
 */

const WASM_URL = 'http://localhost:8080/ra.html?src=http://localhost:9090&autostart=1';
const SHOTS_DIR = path.join(__dirname, 'tim708', 'allied-l1');

async function canvasStats(page: any) {
  return await page.evaluate(() => {
    const c = document.getElementById('canvas') as HTMLCanvasElement;
    const ctx = c.getContext('2d');
    if (!ctx) return { w: 0, h: 0, fill: 0, colors: 0 };
    const data = ctx.getImageData(0, 0, c.width, c.height).data;
    let nonBlack = 0;
    const palette = new Set<number>();
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i+1], b = data[i+2];
      if (r + g + b > 24) nonBlack++;
      palette.add((r << 16) | (g << 8) | b);
    }
    return {
      w: c.width, h: c.height,
      fill: Math.round((nonBlack / (c.width * c.height)) * 100),
      colors: palette.size,
    };
  });
}

test.describe('TIM-708 — WASM Allied L1 capture', () => {
  test.setTimeout(900_000);

  test('WASM reaches Allied L1 via ?src= HTTP source', async ({ page }) => {
    if (!fs.existsSync(SHOTS_DIR)) fs.mkdirSync(SHOTS_DIR, { recursive: true });

    const errors: string[] = [];
    page.on('pageerror', err => errors.push(err.message));

    await page.goto(WASM_URL, { timeout: 60_000 });

    // Wait for the canvas to actually have content (any non-black pixel).
    // Boot sequence on this host: ~10s MIX fetch + ~20s wasm compile + ~15s
    // game boot.  Cap waiting at 5 minutes before declaring broken.
    const startedAt = Date.now();
    let firstNonBlackAt = 0;
    while (Date.now() - startedAt < 5 * 60_000) {
      const s = await canvasStats(page);
      if (s.fill > 1) {
        firstNonBlackAt = Date.now();
        console.log(`First non-black canvas at +${Math.round((firstNonBlackAt - startedAt) / 1000)}s: fill=${s.fill}% colors=${s.colors}`);
        break;
      }
      await page.waitForTimeout(2_000);
    }
    expect(firstNonBlackAt, 'WASM canvas should produce non-black content within 5 min').toBeGreaterThan(0);

    // Capture three checkpoints from first-paint.
    const intervals = [5, 15, 30];
    let prev = 0;
    const results: Record<string, { fill: number; colors: number; bytes: number }> = {};
    for (const t of intervals) {
      await page.waitForTimeout((t - prev) * 1_000);
      prev = t;
      const s = await canvasStats(page);
      const name = `wasm-t${t}.png`;
      const out = path.join(SHOTS_DIR, name);
      await page.screenshot({
        path: out,
        clip: { x: 0, y: 0, width: 800, height: 540 },
      });
      const bytes = fs.statSync(out).size;
      console.log(`  ${name}: fill=${s.fill}% colors=${s.colors} bytes=${bytes}`);
      results[`t${t}`] = { fill: s.fill, colors: s.colors, bytes };
    }

    expect(errors.filter(e => !e.includes('ResizeObserver')),
      'no uncaught JS errors during gameplay').toHaveLength(0);

    // PASS if at least one checkpoint has substantive fill.
    const bestFill = Math.max(...Object.values(results).map(r => r.fill));
    expect(bestFill, 'best WASM frame fill ≥ 10%').toBeGreaterThanOrEqual(10);

    console.log('\nWASM Allied L1 capture summary:');
    for (const [t, r] of Object.entries(results)) {
      console.log(`  ${t}: fill=${r.fill}% colors=${r.colors} bytes=${r.bytes}`);
    }
  });
});
