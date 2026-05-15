# TIM-728 evidence notes

## What landed

`tools/wine-input/ra-sendinput.c` — a 60-line Win32 helper, compiled with
`i686-w64-mingw32-gcc`, that calls `SendInput()` to inject a keypress into
the current Wine session. Unlike `xdotool` / `XTestFakeKeyEvent`, this
fires `WH_KEYBOARD_LL` hooks, which Wine's `dinput.dll` listens on. RA's
DInput polling then sees the key.

`scripts/wine-ra-cage-input.sh` — wrapper around `scripts/wine-ra-cage.sh`
(TIM-719) that also builds + invokes the helper.

## Proven behavior (cage + Xwayland + winex11, NoCD-patched RA95.EXE, no
`d:`-cdrom mapping in this evidence run so the CD dialog is reachable)

| File                         | Size  | State                                    |
|------------------------------|-------|------------------------------------------|
| `evidence/01-cd-prompt.png`  | 13679 | "Please insert a Red Alert CD" — OK \| Cancel |
| `evidence/02-after-esc.png`  | 13387 | "Red Alert is unable to detect your CD ROM drive" — OK |
| `evidence/03-after-ret.png`  | 2759  | Empty (RA exited after pressing OK on the error)  |

Same sequence with `xdotool`, `wlrctl`, hold-and-release variants, and
`--window`-targeted clicks: all produce **zero state change** (13679-byte
CD prompt unchanged). This is the TIM-709 input gap.

## What is *not* yet solved

After the CD dialogs are dismissed (or skipped via `d:`-cdrom + the
TIM-727 DDSCL_NORMAL binary patch), RA renders a Win32 MessageBox
("Warning - you are critically low on free disk space") which is
captured fine, but the subsequent main DDraw surface enters
exclusive-mode rendering that `grim` can no longer see — the cage
framebuffer reverts to the 2759-byte empty backdrop while Wine continues
to run.

This is the same exclusive-mode capture gap from the original TIM-727
diagnosis, except it now appears *after* the menu starts rather than
before. The TIM-727 binary patch (DDSCL_NORMAL) was tested under cage
and also produces the empty backdrop — so the patch is not a complete
solution under cage, only under naked Xvfb. Resolving this requires
either:

- A different Wine cooperative-level/renderer combo (e.g. the
  `EmulatedSurfaces` registry path that PlaywrightEngineer was
  experimenting with at 05:50Z under Xvfb :97)
- Patching Wine's wined3d to commit exclusive-mode surfaces to the X11
  backing window
- An X11-only path: drop cage, run plain Xvfb + openbox + winex11 with
  the DDSCL_NORMAL binary patch — this is what TIM-727's premise was
  built around, and combined with SendInput should reach the menu

Filing this as a follow-up for the parent issue, not a blocker on the
input finding.

## Wine prefix configuration

```
WINEPREFIX=~/.wine-ra-wayland
WINEARCH=win32
[HKEY_LOCAL_MACHINE\Software\Wine\Drives]
"d:"="cdrom"
~/.wine-ra-wayland/dosdevices/d: → /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1
WINEDLLOVERRIDES="mscoree=;mshtml="
```

## How to reproduce

```bash
bash scripts/wine-ra-cage-input.sh
ls e2e/screenshots/wine-ra-cage-input-*.png
```
