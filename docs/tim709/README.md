# TIM-709 research: Wine RA95 mouse input under Xvfb (headless)

## TL;DR

**Mouse motion** propagates from xdotool → Xvfb → Wine cursor in all
configurations tested. **Mouse button events** do NOT propagate to RA95.EXE's
custom GUI (the textured OK/Cancel buttons on "Please insert CD" and the main
menu items). This blocks Wine OG gameplay tests under Xvfb without a real X
session.

The bottleneck is **Wine 10.0's DirectInput in exclusive/polling mode**:
RA polls `IDirectInputDevice7::GetDeviceState` for the mouse, which reads
mouse-button state from a path that does not receive synthetic events from
either X11 (`xdotool`) or the Win32 input queue (`SendInput`/`mouse_event`).

## Configurations tested (all failed for button clicks)

| # | Approach                                              | Cursor moves | Click registers |
|---|-------------------------------------------------------|--------------|-----------------|
| 1 | `xdotool mousemove click 1`                            | ✓            | ✗               |
| 2 | `xdotool click --window <WID>` (XSendEvent)            | ✓            | ✗               |
| 3 | `xdotool mousedown 1 ; sleep ; mouseup 1`              | ✓            | ✗               |
| 4 | `xdotool click --repeat 3 --delay 100 1`               | ✓            | ✗               |
| 5 | `xdotool key Tab` + `xdotool key Return`               | (focus only) | ✗               |
| 6 | `matchbox-window-manager` + xdotool click              | ✓            | ✗               |
| 7 | Win32 `SendInput(MOVE+LEFTDOWN+LEFTUP)` via wine helper| ✓            | ✗               |
| 8 | Win32 legacy `mouse_event()` via wine helper           | ✓            | ✗               |
| 9 | `SetForegroundWindow(RA)` + `SendInput` batch          | ✓            | ✗               |

Win32 dialogs (DirectSound warning — uses a real `MessageBox`) DO accept
`xdotool key Return` because OK is a Win32 default button activated by
Enter at the message-pump layer. RA's custom GUI (which paints OK/Cancel
into its own DDRAW surface and polls DInput for clicks) does not.

## Test harness summary

* Xvfb 800×600 :9X, Wine 10.0, prefix `~/.wine-ra` with virtual desktop
  configured (`HKCU\Software\Wine\Explorer\Desktops\Default = 800x600`).
* RA95.EXE at `/opt/redalert/RA95.EXE`,
  data at `/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1` (has HIRES1.MIX /
  LORES1.MIX — required for menu render).
* Stage `RA95.EXE + THIPX*.DLL + *.MIX` into `C:\redalert` (drive_c).
* Optionally configure `D:` as CDROM (`HKLM\Software\Wine\Drives "d:"="cdrom"`)
  or pass `-CDC:\redalert\` on the command line to bypass the
  "Please insert RA CD" dialog (the dialog is RA-rendered; its buttons cannot
  be clicked under Xvfb, so the bypass is required before any input test).

## Partial workaround discovered

`RA95.EXE -CDC:\redalert\` bypasses the "Please insert CD" dialog entirely:
RA's `CCFileClass::Set_Search_Drives` override skips the CD detection that
would otherwise prompt for a disc. Verified — "Please Stand By" screen renders
~8 s in. Subsequent privileged-instruction crash at `005c1fa4` is a separate
Wine compatibility issue (likely IPX init or 16-bit fragment), not relevant
to TIM-709's input scope.

This bypass is useful but **not sufficient** for gameplay automation: once
RA reaches the main menu, navigation still requires clicks RA can't see.

## Why it fails (theory)

Wine 10.0's DirectInput mouse driver (`dlls/dinput/mouse.c`) services
`IDirectInputDevice7::GetDeviceState` by polling raw button state. In
`DISCL_EXCLUSIVE | DISCL_FOREGROUND`, the polling path reads from XInput2
raw events bound to a specific master pointer device. XTest-generated
buttons carry a different `XISourceID` and may be filtered.

For `SendInput` (Win32), wineserver posts the event to the system input
queue. Wine routes it to the foreground HWND's message queue. RA's DInput
device, however, polls *device state* (not message queue), so the click
never feeds the device state register that `GetDeviceState` reads.

This is **fundamentally a Wine dinput limitation in exclusive-mode polling
under headless X servers**.

## Next steps (not in TIM-709 scope)

* Patch Wine `dinput` to also route synthetic button events into the
  device state in `DISCL_EXCLUSIVE` mode (Wine upstream patch).
* Hook `IDirectInputDevice7` from within RA's wine prefix using a fake DLL
  that overrides `GetDeviceState` (Winelib shim).
* Switch the gameplay equivalence approach for Wine OG from
  Playwright/xdotool-driven runs to **pre-recorded keyframe replay** —
  record on a workstation with a real X server, store the resulting
  screenshots/state as fixtures, compare WASM port output against them.
  This sidesteps headless input entirely and is the recommended path
  for CI given the depth of the upstream Wine work otherwise required.

## Artifacts

* `winclick.c` — Win32 SendInput / mouse_event / foreground click injector.
  Build: `i686-w64-mingw32-gcc -mwindows -O2 -o winclick.exe winclick.c -luser32`.
  Three modes via `WC_MODE={batch,legacy,foreground}`. None succeed in
  posting a click RA's GUI observes.
* `wine-click-not-propagated.png` — Insert-CD dialog after `xdotool click`
  at OK button position; cursor on OK, click silently dropped.
