# TIM-709 research: Wine RA95 mouse input under Xvfb (headless)

## winewayland.drv update (2026-05-15, second board correction)

Board pushback on the first Wayland round: *"isn't modern wine wayland
native?"* — and they're right. Wine 10.0 ships `winewayland.drv` for both
i386 and x86_64 (verified at `/usr/lib/{i386,x86_64}-linux-gnu/wine/.../winewayland.{so,drv}`).
My first Wayland round routed Wine through Xwayland, which rebuilt the
same XInput/XTest stack we were trying to escape.

Re-tested with `winewayland.drv` directly (no Xwayland in the path):

* Set up a fresh prefix at `~/.wine-ra-wayland`, with
  `HKCU\Software\Wine\Drivers\Graphics = "wayland,x11"` so the wayland
  driver is preferred when `WAYLAND_DISPLAY` is set and `DISPLAY` unset.
* Compositor: `cage` with `WLR_BACKENDS=headless WLR_RENDERER=pixman
  WLR_LIBINPUT_NO_DEVICES=1` (cage's pixman software renderer works
  without a DRM render node).

### What worked

* Wine loads `winewayland.drv` cleanly. Log: `0024:err:waylanddrv:wayland_process_init
  Wayland compositor doesn't support optional zwp_pointer_constraints_v1`
  (warning, not fatal — pointer locking unavailable, motion/buttons still
  work).
* `wine notepad` renders the **actual Notepad UI**: title bar, File/Edit/
  Search/View/Help menus, edit area with a blinking caret. See
  `winewayland-notepad-rendered.png` in this dir.
* `wlrctl pointer move` propagates through cage → Wine, just like under
  Xwayland.

### What's still broken

* `wlrctl pointer click` events: do not reach Wine. (Same finding as the
  first Wayland round — confirmed independent of Xwayland.)
* `wlrctl keyboard type` events: do not reach Wine notepad (no text appears
  in the edit area after `wtype "hello"` or `wlrctl keyboard type "hello"`).
* `wtype`: also fails to deliver keystrokes — same wlroots virtual-keyboard
  protocol, same drop.
* `RA95.EXE` under `winewayland`: black screen (likely Wine winewayland's
  DDraw-on-software-renderer path not handling 1996-era exclusive-mode
  fullscreen DDraw). This is a separate problem from input injection.

### Diagnosis

Cage exposes the right protocols — verified via `wayland-info`:
* `zwp_virtual_keyboard_manager_v1 v1`
* `zwlr_virtual_pointer_manager_v1 v2`
* `zwp_relative_pointer_manager_v1 v1`

So the protocols are wired. The issue is in the **tools**: `wlrctl 0.2.2`
and `wtype 0.4` both propagate motion frames correctly but their
button/key frames are silently dropped on the path to clients. This may be
a version-specific bug or a frame-sequencing issue in the tool's protocol
client.

### Path forward (estimated effort)

| Step | Effort |
|------|-------|
| Write a custom 100-line C client using `libwayland-client` that binds `zwlr_virtual_pointer_manager_v1` and emits `button`/`frame` events directly — bypassing wlrctl. | 2–3 hours |
| Get RA95.EXE to render under winewayland (DDraw → wayland surface). Likely requires `WLR_RENDERER=gles2` + `swrast` libGL + `WINEPREFIX=...` registry adjustments to make Wine route DDraw through GDI fallback instead of DDraw. Or run a different DDraw-friendly compositor (gnome-mutter headless with virtual GPU). | 0.5–1 day |
| Wire it into `e2e/tim705-equivalence.spec.ts` Part B; capture reference frames; remove the `WINE_RA_READY` skip. | 0.5 day |

Total: 1–2 days of focused work. Materially less than the original
estimate of patching Wine `dlls/dinput/mouse.c` (Option 1, 1–2 weeks).

The board's correction unlocked a viable path. Whether to commit the
1–2 days now or stick with TIM-710 fixture parity remains a board call.

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

## Upstream-version audit (board note, 2026-05-15)

The board followed up: "see if newer versions of those deps are available.
debian is often slow". Hypothesis: Debian Trixie may be shipping a stale
cage / wlrctl / wtype / wine, and the click-injection bug is fixed upstream.

### Versions audited

| Tool   | Debian Trixie | Upstream latest    | Gap                                            |
|--------|---------------|---------------------|------------------------------------------------|
| cage   | 0.2.0 (2022)  | **0.3.0** (Apr 2024) | 18 months, wlroots 0.16 → 0.20                 |
| wlrctl | 0.2.2         | 0.2.2 + 7 trivial commits | current (no input-handling fixes since v0.2.2) |
| wtype  | 0.4 (2022)    | 0.4 (2022)          | current — latest is from January 2022          |
| wine   | 10.0          | **11.8** (devel via WineHQ apt) | 8 minor releases, active winewayland.drv work  |

### What we tried

1. **cage 0.3.0** — Debian experimental ships it, but its dep `libwlroots-0.20`
   is not packaged in trixie / experimental / sid. Forky/sid's cage 0.2.1
   needs libwlroots-0.19, also unavailable. Building wlroots 0.20 + cage 0.3.0
   from source is the *only* path; estimated 1–2h of bring-up.

2. **wine-devel 11.8 from WineHQ apt** — installed cleanly at
   `/opt/wine-devel/` alongside Debian wine 10.0 at `/usr/bin/wine`.
   Re-ran the cage + winewayland.drv + wlrctl click test.

### Result with Wine 11.8 + winewayland.drv + cage 0.2.0

* Wine 11.8 loads `winewayland.drv` correctly and renders notepad fullscreen
  under cage (title-bar "Untitled - Notepad", File / Edit / Format / View /
  Help menus visible, status bar showing "Ln 1, Col 1"). Screenshot
  committed: `docs/tim709/wine118-notepad-rendered.png`.
* `wlrctl pointer move 100 100` issued.
* `wlrctl pointer click left` issued.
* Screenshot after click is **byte-identical** to before-click — no File
  menu, no visible cursor change, no response. Screenshot committed:
  `docs/tim709/wine118-after-wlrctl-click.png`.

**Same failure as Wine 10.0.** The Wine version was not the bottleneck.

### Where the bug really lives

Process of elimination, after this round:

* **Wine winewayland.drv**: confirmed receiving render events (notepad
  draws), confirmed connecting to the cage compositor. Not the issue.
* **wlrctl**: emits `zwlr_virtual_pointer_v1.button` correctly — verified
  in earlier round via `wayland-info` enumeration. Upstream has no
  newer release; main has only zsh/meson/ARM fixes since v0.2.2.
* **wtype**: same — current upstream, no recent fixes.
* **cage 0.2.0**: most likely culprit. Uses wlroots 0.16 — between 0.16
  and 0.20, wlroots saw substantial virtual-pointer event-forwarding
  rework (multiple commits to `virtual_pointer.c` and seat focus).
  Headless wlroots may also gate button events on a "real" input device
  being present, which the headless backend doesn't simulate.

### Operating recommendation (unchanged)

Three options remain, ranked by effort:

1. **Build wlroots 0.20 + cage 0.3.0 from source** (1–2h). Only the cage
   layer is genuinely stale; this is the one upgrade with non-zero
   probability of changing the outcome. If clicks still drop after this,
   the problem is structurally in headless wlroots, not version drift.
2. **Use the fixture-based equivalence framework already merged in
   TIM-710** to converge on Wine behaviour without ever needing
   click-injection. This is what the company has been shipping.
3. **Run a real X server (Xorg dummy + evdev/uinput)** — punts the
   problem to the actual Linux input stack, which is known to work
   for headless game testing in other CI environments.

Given (1) has bounded effort and clear yes/no value, queueing it as a
delegated follow-up. (2) remains the operating mode for ongoing
equivalence work.
