# TIM-709 research: Wine RA95 mouse input under Xvfb (headless)

## Decision record (2026-05-15)

**Option 2 chosen — pivot Part B equivalence to fixture-based comparison
(TIM-710). WineExpert rehire path (Option 1) deferred indefinitely.**

Rationale, per CEO comment on TIM-709:

* Part A (cinematic, 8/8 VQAs pixel-exact, PRs #113/#114) already proves the
  engine's frame-decode fidelity at the pixel level — the strongest
  equivalence signal we have.
* A Wine `dlls/dinput/mouse.c` patch is 1–2 weeks of Wine source work for a
  testing-only capability; ROI does not justify a WineExpert rehire at this
  stage.
* Fixture-based comparison is cleaner for CI: no Wine, no Xvfb, just
  WASM-rendered frames vs reference captures. More stable, easier to
  diagnose regressions.

Acceptance criteria as originally written (Wine clicks working under Xvfb)
are not achievable without a Wine source patch — TIM-709 is closed as
won't-fix-via-Wine. The research artifacts here remain valuable as
documentation of the dead-end, and the `-CDC:\redalert\` workaround in
`scripts/wine-ra-setup.sh` is kept for any future Wine OG debugging.

Note: the board posted approval of Option 1 ("I approve the rehiring of an
opus wine expert") ~19 min before the CEO's Option 2 decision. The CEO's
comment explicitly weighed the WineExpert option and declined it on ROI
grounds, so the CEO decision stands as the operative directive. If the
board wishes to re-open and re-direct, this section can be amended.

Follow-up issue: **TIM-710 — Part B equivalence (fixture-based)**.

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

## Wayland / sway research (board note, 2026-05-15)

The board followed up: "research if a wayland / swaywm approach would work
here instead". The hypothesis: maybe Wine's dinput filter only drops *XTest*
synthetic events, and routing through a Wayland compositor + Xwayland would
launder events into "real" master-pointer input that Wine accepts.

**Result: this path also fails under the headless toolchains available in
Debian 13.** Details below; if the board wants to push further, the deeper
follow-up is sway + libinput + uinput, estimated 0.5–1 day of debugging
with no guarantee.

### Stack tested

* `weston 14.0.2` (headless backend) via `xwfb-run` (default)
* `cage 0.2.0` (wlroots-based kiosk compositor, `WLR_BACKENDS=headless`)
  via `xwfb-run -c cage`
* `Xwayland` on top of each compositor
* Synthetic input: `xdotool` (XTest), `wlrctl 0.2.2` (wl_virtual_pointer_v1),
  `ydotool 1.0.4` (uinput via `/dev/uinput`)

### Findings

| Config | Cursor moves | X ButtonPress observed (xev) | Wine WM_MOUSEMOVE | Wine WM_LBUTTONDOWN | Dialog dismisses |
|--------|:-:|:-:|:-:|:-:|:-:|
| Xvfb + xdotool (baseline) | ✓ | ✓ (XTest) | ✓ | ✗ (dinput drops by XISourceID) | ✗ |
| `xwfb-run` (weston) + xdotool | ✓ | ✓ (`synthetic NO`) | ✓ | ✗ | ✗ |
| `xwfb-run -c cage` + xdotool | ✓ | ✓ (XTest, via XTEST slave) | ✓ | ✗ | ✗ |
| `xwfb-run -c cage` + wlrctl pointer move | ✓ | n/a | ✓ | n/a | ✗ |
| `xwfb-run -c cage` + wlrctl pointer click | n/a | **✗ (zero events)** | n/a | **✗** | ✗ |
| ydotool / `/dev/uinput` | n/a (headless compositor has no libinput backend) | – | – | – | ✗ |

The most surprising negative result is the `cage + wlrctl` row: `wlrctl
pointer move` correctly delivers `MotionNotify` to X clients and Wine emits
`WM_MOUSEMOVE`, but `wlrctl pointer click` produces **zero** `ButtonPress`
events at the X layer. Reproducible via `bash /tmp/cage-wlrctl-xev.sh`
(committed as commit reference only — not in tree).

The `xwayland-pointer:6` floating-slave device DOES appear in `xinput list`
under cage, confirming the wlr_virtual_pointer_v1 protocol is wired up.
But the button-frame path is broken — likely a wlrctl ↔ cage ↔ Xwayland
bridge bug specific to virtual-pointer buttons. wlrctl's motion frame
flushes through; the button frame doesn't.

### Why ydotool / `/dev/uinput` doesn't work here

`ydotool` writes synthetic events to the kernel's `/dev/uinput`, which
creates a virtual evdev device that real Wayland compositors read via
`libinput`. Under `WLR_BACKENDS=headless`, cage/wlroots does NOT initialize
the libinput backend — the virtual evdev device exists in `/dev/input/`
but is invisible to the headless compositor. Setting
`WLR_BACKENDS=headless,libinput` is documented but not tested here.

### What this means for TIM-709

The simple Wayland substitution (replace Xvfb with `xwfb-run`) does **not**
solve the click-injection problem — Wine still drops XTest clicks, and the
Wayland virtual-pointer protocol has its own broken-button path. To actually
unblock headless Wine gameplay tests on Linux, one of these is still
required:

* Patch Wine's `dlls/dinput/mouse.c` to accept XTest source IDs in
  `DISCL_EXCLUSIVE` polling (Option 1 from the original decision).
* Run a *real* X server (Xorg with the dummy display driver and an evdev
  input driver) backed by ydotool/uinput synthetic devices. This was not
  tried in this round.
* Build out `WLR_BACKENDS=headless,libinput` + ydotool + sway custom-bind
  the libinput device. Possible but undocumented.

Given that the fixture-based approach (TIM-710, already merged in PR #115)
achieves equivalence without any of this, the operating recommendation is
unchanged: TIM-709 stays closed as won't-fix. If the board still wants to
prosecute the Wayland angle, the next concrete experiment to run is
"sway-headless + ydotool with libinput-via-uinput-passthrough", which
needs ~0.5–1 day of bring-up.

Screenshots committed: `wayland-weston-no-click.png` (Xwayland default —
dialog after xdotool click, unchanged) and `wayland-cage-{before,after}-sweep.png`
(cage + wlrctl click sweep across the dialog — dialog unchanged across all
50 attempted click positions).

## Asset audit (board note, 2026-05-15)

The board flagged: "the /cncremastered assets may be slightly different than
what the original binary expects. better to get original assets."

Verification:

| File | Source A: `/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/` | Source B: archive.org `redalert_allied.iso` | Identical? |
|------|----------------------------------------------------------|-----------------------------------------------|-----------:|
| `MAIN.MIX`     | 454,605,294 bytes  sha1=`99104379472bbcfb70c7e378de18d5aa86918bd4` | same | ✓ |
| `REDALERT.MIX` (INSTALL/) | 25,046,328 bytes  sha1=`0e58f4b54f44f6cd29fecf8cf379d33cf2d4caef` | same | ✓ |

The two main game-data MIXes are bit-identical between the Remastered
Collection's CD1 dir and the original 1996 Allied CD ISO. The Remastered
overlay we use is the original 1996 file set unmodified.

Extras present in `/CnCRemastered/CD1/` but NOT on the original Allied CD:
`EXPAND.MIX`, `EXPAND2.MIX` (Counterstrike/Aftermath expansion content),
`HIRES1.MIX`, `LORES1.MIX` (later-patch high/low-res asset deltas), and
`REDALERT.INI` (config file the installer would normally generate). Their
presence is what causes RA95.EXE to skip the "Please insert CD" dialog and
boot straight to the main menu — the original game's installer copied
analogous content to the install directory.

Mouse-input behaviour with a pure-original stage
(`MAIN.MIX + REDALERT.MIX + REDALERT.INI + RA95.EXE` from the Allied ISO,
no Remastered overlays):

* Wine boots, shows the "Please insert a Red Alert CD" dialog (640×480
  Red Alert window, screenshot indistinguishable from prior runs).
* `xdotool mousemove 505 270` → cursor visibly moves to Cancel button.
* `xdotool click 1` → no effect, dialog stays.

Same input-layer failure as in the 9 configurations table above. **Asset
choice is not the variable** — Wine DirectInput drops the synthetic click
identically with original or Remastered MIXes. The three CEO decision
options stand.
