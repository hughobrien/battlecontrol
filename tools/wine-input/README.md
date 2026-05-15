# wine-input — SendInput-based input injection for Wine RA/TD harness

## Why this exists

Wine's `dinput.dll` populates the DirectInput keyboard-state array via a
`WH_KEYBOARD_LL` low-level hook. RA95.EXE (and CC95.EXE) read input by
polling that DInput state — they do **not** use the Win32 message queue
for menus, dialogs, or in-game commands.

Synthetic X events (`xdotool`, `XTestFakeKeyEvent`) generate `WM_CHAR`
and `WM_KEYDOWN` via Wine's `x11drv`, but they do **not** trigger
`WH_KEYBOARD_LL` hooks — so DInput never sees the press, and RA never
reacts. This is the input gap documented in TIM-709.

`SendInput` from inside the Wine process tree dispatches via Wine's
own input pipeline (`win32u/input.c → __wine_send_hardware_message`),
which **does** fire LL hooks. DInput sees the press, RA reacts.

## Build

```bash
i686-w64-mingw32-gcc -o ra-sendinput.exe ra-sendinput.c -luser32
```

## Use

Inside the same Wine prefix as the running game:

```bash
WINEPREFIX=~/.wine-ra-wayland \
  /opt/wine-devel/bin/wine ra-sendinput.exe 0x0D 0   # VK_RETURN, no delay
```

Common VKs:

| Hex   | Key       | Notes                              |
|-------|-----------|------------------------------------|
| 0x0D  | VK_RETURN | OK / confirm                       |
| 0x1B  | VK_ESCAPE | Cancel / skip intro                |
| 0x20  | VK_SPACE  | Continue / activate focused button |
| 0x28  | VK_DOWN   | Menu navigation                    |
| 0x26  | VK_UP     | Menu navigation                    |
| 0x4E  | 'N'       | RA: New Campaign hotkey            |

## Proof (TIM-728, 2026-05-15)

Under cage + Xwayland + winex11 + RA95.EXE (NoCD-patched only):

- t=5s screenshot: `e2e/tim728/evidence/01-cd-prompt.png` — "Please insert
  a Red Alert CD" dialog (13679 bytes), OK | Cancel.
- After `SendInput(0x1B)`: `e2e/tim728/evidence/02-after-esc.png` —
  advanced to "Red Alert is unable to detect your CD ROM drive" (13387
  bytes), OK only.
- After `SendInput(0x0D)`: game exits cleanly (2759 bytes, empty
  backdrop).

For the same sequence, `xdotool key Return` / `xdotool key --window
<RA_WIN> Return` / `wlrctl keyboard type` / hold-and-release variants
all produced **zero state change** (13679-byte CD prompt unchanged
across all attempts).

## Limits / follow-ups

- Mouse events are not yet implemented in this helper. A
  `INPUT_MOUSE`-based variant would inject DInput-visible clicks.
- Cage's exclusive-mode capture is still a problem after the menu
  loads — see e2e/tim728/notes.md.
