# TIM-708 Allied L1 — Wine OG gameplay capture

## What's proven

With the full patch chain (NoCD + DDSCL_NORMAL + probe-skip + focus-skip +
game-in-focus pin + cdlabel + vqa-skip) plus cnc-ddraw v7.5.0 (gdi
renderer, windowed) plus Xvfb + openbox plus `d:=cdrom` in the Wine
registry, **Red Alert 95 boots into the Allied Mission 1 "Find Einstein"
AUTODEMO recording within 6 seconds** under Wine 10.0 and renders it
in an X11-capturable window.

Evidence in this directory:

| File | Bytes | Content |
|---|---|---|
| `mission-t0.png` | 82594 | Allied L1 snowy terrain, infantry + jeeps + buildings + radar sidebar, "Find Einstein" objective top-left |
| `mission-t3.png` | 83635 | demo advanced — helicopter dropped in, units moved |
| `mission-t6.png` … `mission-t17.png` | 70444 | crash dialog "Application Error: D:\HA95.EXE — instruction 00534273 referenced memory 00000000" overlaid on demo map |

## Why the crash

RA's AUTODEMO recording dereferences a null pointer at instruction
`0x00534273` somewhere between t=3s and t=6s. Crash is non-deterministic
(an earlier run captured t=5 at 83544 bytes of clean gameplay, then
TOP SCORES at t=30 — no crash). Root cause not yet diagnosed.

The crash is **inside the AUTODEMO playback path**, not the interactive
mission code path. Driving the menu via SendInput to start an actual
interactive game (instead of the demo) would likely avoid this code.

## Why we relied on AUTODEMO

Driving the menu via SendInput keystrokes (the TIM-728 helper) requires
mapping RA's main-menu hotkeys, which we didn't reliably crack in this
heartbeat. The patch chain happens to dump the player directly into the
attract-mode demo, which plays Allied L1, so we capture there.

To do an end-to-end interactive Allied L1 run we'd need to:

1. Dismiss the title screen with a known SendInput sequence (Return /
   Space / mouse click).
2. Navigate New Campaign → Easy → Allied via SendInput at the right
   coordinates (RA's menu is DirectDraw-rendered, so mouse clicks need
   to land on the rendered button positions).
3. Skip the briefing.
4. Let mission load and capture.

This is straightforward extension work — the TIM-728 SendInput helper
is the right mechanism — but exceeded this heartbeat's budget.

## How to run

```bash
WINE=/usr/bin/wine \
    WINEPREFIX=$HOME/.wine-tim708-w10 \
    bash scripts/wine-allied-l1.sh
```

Outputs at `e2e/tim708/allied-l1/mission-t{0,3,6,9,12,17}.png`.

## Open follow-ups

- AUTODEMO crash at 0x00534273 — investigate the null-pointer site.
- SendInput-driven interactive mission (Easy/Allied/start) — would
  produce the full t=0/5/30/60/120 timeline the acceptance criteria
  envisioned.
- `scripts/wine-ra-cnc-ddraw-diag.sh` patched in this PR to add the
  `d:=cdrom` registry write — without it the title screen never renders
  even with all binary patches applied. PR #138 (TIM-739) verified the
  patch chain in a prefix that already had this registry from prior
  manual configuration; the script was missing the line.
