---
name: frame-sequence-parity
description: Use when Wine/native Red Alert gameplay screenshots drift by frame, PRNG, palette phase, or capture timing and single-frame parity screenshots are too noisy to diagnose.
---

# Frame Sequence Parity

Use this when a visual divergence might be caused by timing, animation phase, palette cycling, PRNG state, or screenshot delay. The goal is to establish a root of trust before debugging pixels: each target must be internally reproducible, then Wine/native sequences are aligned by measured frame offset.

## Workflow

1. Capture two Wine RA-clock sequences for the same mission and prove they match.

```bash
python3 scripts/capture-wine-sequence.py allied-l1 \
  --clock ra --start 50 --count 100 --fps 60
```

Success means both runs report frames `50..149` and compare `100/100` frame hashes equal. Prefer RA-clock over render-clock; render-loop ordinal is not stable enough near mission entry.

2. Capture two native sequences and prove they match.

```bash
RA_BIN=$PWD/result/bin/redalert \
RA_ASSETS=/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 \
python3 scripts/capture-native-sequence.py allied-l1 \
  --start 50 --count 100 --fps 60
```

Success means both native runs report frames `50..149` and compare `100/100` RGBA hashes equal. Native capture uses frame-derived palette cycling during sequence capture, so real-time `Color_Cycle()` phase should not drift.

3. Sweep Wine/native frame offsets and generate aligned review artifacts.

```bash
python3 scripts/compare-frame-sequences.py \
  --a /tmp/battlecontrol/<wine-run>/wine-sequence-report.json \
  --b /tmp/battlecontrol/<native-run>/native-sequence-report.json \
  --offset-min -10 --offset-max 10 \
  --out /tmp/battlecontrol/sequence-align-wine-native \
  --sample-frames 50,60,70,90,120,140
```

For the current Allied L1 corpus, best alignment is native `wine+2`. Do not force offset zero; first prove both sides describe the same simulation/render boundary.

4. Serve artifacts for review.

```bash
setsid sh -c 'exec python3 -m http.server 1234 -b 0.0.0.0 -d /tmp/battlecontrol >>/tmp/battlecontrol-server.log 2>&1' </dev/null >/dev/null 2>&1 &
```

Browse `http://bigthink.wg:1234/<run>/` or the local `http://127.0.0.1:1234/<run>/`.

## Interpretation

- If a target is not internally reproducible, do not debug Wine/native pixels yet. Fix root-of-trust capture first.
- If internal reproducibility passes but best offset is nonzero, treat that as capture-boundary evidence, not a bug by itself.
- If aligned residuals are localized clusters, debug those as real rendering/state divergences.
- If residuals move broadly with offset, alignment or mission-entry state is still uncontrolled.

## Common Mistakes

- Comparing one Wine screenshot to one native screenshot before proving each target is stable.
- Using render-clock sequences near mission entry and assuming frame labels mean the same thing.
- Treating fixed PRNG seed as complete determinism; palette phase, callbacks, and capture boundary can still differ.
- Leaving stale diagnostic source edits in the worktree while collecting new evidence.
