/**
 * TIM-723 — TD cinematic equivalence between Wine OG and our WASM/native port.
 *
 * Mirrors TIM-705 (e2e/tim705-equivalence.spec.ts) for Red Alert: invokes
 * scripts/td-cinematic-compare.py which:
 *   - Extracts TD intro / campaign cinematic VQAs from MOVIES.MIX by name
 *     (TD MIX index is not Blowfish-encrypted, unlike RA — no FORM+WVQA byte
 *     scan needed)
 *   - For each VQA, decodes a representative frame with our Python decoder
 *     (proxy for our WASM/native port — it shares the same vqa_player.cpp
 *     codepath and was audited bit-exact by TIM-658)
 *     and with ffmpeg (proxy for the Westwood VQA decoder used by C&C95.EXE
 *     under Wine — clean-room reverse-engineering, frame-identical output)
 *   - Computes p99 pixel-channel delta + SSIM
 *   - PASS criterion: p99 ≤ 0 (pixel-exact)
 *   - Requires 6+ VQAs to pass for the suite to pass (mirrors TIM-705)
 *
 * The TD VQAs compared by default:
 *   LOGO.VQA, INTRO2.VQA, TBRINFO2.VQA, TBRINFO3.VQA,
 *   GDIFINA.VQA, NAPALM.VQA, VISOR.VQA, BANNER.VQA
 *
 * Environment:
 *   TD_MOVIES_MIX   override MOVIES.MIX path
 *                   default: /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/MOVIES.MIX
 */

import { test, expect } from '@playwright/test';
import * as child_process from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const REPO_ROOT  = path.resolve(__dirname, '..');
const DATA_DIR   = process.env.TD_DATA_DIR
                   || '/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1';
const MOVIES_MIX = process.env.TD_MOVIES_MIX
                   || path.join(DATA_DIR, 'MOVIES.MIX');

test.describe('TIM-723 — TD cinematic midpoint comparison (port vs Wine OG)', () => {

  test('≥ 6 TD VQA frames pass p99 ≤ 0 (pixel-exact) [requires MOVIES.MIX + ffmpeg]',
    { tag: ['@vqa', '@cinematic', '@td'] },
    () => {
      test.skip(!fs.existsSync(MOVIES_MIX),
        `MOVIES.MIX not found at ${MOVIES_MIX} — skipping TD cinematic comparison`);

      const ffmpegCheck = child_process.spawnSync('ffmpeg', ['-version'], { encoding: 'utf-8' });
      test.skip(ffmpegCheck.status !== 0,
        'ffmpeg not available — skipping TD cinematic comparison');

      const outDir = path.join(REPO_ROOT, 'e2e', 'td-cinematic-compare');
      const script = path.join(REPO_ROOT, 'scripts', 'td-cinematic-compare.py');

      const result = child_process.spawnSync(
        'python3',
        [script, '--mix', MOVIES_MIX, '--out-dir', outDir, '--threshold', '0', '--max-vqas', '8'],
        { encoding: 'utf-8', timeout: 600_000 },
      );

      console.log('=== td-cinematic-compare.py stdout ===');
      console.log(result.stdout);
      if (result.stderr) {
        console.log('=== td-cinematic-compare.py stderr ===');
        console.log(result.stderr);
      }

      const reportPath = path.join(outDir, 'report.json');
      let report: any = null;
      if (fs.existsSync(reportPath)) {
        report = JSON.parse(fs.readFileSync(reportPath, 'utf-8'));
        console.log('=== Report summary ===');
        console.log(JSON.stringify(report.summary, null, 2));
        console.log('=== Per-VQA results ===');
        for (const r of report.results) {
          const ssim = r.ssim !== undefined ? ` ssim=${r.ssim.toFixed(4)}` : '';
          console.log(`  [${r.status}] ${r.label}: frame=${r.compare_frame}/${r.num_frames} `
                    + `p99=${r.p99 ?? '?'} mean=${r.mean ?? '?'}${ssim}`);
        }
      }

      if (result.status === 2) {
        test.skip(true, `td-cinematic-compare.py SKIP: ${result.stderr || result.stdout}`);
      }

      expect(result.status,
        'td-cinematic-compare.py should exit 0 or 1').toBeLessThanOrEqual(1);
      expect(report, 'report.json should be generated').not.toBeNull();

      const passCount = report?.summary?.pass ?? 0;
      const failList  = (report?.results ?? []).filter((r: any) => r.status === 'FAIL');

      if (failList.length > 0) {
        console.log('=== FAILED VQAs ===');
        for (const f of failList) {
          console.log(`  FAIL: ${f.label} — p99=${f.p99} mean=${f.mean} diff=${f.diff_image ?? 'n/a'}`);
        }
      }

      expect(passCount, '≥ 6 TD cinematics must pass the p99 ≤ 0 threshold')
        .toBeGreaterThanOrEqual(6);
    }
  );
});
