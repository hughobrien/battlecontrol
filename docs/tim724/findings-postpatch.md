# TIM-724 — After TIM-743 patches: SetDisplayMode failure is the next wall

## What changed since `findings-substrate.md`

TIM-743 landed `td-focus-skip`, `td-game-in-focus`, `td-vqa-skip`, and
`td-activateapp` binary patches plus an updated `scripts/wine-gdi-m1.sh`
that applies them automatically and switches `WINEDLLOVERRIDES` to
`ddraw=b` (Wine builtin).

With the patch chain applied:

* Window appears in 3 s (was 13 s before).
* Capture is 5,005 B / 471 unique colors (was 3,820 B / 2 colors).
* TD reaches DDraw init (`+ddraw` trace shows `ddraw1_SetDisplayMode 640x400 bpp=8`
  and `ddraw7_SetDisplayMode 640x480 bpp=8`).

## What still blocks GDI Mission 1

`NtUserChangeDisplaySettings` returns `-2` (`DISP_CHANGE_FAILED`) — Xvfb
refuses to change display mode. TD treats `SetDisplayMode != DD_OK` as
fatal, calls `MessageBoxA` to show a small modal warning, and on dismiss
calls `Prog_End` and exits.

The post-dismiss state:

* All open windows close (`xdotool search --onlyvisible --name .`
  returns nothing).
* Xvfb continues running with just the cursor on a black background
  for the remainder of the timeout — TD is gone.

This is the same failure mode TIM-727 fixed for RA in `scripts/ddscl-patch.py`:

* `SetCooperativeLevel(DDSCL_EXCLUSIVE|FULLSCREEN)` → patched to `DDSCL_NORMAL`
* `SetDisplayMode` call → patched to `xor eax,eax; nop` (fake `DD_OK`)

## What's needed

A `scripts/td-ddmode-patch.py` analogous to RA's `ddscl-patch.py`. The
work is bounded — identify the `Set_Video_Mode` (or equivalent) function
in `C&C95.EXE`, find the `SetDisplayMode` call after the
`SetCooperativeLevel` call, and stub it.

## What I tried before filing this

* **`wine explorer /desktop=td,640x400 'C&C95.EXE'`** — Wine's virtual
  desktop accepts SetDisplayMode silently. But the TD process did not
  create a visible child window inside it (capture is the explorer
  desktop background, blue/solid, with cursor). Likely TD looks for
  a top-level X window in a specific way that doesn't reach the
  embedded explorer desktop, or fails very early.
* **Double / triple Return keystrokes after the warning** — only the
  first dismisses; after that, no windows are alive (TD has exited).

## Evidence

| File | Description |
|------|-------------|
| `td-warning-dialog-after-patches.png` | t05 — the SetDisplayMode-failed warning. Small 98x82 dialog over the 640x400 cnc-ddraw white window. |
| `td-after-dismiss-blank.png` | t53 — 50 s after the dismiss. Black + cursor only. TD has exited; Xvfb has nothing to draw. |

## Recommendation

Block TIM-724 on a new TD-specific DDraw stub patch
(analogous to TIM-727 / `ddscl-patch.py` for RA). When that lands,
`wine-gdi-m1.sh` should be sufficient — the substrate is otherwise
in place.
