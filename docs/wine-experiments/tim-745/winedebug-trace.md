# TIM-745 — WINEDEBUG=+message,+focus trace excerpt

## Setup

- Wine: wine-11.8 (wine-devel)
- Compositor: cage 0.3.0 (WLR_BACKENDS=headless)
- X server: Xwayland :99 -geometry 640x480 (software, glamor disabled)
- Driver: winex11.drv (no cnc-ddraw)
- Binary: /opt/redalert/RA95.EXE (sha256 c9e9be01...) — TIM-727 DDSCL/SetDisplayMode patches present,
  NO game-in-focus-patch.py applied. Entry-point at 0x1AD8CA is original (`c7 05 4c 79 6d 00 b0 94 55 00 e9 af 85 00 00`).
- WINEDLLOVERRIDES="mscoree=;mshtml="
- WINEDEBUG=+message,+focus,fixme-all

## Result: WM_ACTIVATEAPP IS delivered to Red Alert window

RA's main window is created at hwnd 0x20062 (class "R", title "Red Alert"):

```
0024:trace:message:spy_enter_message (0x20062) L"{Red Alert}"   [0081] WM_NCCREATE sent from self wp=00000000 lp=0021f8f0
0024:trace:message:spy_enter_message (0x20062) L"Red Alert"     [001c] WM_ACTIVATEAPP sent from self wp=00000001 lp=00000000
0024:trace:message:spy_enter_message (0x20062) L"Red Alert"     [0086] WM_NCACTIVATE sent from self wp=00000001 lp=00000000
0024:trace:message:spy_enter_message (0x20062) L"Red Alert"     [0006] WM_ACTIVATE sent from self wp=00000001 lp=00000000
0024:trace:message:spy_enter_message         (0x20062) L"Red Alert"     [0007] WM_SETFOCUS sent from self wp=00000000 lp=00000000
```

Focus message sequence for 0x20062 "Red Alert":

| Msg | wParam | meaning |
|---|---|---|
| WM_NCACTIVATE | 1 | non-client area activating |
| WM_ACTIVATE | 1 | window getting activated |
| WM_SETFOCUS | 0 | gaining keyboard focus |
| **WM_ACTIVATEAPP** | **1** | **app activated — this is the message TIM-735 was added to compensate for** |

## Conclusion

cage 0.3.0 (headless backend) + standalone Xwayland + winex11.drv DOES deliver WM_ACTIVATEAPP
with wParam=TRUE to the RA main window. RA's wndproc that sets GameInFocus from wParam would
receive this message and set the global to 1. The Xvfb+openbox failure mode that motivated
TIM-735 (perpetually-FALSE GameInFocus) does NOT happen under cage+Xwayland.
