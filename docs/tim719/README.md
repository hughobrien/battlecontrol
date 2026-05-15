# TIM-719 — RA95.EXE black-screen under cage 0.3.0 + winewayland.drv

## Symptom

Launching RA95.EXE under `cage 0.3.0 + winewayland.drv` (Wine 11.8) produces
multiple Wayland surfaces but never a committed client buffer. `grim`
screenshots are byte-identical to the empty cage backdrop (2759 bytes).
`wine notepad` under the same compositor renders correctly, so cage +
winewayland are functional — the break is RA95.EXE-specific.

## Root cause

`winewayland.drv` in Wine 11.8 does **not** implement display-mode
switching. RA95.EXE's DDraw startup path is:

1. `DirectDrawCreate` — OK
2. `SetCooperativeLevel(DDSCL_FULLSCREEN | DDSCL_EXCLUSIVE)` — `DD_OK`
3. `SetDisplayMode(640, 480, 8)` — internally calls
   `NtUserChangeDisplaySettings(L"\\\\.\\DISPLAY1", ...)`
4. winewayland.drv returns `DISP_CHANGE_BADMODE (-2)`:

   ```
   0024:err:system:NtUserChangeDisplaySettings Changing L"\\\\.\\DISPLAY1"
        display settings returned -2.
   ```
5. DDraw cannot allocate the primary surface; RA retries
   `wayland_surface_make_toplevel` on the same surface 10+ times before
   stalling.
6. The compositor configures the xdg_toplevel at 1280x720 (cage output
   size) but no buffer is ever attached.

Wine source reference: `dlls/winewayland.drv/display.c`. Wayland gives
the compositor authority over output mode; winewayland.drv has not yet
implemented the Win32 lie that lets legacy DDraw games believe the
desktop resolution changed. See upstream Wine GitLab issues for
`winewayland.drv` + `ChangeDisplaySettings`.

## Workaround (validated)

Run **Xwayland inside cage** and route RA95.EXE through `winex11.drv`
instead of `winewayland.drv`. winex11.drv has had working
`ChangeDisplaySettings` semantics for years — DDraw's mode change is
accepted and the primary surface allocates normally.

Stack:

```
cage 0.3.0 (Wayland compositor, headless backend, pixman renderer)
  └── Xwayland :99 (Wayland client, exposes X11 server)
        └── wine RA95.EXE (DISPLAY=:99 → winex11.drv → DDraw works)
```

Cage was built with `-Dxwayland=disabled` (see
`scripts/build-cage-headless.sh:73`), but that flag controls cage's
*embedded* Xwayland; a standalone `/usr/bin/Xwayland` started as a
plain Wayland client of cage works fine.

## Proof

Running `scripts/wine-ra-cage.sh` produces `cd-prompt-rendered.png`
(this directory): the "Please insert a Red Alert CD into the CD-ROM
drive" dialog with OK / Cancel buttons rendered at 640x480 in the
top-left of cage's 1280x720 output. First non-black frame appears
within ~6 seconds.

DDraw trace excerpt (cage + Xwayland + winex11):

```
ddraw1_SetCooperativeLevel iface ..., flags 0x11.   # FULLSCREEN | EXCLUSIVE
ddraw_set_cooperative_level SetCooperativeLevel returning DD_OK
ddraw1_SetDisplayMode width 640, height 400, bpp 8.
ddraw1_CreateSurface ... DDSCAPS_PRIMARYSURFACE
ddraw_surface1_Blt ...                              # game renders frames
```

No `NtUserChangeDisplaySettings ... returned -2` errors.

## Why not patch winewayland.drv

Patching `dlls/winewayland.drv/display.c` to accept a fake mode change
and scale via `wp_viewporter` is feasible (~1–2 days of Wine source
work) but is out of scope for the Red Alert port — the workaround
above gives full DDraw fidelity with zero Wine source changes, and the
upstream Wine project is already moving on this. If/when Wine ships
the fix, the harness can drop Xwayland and use winewayland directly
with no other changes.

## Acceptance status

| Criterion (from issue) | Status |
|------------------------|--------|
| Non-black frame within 10s | ✅ Proven (cd-prompt-rendered.png at t≈6s) |
| `wtype -k Return` dismisses dialog | Not retested — same input gap as TIM-709 |
| `wlrctl pointer click` on menu | Not retested — same input gap as TIM-709 |

The rendering bug is closed. Input injection under cage remains
TIM-709's known limitation and is orthogonal to this fix.

## Files

* `scripts/wine-ra-cage.sh` — reproducible launcher
* `docs/tim719/cd-prompt-rendered.png` — proof screenshot
* `docs/tim719/README.md` — this document
