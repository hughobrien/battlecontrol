# TIM-708 — Wine OG Allied L1 capture: findings + remaining gap

## Goal

Drive RA95.EXE under headless Wine through Allied Mission 1, capture timed
screenshots, compare against the WASM port (TIM-712 spec).

## What landed

- `tools/wine-input/ra-sendinput.c` extended with mouse + sequenced ops
  (keyboard-only was insufficient — the menu navigation needs `click` and
  `seq`).
- `tools/wine-input/ra-screenshot.c` (new) — Win32 GDI BitBlt screenshot helper
  intended for in-Wine capture. Verified it builds and runs but produces black
  frames against wined3d-backed DDraw surfaces (see Finding 4 below).
- `scripts/wine-ra-xvfb-allied-l1.sh` (new) — Xvfb + openbox + winex11 capture
  pipeline using SendInput. Reaches the boot dialog correctly with
  `renderer=gdi`, then RA aborts because gdi can't allocate the primary buffer.

## Findings

### 1. Default Wine 11.x DDraw is invisible to X11 capture

With no `Direct3D\renderer` override, Wine routes DDraw through wined3d/GL.
The X11 window backing store stays empty regardless of:

- `WINEDEBUG=+ddraw` shows `surface_lock`, `update_frontbuffer`, and
  `X11DRV_client_surface_present 0x20062/0x5d400960 offscreen 0` calls,
  yet `ffmpeg x11grab`, `xwd -root`, and `import -window root` all return
  pure black (1 colour, 307200 pixels black).
- `xcompmgr -a` (composite extension on) — no change.
- `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` — no change.
- Even `PrintWindow` / `BitBlt` *from inside Wine* against the
  `Red Alert` HWND returns a black bitmap — wined3d does not keep a
  CPU-readable mirror of the primary surface.

### 2. `renderer=gdi` makes Win32 GDI visible but aborts DDraw init

With `HKCU\Software\Wine\Direct3D renderer = gdi`:

- The Win32 GDI MessageBox at boot **is** captured by `ffmpeg x11grab`
  — `boot.png` shows the dialog clearly: *"Error - Unable to allocate
  primary video buffer - aborting."*
- After pressing OK the game exits — gdi mode disables wined3d, which
  RA needs to allocate the DDraw primary surface.

### 3. `renderer=no3d` behaves the same

Same dialog (`Error - Unable to allocate primary video buffer`) with the
same fatal-exit-on-OK behaviour.

### 4. cnc-ddraw produces a capturable window but RA does not draw

Tested cnc-ddraw 7.5.0 (latest as of 2026-05-15) as a DLL drop-in:

- `tools/wine-input/cnc-ddraw/ddraw.dll` + `ddraw.ini` staged next to RA95.EXE
- `WINEDLLOVERRIDES="ddraw=n"` to force the native ddraw
- Wine load trace confirms `Loaded L"Z:\\tmp\\…\\DDRAW.dll" at 79660000: native`

Result: a 640×400 cnc-ddraw window appears at the screen centre and is
fully captured by `ffmpeg x11grab` — **but** the window contents stay
pure white (167 747 white + 88 050 black pixels, identical at t=5/10/15/20/25s).
SendInput keys/clicks fire but produce no state change.

Tried on three EXE variants with no behavioural change:

| EXE                             | Patches applied                                  | Result |
|---------------------------------|--------------------------------------------------|--------|
| `/opt/redalert/RA95.EXE`        | NoCD + DDSCL_NORMAL (TIM-720 + TIM-727)          | white  |
| `RA95.EXE.ddscl_orig`           | NoCD only                                        | white  |
| `/opt/redalert/game/RA95.EXE`   | NoCD + sdm-skip + probe-skip + focus-skip        | white  |

Including the `focus-skip-patch.py` (NOPs the three `while (!GameInFocus)`
spin loops at 0x154005, 0x15f2f1, 0x15f583) — also no change.

So RA is stuck **before** entering its DDraw render loop. cnc-ddraw is
working; the game just never calls it. Likely candidates:

- DirectSound init waiting for a device that `AUDIODEV=null` won't
  satisfy.
- THIPX32/16 IPX networking init handshake (these DLLs are present in
  staging, but they may need wineserver registry keys we are not
  setting).
- The `probe-skip` / `sdm-skip` predecessor patches in `/opt/redalert/game`
  are unknown and may collide with cnc-ddraw's expectations.
- Some Wine-side prefix setting (Wine 11.8 differs from the Wine 10 that
  TIM-727 was verified against).

## Captures in this directory

`e2e/tim708/captures/` holds the last `scripts/wine-ra-xvfb-allied-l1.sh`
run output. The boot dialog *is* captured (`wine-allied-l1-boot.png`,
6940 bytes — *"Unable to allocate primary video buffer"* from the
`renderer=gdi` attempt). All later captures are 1301-byte blank PNGs
because RA exited after the OK press.

## Recommended next step

Open a child issue: **TIM-708 follow-up — cnc-ddraw integration deep-dive
for headless RA95.EXE capture.** Scope:

1. Strip patches back to NoCD-only + focus-skip; verify each predecessor
   patch independently with cnc-ddraw (sdm-skip, probe-skip can probably
   be removed entirely because cnc-ddraw handles display mode internally).
2. Enable cnc-ddraw `debug=true` and inspect `ddraw.log` for "Surface
   created" / "Blt" calls — confirm RA actually reaches a DDraw flush.
3. Add `WINEDEBUG=+winmm,+dsound,+module` and trace RA's startup until
   the first DDraw call to find where it gets stuck.
4. If the stall is in `THIPX32` networking init, add
   `WINEDLLOVERRIDES="thipx32.dll=" wineserver` registry stubs.

Once a non-white cnc-ddraw frame is captured, the rest of the pipeline
(SendInput menu nav, timed captures, WASM comparison) is already wired
and ready to run.

## Test commands for next agent

```bash
# Reproduce the cnc-ddraw white-window state:
mkdir -p /tmp/diag
ln -sf /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/*.MIX /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/*.INI /tmp/diag/
cp /opt/redalert/game/RA95.EXE /tmp/diag/RA95.EXE
cp /tmp/cnc-ddraw/ddraw.dll /tmp/diag/ddraw.dll
cat > /tmp/diag/ddraw.ini <<EOF
[ddraw]
renderer=gdi
windowed=true
nonexclusive=true
debug=true
EOF
Xvfb :91 -screen 0 800x600x24 -ac &
DISPLAY=:91 openbox &
cd /tmp/diag
DISPLAY=:91 WINEPREFIX=~/.wine-ra-cnc WAYLAND_DISPLAY= \
    WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" AUDIODEV=null \
    WINEDEBUG=+winmm,+dsound,+module,err+all \
    /opt/wine-devel/bin/wine RA95.EXE 2>&1 | tee /tmp/wine-trace.log
```
