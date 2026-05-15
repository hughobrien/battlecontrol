# TIM-724 — TD substrate findings

## What works (Wine 11.8 + cnc-ddraw + Xvfb + openbox)

* `scripts/wine-gdi-m1.sh` ports the TIM-708 RA substrate (cnc-ddraw drop-in,
  Xvfb + openbox window manager, `d:=cdrom` registry, CRLF CONQUER.INI) to TD.
* TD loads C&C95.EXE successfully (binary mapped, THIPX32.DLL imports
  resolved).
* cnc-ddraw creates a "Command & Conquer" titled window ~13 s after launch.
* TD opens the always-loaded MIX files in the expected order:
  CONQUER.INI → CCLOCAL.MIX → UPDATE.MIX → UPDATEC.MIX.
* Wine's `.windows-label = "GDI95"` mechanism works — verified independently
  with a tiny `GetVolumeInformationA` test exe (returns `ok=1
  volume_name='GDI95'`).
* d:\ is reported as DRIVE_CDROM (5) via `GetDriveTypeW`.

## What blocks gameplay

TD does **not** progress past UPDATEC.MIX. The cnc-ddraw window is created
but stays white — no `DirectDraw` / `CreateSurface` / `SetCooperativeLevel`
calls in `WINEDEBUG=+ddraw` trace over 18 s. TD is stuck **before** the
DDraw init, and therefore before the CD check at `Get_CD_Index`
(`SOURCECODE/TIBERIANDAWN/CONQUER.CPP:3620`).

The blocker is somewhere between `CreateWindow` (which fires — window
appears) and `Init_Video` / DDraw cooperative-level setup. Likely
candidates, by analogy with the RA failure modes that TIM-708 patched
out:

* **Three GameInFocus polling loops** (RA had three; TD's `Focus_Loss`,
  `Focus_Restore`, and main-loop polling probably mirror this).
* **Mouse driver check** — TD binary contains the string
  "Command & Conquer is unable to detect your mouse driver." which
  suggests an explicit detect-and-abort path that may not exit cleanly
  on Wine.
* **Pre-DDraw audio init** that blocks on absent device even with
  `AUDIODEV=null`.

## What's still required for gameplay

TD-specific binary patches mirroring the TIM-708 set for RA, but at
**different byte offsets** because the binary is different:

| RA patch (TIM-708)          | TD analogue needed?     | Notes |
|-----------------------------|-------------------------|-------|
| `focus-skip-patch.py`       | yes                     | NOP TD's GameInFocus spin-loops. |
| `game-in-focus-patch.py`    | yes                     | Entry-detour to pin TD's GameInFocus = TRUE. |
| `cdlabel-patch.py`          | **no — substitute**     | `.windows-label = "GDI95"` already satisfies TD's `Get_CD_Index`. |
| `vqa-skip-patch.py`         | yes                     | TD has intro VQAs (`%c:\movies.mix` → `TRAILER.VQA` etc.). |
| `nocd-patch.py`             | maybe                   | TD's `GetDriveType` check is the same idiom; `d:=cdrom` may already satisfy it. |

Identifying TD's patch sites is the same kind of work TIM-708 did for
RA: pick an addressable failure mode, find the call site with strings /
disassembly / signature search, NOP or detour. This is a substantive
piece of reverse-engineering that should be its own issue.

## What the substrate script does and does not do

`scripts/wine-gdi-m1.sh`:

* Stages MIX/INI symlinks, the TD binary, THIPX32.DLL, cnc-ddraw, and
  `.windows-label = "GDI95"` into a temporary `d:\` mount.
* Starts Xvfb 800x600x24 + openbox + cnc-ddraw + Wine 11.8.
* Launches C&C95.EXE and waits for a window.
* Captures `t05-initial`, `t10-after-dismiss`, `t15-menu-or-intro`,
  `t20`, `t30`, `t60` screenshots via `ffmpeg x11grab`.

It does **not**:

* Apply any binary patches (none exist for TD yet).
* Navigate menus (TD never reaches the menu in current state).
* Capture GDI Mission 1 frames (gated on patches above).

## Evidence

* `e2e/tim724/gdi-m1/t05-initial.png` through `t60.png` — six byte-identical
  3,820 B PNGs of a white cnc-ddraw window on black Xvfb root.
* `wine.log` (suppressed; re-run with `WINEDEBUG=+ddraw,+gdi` confirms no
  DDraw activity).
* Source reference: `Get_CD_Index` in
  `/CnCRemastered/SOURCECODE/TIBERIANDAWN/CONQUER.CPP:3620-3700`.

## Next agent

* File the TD patch identification as a child issue. The work is bounded
  but non-trivial — it is the same kind of binary RE that took TIM-708
  several heartbeats for RA, applied to a smaller, simpler binary.
* When patches land, `scripts/wine-gdi-m1.sh` may be sufficient as-is
  (the patch chain is applied before staging the binary, identical
  pattern to `scripts/wine-allied-l1.sh`).
