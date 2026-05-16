# TIM-747 — td-ddmode-patch findings

## Acceptance 1 (script applies cleanly) ✅

```
$ python3 scripts/td-ddmode-patch.py /tmp/td-test.exe
  Patched 0xbc6c3: 0x57 -> 0x90  [NOP push %edi (bpp arg to SetDisplayMode)]
  Patched 0xbc6c8: 0x51 -> 0x90  [NOP push %ecx (height arg to SetDisplayMode)]
  Patched 0xbc6ce: 0x56 -> 0x90  [NOP push %esi (width arg to SetDisplayMode)]
  Patched 0xbc6d1: 0x50 -> 0x90  [NOP push %eax (this/IDirectDraw* arg)]
  Patched 0xbc6d2: 0xff -> 0x31  [SetDisplayMode call -> xor eax,eax (fake DD_OK)]
  Patched 0xbc6d3: 0x53 -> 0xc0  [SetDisplayMode call -> xor eax,eax (cont)]
  Patched 0xbc6d4: 0x54 -> 0x90  [SetDisplayMode call -> nop]
/tmp/td-test.exe: patched OK (46dc1eb4a8114361…)
```

Input SHA `46a6d902…` (post-TIM-743-chain) → output SHA `46dc1eb4…`. Both
match the script's documented hashes.

## Acceptance 2 / 3 (TD content ≥30 s) ❌

Triggers the explicit hand-back clause in the routing comment:
> Hand back if … the patch produces a black post-dismiss screen
> (likely indicates a deeper init seam beyond this PR's scope).

### What was tried

Six combinations of {Wine 10.0, Wine 11.8} × {cnc-ddraw, Wine builtin ddraw}
× {td-ddmode-patch, plain run} were exercised through `scripts/wine-gdi-m1.sh`
variants. None reach TD content within 60 s:

| Wine   | ddraw         | ddmode | setcoop-hwnd | virt-desk | Result at t30                           |
|--------|---------------|--------|--------------|-----------|-----------------------------------------|
| 11.8   | cnc-ddraw (n) | no     | yes          | no        | White client (4538 B, 63 colors)         |
| 11.8   | builtin (b)   | yes    | yes          | no        | Wine "Application Error" dialog          |
| 11.8   | builtin (b)   | yes    | yes          | tim724    | Black client + cursor (6384 B, 669 col.) |
| 10.0   | builtin (b)   | yes    | yes          | tim724    | Uniform blue client (7559 B, 712 col.)   |
| 10.0   | builtin (b)   | no     | yes          | tim724    | Uniform blue client (same)               |
| 10.0   | builtin (b)   | yes    | yes          | tim724    | In-Wine BitBlt = same blue: 617 colors   |

The last row used `tools/wine-input/td-screenshot.c` (BitBlt inside the Wine
prefix). The BitBlt mirrors what ffmpeg x11grab sees — uniform blue. There is
no hidden game frame in wined3d's CPU mirror; TD is not rendering.

### Diagnostic signals

* `WINEDEBUG=+ddraw` confirms the patch chain reaches `SetCooperativeLevel
  (window 00020070, flags 0x8) → DD_OK` and `CreateSurface(DDSCAPS_PRIMARYSURFACE)`.
* Without `explorer /desktop`, Wine's primary surface comes out 1024×768×32
  (desktop format) instead of TD's expected 640×400×8 — the stub means Wine
  was never told what mode to use, so the binary's render code writes into
  the wrong format and the Wine fault handler shows an Application Error
  dialog before t30.
* With `explorer /desktop=tim724,640x400`, no crash, but the surface is
  never blitted into. TD is reaching DDraw init but stopping somewhere
  between `CreateSurface(PRIMARY)` and the first `Flip` / `Blt(BLT_COLORFILL)`
  call. `WINEDEBUG=+ddraw` shows no `ddraw_surface_blt` / `ddraw_surface_flip`
  in the 30-second window.
* `+file` traces show TD reaching D:\ and MIX files are visible there.
  Get_CD_Index / Set_Search_Drives is presumably succeeding (.windows-label
  = GDI95 is set on D:).

### Hypothesis

The block is downstream of CreateSurface(PRIMARY) and upstream of the first
Flip. Likely candidates (none verified in this heartbeat):

1. Init_Bulk_Data palette load — TEMPERAT.PAL is extracted, but maybe TD
   needs a different PAL (PALETTE.PAL?) before menu render.
2. A second `SetDisplayMode` on a different DDraw interface — the call at
   0xbc6d2 is the one inside the TIM-723-chain DDraw init helper, but TD
   may call SetDisplayMode again from its menu code via a fresh DD7
   interface (`call [edx+0x54]` at the other enumerated candidate offsets
   listed in TIM-747).
3. Some other GameInFocus / message-loop variant that doesn't run because
   the virtual desktop changes the focus/activate sequence.

### Recommended next steps (for follow-up issue)

* Add `+ddraw,+message,+win` and trace for the first 30 s to find where TD
  is actually spinning.
* Compare against `wine-allied-l1.sh` for RA, which has the same patch
  family running successfully — the missing seam for TD is probably one
  of the patches RA needed that TD does not yet have.
* Consider scoping a `td-ddraw-call-survey` task: instrument each of the
  enumerated SetDisplayMode candidate sites (see TIM-747 description) and
  log which one TD actually executes through.

## Files

* `scripts/td-ddmode-patch.py` — TIM-747 deliverable (acceptance 1).
* `scripts/td-setcoop-hwnd-patch.py` — companion: rewrites SetCooperativeLevel
  to pass the real HWND from global `0x567848`. Required to keep Wine builtin
  ddraw from creating a head-less primary surface.
* `scripts/td-cdlabel-patch.py` — alternative `Get_CD_Index` fix that
  zeroes `"GDI95"[0]`. Not used in `wine-gdi-m1.sh` because it makes
  Get_CD_Index match C: first; the `.windows-label` mechanism is used
  instead. Kept in-tree as a reference/fallback.
* `tools/wine-input/td-screenshot.c` — in-Wine BitBlt screenshot helper.
* `scripts/wine-gdi-m1.sh` — re-wired for Wine builtin ddraw + virtual
  desktop. Currently exercises the patch chain but does not yet produce
  TD content (deeper init seam open).
