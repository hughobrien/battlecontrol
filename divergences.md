# Allied L2 Divergences

Reference scene: `mission allied-l2 --frame 60`.

Capture determinism: parity mission captures no longer force a random seed by
default. Stable visual comparisons should be produced by frame/state control,
not by pinning gameplay randomness in a way that could mask later drift. The
capture harness still defaults `RA_CAPTURE_FPS=10` so Wine's cnc-ddraw limiter
and native's capture throttle run at the same low rate.

Latest useful captures:

- Wine/native after current real fixes: `/tmp/battlecontrol/2026-05-20T03-38-23-mission-allied-l2`
- Native forced tactical redraw probe: `/tmp/battlecontrol/2026-05-20T03-39-49-mission-allied-l2`
- Wine/native frame-60 after message timing + stamp-map fixes: `/tmp/battlecontrol/2026-05-20T04-33-52-mission-allied-l2`
- Wine/native frame-60 after radar jam fix: `/tmp/battlecontrol/2026-05-20T04-47-45-mission-allied-l2` (`SSIM=0.9804`)
- Wine/native exact gameplay frame-60 using RA95 process-memory frame probe:
  `/tmp/battlecontrol/2026-05-20T07-54-30-mission-allied-l2` (`SSIM=0.9698`).
  This pins Wine's gameplay `Frame` at address `0x006544c8` for Allied L2 and
  proves the remaining shroud mismatch is not just wall-clock capture drift.
- Wine exact gameplay frame-90: `/tmp/battlecontrol/2026-05-20T08-17-05-mission-allied-l2`.
  The west-edge shroud pixels remain black at frame 90, so the mismatch is not
  simply Wine reaching the initial reveal a few frames later.
- Native after clipped-stamp window-origin fix:
  `/tmp/battlecontrol/2026-05-20T09-08-42-mission-allied-l2`; compared against
  the stable Wine exact frame at `/tmp/battlecontrol/2026-05-20T07-54-30-mission-allied-l2`,
  `SSIM=0.9976`, `p99=12`.
- Clean Wine/native rerun after the same fix:
  `/tmp/battlecontrol/2026-05-20T09-09-30-mission-allied-l2`, `SSIM=0.9975`.
- Clean Wine/native rerun after hiding mapped-but-not-visible overlays:
  `/tmp/battlecontrol/2026-05-20T09-39-51-mission-allied-l2`, `SSIM=0.9977`.
- Allied L3 native frame-10 shroud trace: `/tmp/battlecontrol/2026-05-20T07-21-25-mission-allied-l3`
- Allied L3 Wine FPS sweep:
  - wall-clock frame 10, 5/15/30 FPS: `/tmp/battlecontrol/2026-05-20T07-30-47-mission-allied-l3`, `/tmp/battlecontrol/2026-05-20T07-31-28-mission-allied-l3`, `/tmp/battlecontrol/2026-05-20T07-32-09-mission-allied-l3`
  - process-memory counter probe at `0x0068dea0` target 29/33: `/tmp/battlecontrol/2026-05-20T07-46-26-mission-allied-l3`, `/tmp/battlecontrol/2026-05-20T07-47-07-mission-allied-l3`
- Multi-level synchronized rerun after Wine actual-frame reporting:
  - Allied L1: `/tmp/battlecontrol/2026-05-20T21-34-18-mission-allied-l1`, `SSIM=0.9969`
  - Allied L2: `/tmp/battlecontrol/2026-05-20T21-35-15-mission-allied-l2`, `SSIM=0.9984`
  - Allied L3: `/tmp/battlecontrol/2026-05-20T21-36-13-mission-allied-l3`, Wine actual frame `1`, `SSIM=0.9443`
  - Allied L4: `/tmp/battlecontrol/2026-05-20T21-36-56-mission-allied-l4`, Wine actual frame `1`, `SSIM=0.9805`
  - Allied L5: `/tmp/battlecontrol/2026-05-20T21-37-41-mission-allied-l5`, Wine actual frame `1`, `SSIM=0.9432`
  - Soviet L1: `/tmp/battlecontrol/2026-05-20T21-38-25-mission-soviet-l1`, Wine actual frame `1`, `SSIM=0.9826`
  - Soviet L2: `/tmp/battlecontrol/2026-05-20T21-39-08-mission-soviet-l2`, Wine actual frame `1`, `SSIM=0.9509`
  - Soviet L4: `/tmp/battlecontrol/2026-05-20T21-40-36-mission-soviet-l4`, Wine actual frame `1`, `SSIM=0.9743`
  - Soviet L5: `/tmp/battlecontrol/2026-05-20T21-41-20-mission-soviet-l5`, Wine actual frame `1`, `SSIM=0.9862`

Soviet L3 is currently excluded from the passing set because the Wine capture
path often enters the top-scores screen instead of gameplay. The harness now
rejects those captures by checking tactical-viewport fill, rather than allowing
a black Wine frame and black native frame to pass as a false positive.

## Debug Execution Plan

The next pass is assertion-led. Screenshots tell us that D4 and D9 remain, but
they do not tell us whether the native port has the wrong simulation state or
the right state being drawn through the wrong dirty/redraw path.

- [x] Freeze randomness for mission parity captures with `RA_RANDOM_SEED`.
- [x] Limit both Wine and native capture runs with `RA_CAPTURE_FPS=10`.
- [x] Add a native internal frame trap so native screenshots are taken after a
  target gameplay frame reaches the renderer.
- [x] Add a capture-frame state dump for native:
  - gameplay frame and global `Frame`;
  - `TickCount` and mission countdown timer;
  - visible message count;
  - credit target/current values;
  - hashes/counts for mapped cells, visible cells, shroud shape indices, and
    redraw flags.
- [x] Add message lifetime tracing around `MessageListClass::Add_Message()` and
  `MessageListClass::Manage()` to prove whether D9 is message expiry,
  draw-layer ordering, or capture placement.
- [x] Compare native frame-60 state with native frame-1/frame-30 state to find
  where the instruction text disappears.
- [ ] Add a same-frame redraw probe for D4: save/check state after normal
  incremental redraw and again after `Map.Flag_To_Redraw(true)`.
- [ ] If the state hashes differ when screenshots should match, trace the source
  of visibility/shroud changes. If hashes match but pixels differ, focus on
  dirty-rectangle coverage, shadow template selection, and page/blit order.
- [ ] Only after native state is understood, decide whether Wine needs an
  equivalent frame trap or calibrated binary hook.
- [x] Test the apparent one-cell terrain shift:
  - source-cell offsets of `+128`/`-128` worsened or did not improve the image;
  - template pixel offsets of `+24`/`-24` also did not beat the no-offset capture;
  - tactical crop RMSE is best at `dy=0`, so the remaining terrain mismatch is
    not a global one-cell layer displacement.
- [x] Trace inactive radar panel draw:
  - native `RadarAnim` SHP frames decode to distinct buffers, so the asset load
    and keyframe decoder are not the cause;
  - git history shows the porting change replaced disabled legacy
    `IsRadarJammed` with `Get_Jammed(PlayerPtr)`;
  - `Get_Jammed(PlayerPtr)` is true when the player has no radar building, so
    native drew jam snow over the no-radar Allied cover plate.

## Tracked Divergences

| ID | Symptom | Status | Current read |
| --- | --- | --- | --- |
| D1 | Native misses mission instruction text: `Clear the way for the convoy` at top left. | Fixed | `MessageListClass::Add_Message()` was forwarding to the GlyphX callback while the in-engine label list was compiled out; native now keeps the callback and restores the label list for port builds. |
| D2 | Native misses mission countdown timer in the top bar. | Fixed | Native/WASM port now uses the Win95 high-res tab path and re-enables timer text drawing in `CreditClass::Graphic_Logic()`. |
| D3 | Native misses credit balance in the top right. | Fixed | Same high-res tab/credit draw restoration as D2; remaining credit-value mismatch was capture timing, not missing rendering. |
| D4 | Native shroud/fog edge is abrupt/blocky compared with Wine. | Fixed | `Buffer_Draw_Stamp_Clip()` treated clipped stamp coordinates as full-page coordinates while shape drawing treated them as window-relative. Terrain stamps were drawn 16 pixels too high relative to shadows/objects in the Allied L2 Win95 layout (`TacPixelY=16`). Adding the clip window origin to stamp coordinates and interpreting the clip args as origin plus width/height aligns terrain with the shadow/shape path. |
| D5 | Native had stale one-pixel text/crosshair remnants. | Fixed | `Buffer_Fill_Rect` used exclusive right/bottom; original callers pass inclusive coordinates. |
| D6 | Native initially captured wrong viewport/camera. | Fixed | `Set_Tactical_Position()` ignored its requested coordinate; Linux also needed Win95 sidebar/start-view logic. |
| D7 | Wine/native captures are at different simulation times. | Mostly fixed for native | Native now traps after the target gameplay frame is presented. Wine still uses FPS-limited wall-clock capture, but `RA_CAPTURE_FPS=10` and deterministic seed make Allied L2 frame-60 close enough to debug rendering. |
| D8 | Native credit text smears/overprints during credit counter animation. | Fixed | `CreditClass::Graphic_Logic()` now redraws the credit/timer tab background before printing updated text; frame-60 native capture shows a clean `5666`. |
| D9 | Native tutorial message lifetime differs from Wine at later frames. | Fixed | `MessageListClass` now uses the gameplay frame clock while `GameActive`; trace showed the old native path added the message at `Frame=0` with `timeout=540` but expired it at `Frame=45` because it compared against `TickCount`. Frame-60 now has `messages=1`. |
| D10 | Road/ground template art was fragmented or looked like the wrong subtile. | Fixed | The portable `Buffer_Draw_Stamp*` implementations skipped the original iconset logical-to-physical `Map` remap. Restoring that remap fixes Allied L1/L2 road fragmentation and the earlier “template rendering” issue. |
| D11 | Native inactive radar panel shows static/noise where Wine shows the Allied cover plate. | Fixed | Porting regression from `84604ef`: `Get_Jammed(PlayerPtr)` was used as a replacement for disabled legacy `IsRadarJammed`, but it is true when no radar building exists. Native now only draws jam snow when a radar exists and is jammed; no-radar Allied L2 draws the cover plate like Wine. |
| D12 | Wine has drop shadows to the right of the three control panel buttons (spanner, dollar, earth), native does not. | Fixed | The dark pixels are ordinary `SIDE1NA.SHP` sidebar art, not button shadow effects. Native drew those pixels correctly, then `RadarClass::AI()` unconditionally flagged an inactive no-radar cover redraw and `RadarClass::Draw_It()` repainted `RadarAnim` frame 0 over the sidebar. Native now advances/flags the jammed-radar animation only when a radar exists and is actually jammed. |
| D13 | Wine shroud/fog appears to have four grades between revealed and hidden, native closer to three. | Fixed | Porting regression in the portable `Build_Fading_Table()` replacement: it allowed fixed/control palette slots `0..15` as nearest fade targets, so shroud pixels from `SHADOW.SHP` source colors 13/14 over terrain color 79 collapsed to black index 0/12. RA95's table maps those cases to terrain-shadow index 16. Native now preserves transparent black and searches the game-art palette range starting at 16. |
| D14 | Native has native-only saturated green/purple/cyan/red pixels near the infantry cluster; Wine is clean. | Fixed | The saturated cluster was mapped ore (`OVERLAY_GOLD2`, `OverlayData=3`) in cell `5972`, which native drew even though the cell was mapped but not visible. The later shroud mask has transparent holes, so ore colors leaked through. Native now skips overlays for mapped-but-not-visible cells, matching Wine at the reported green/purple pixels. |

| D15 | Multi-level Soviet captures showed large native-only colored/noisy blocks and over-revealed terrain. | Mostly capture artifact | The bad Soviet L1/L2/L4/L5 samples compared Wine actual gameplay frame `1` to native frame `60` because the RA95 process-memory counter at `0x006544c8` stalls at `1` for those missions. When native is synced to Wine's reported actual frame, those missions pass. The remaining Soviet L3 issue is Wine capture entry falling into top scores, not a renderer diff. |

Remaining saturated samples at `(360..361,109..114)` are a different issue:
native traces them to a 50x39 `SHAPE_FADING|SHAPE_GHOST` remapped object draw,
consistent with unit/animation-state drift rather than the mapped-ore leak.

## Ruled Out

- Cursor edge scrolling: centering X pointer before capture barely changed SSIM.
- MapPack layout: `SCG02EA.INI` reports `NewINIFormat=3`; split template/icon layout is fully valid, interleaved is invalid.
- Treating template type `255` as a real template: worsened Allied L2 (`SSIM 0.5740`) and created black holes.
- Linux `CC_Draw_Shape` Win95 branch switch: no material effect on Allied L2 capture.

## Working Hypotheses

1. A shared scenario/UI initialization issue may explain D1-D3 if native does not load or activate mission timer, house credits, or briefing/message triggers before capture.
2. D4 may be separate rendering dirtiness: forced tactical redraw improves the map but does not restore the top-bar state.
3. Remaining shroud parity should be investigated after D1-D3 prove whether native game state is aligned with Wine.
4. The apparent one-cell terrain shift is not global: source-cell and pixel-offset probes failed to improve the tactical crop, and crop-offset scoring is best at zero vertical offset.
5. The large SSIM loss was dominated by the inactive radar panel; after fixing the jam condition, Allied L2 frame 60 passes parity at `SSIM=0.9804`.
6. The post-frameprobe Allied L2 mismatch initially looked concentrated at exact
   sight-range boundaries, but RA95 process-memory probes and native stamp
   probes changed the read: the cells and CLEAR1 icon bytes matched, while
   native terrain stamps were being placed 16 pixels above the shadow/shape
   layer. This was a clipped-stamp viewport-origin bug.

## Multi-Level Sampling Notes

### Frame-Probe Capture Artifact

The biggest new lead from sampling Allied/Soviet L1-L5 is that many of the
reported "rendering" failures were bad pairings. The Wine frame probe originally
had a stable-nonzero escape for missions where `0x006544c8` never reached the
requested target frame. That let the driver capture a Wine image at actual
counter value `1`, while the native driver still captured frame `60`.

This mismatch exactly explains the noisy native-only blocks seen in failed
Soviet samples: native units, shroud, hover text, and remapped/ghosted object
draws had advanced dozens of frames while Wine had not. Soviet L2 proves the
point directly:

- Bad pair: `/tmp/battlecontrol/2026-05-20T21-17-34-mission-soviet-l2`,
  Wine actual `1` vs native `60`, `SSIM=0.5504`.
- Same Wine image against native frame `1`: `SSIM=0.9656`.
- Harness-synced rerun after actual-frame reporting:
  `/tmp/battlecontrol/2026-05-20T21-22-31-mission-soviet-l2`, `SSIM=0.9516`.

The capture harness now writes `wine-frame.txt`, records `effective_frames` in
the manifest, and can sync native to Wine's actual frame with
`RA_SYNC_NATIVE_TO_WINE_FRAME=1`. It also rejects Wine captures whose tactical
viewport is effectively blank; this catches the Soviet L3 top-scores/main-menu
failure that previously looked like a black-but-passing screenshot.

### Allied L2 Exact Frame

Process-memory probing against RA95 under Wine identified `0x006544c8` as the
gameplay `Frame` counter for Allied L2. In a clean run it started at 54 and
advanced 55, 56, 57... while the faster candidate at `0x0069720c` advanced at
roughly nine times that rate. Gating Wine at `Frame=60` and native at internal
frame 60 produces a stable comparison in
`/tmp/battlecontrol/2026-05-20T07-54-30-mission-allied-l2`.

Before the clipped-stamp fix, that exact-frame comparison had a native-only pale
shroud opening left of the island. Native cell tracing mapped the main offending
cells at startup:

- `6227` (`cx=83 cy=48`, screen about `252,108`), `mapped=1 visible=0 shadow=13`
- `6356` (`cx=84 cy=49`, screen about `276,132`), `mapped=1 visible=0 shadow=8`
- `6484` (`cx=84 cy=50`, screen about `276,156`), `mapped=1 visible=0 shadow=12`

`RA_TRACE_SIGHT=1` showed these cells are revealed at `Frame=0` by Greece units:

- center `6231` (`cx=87 cy=48`) maps `6227`, `6356`, and `6484` with range 4;
- center `6360` (`cx=88 cy=49`) also maps `6356` with range 4.

The SCG02EA scenario confirms matching infantry at those centers, including
`25=Greece,E1,256,6231,4,Guard,192,None` and
`28=Greece,E1,256,6360,1,Guard,128,None`. Cell `6227` is exactly four cells
west of `6231`, so the next assertion is whether the native source includes a
cardinal cell at exactly `sightrange * CELL_LEPTON_W` that RA95 excludes, or
whether native's distance/radius calculation differs from the shipped binary.

Follow-up probes:

- Excluding every exact sight-radius boundary (`Distance >= range`) makes the
  target black pixels match but hides far too much terrain (`SSIM=0.8671`), so
  this is not a valid global fix.
- Measuring sight from actual infantry subcell coordinates only reduces the
  reveal slightly (`SSIM=0.9316`). It does not close the target hole because
  SCG02EA has a second Greece E1 in cell `6231` at upper-left subposition 1;
  with range 4 it still reaches `6227`.
- Reducing all infantry sight ranges by one makes the target pixels black but
  hides much too much of the visible island (`SSIM=0.7967`).
- Drawing shadow shapes opaquely leaves the same top-left pixels uncovered.
  Therefore the open native block is not a translucency table blend error; it is
  either an unmapped/different-neighborhood state in RA95 or a different
  selected shadow shape.
- Colorizing the native shroud pass with `RA_COLOR_SHADOW_CELLS=1` in
  `/tmp/battlecontrol/2026-05-20T08-26-57-mission-allied-l2` proves the pale
  top-left pixels are not terrain being drawn after the shroud. They are the
  final `Redraw_Shadow()` pass painting mapped shadow cells with native
  `Cell_Shadow()` values. This rules out draw-order repaint as the immediate
  cause.
- Suppressing all sight from cell `6231` makes `6227` unmapped and black, but it
  also hides too much neighboring terrain (`SSIM=0.9435`). This proves the bad
  block is caused by the sight contribution from the starting Greece infantry at
  `6231`, but not that the production fix should remove that sight.
- Wine frame 90 keeps the same target pixels black as Wine frame 60. The
  mismatch is stable across at least 30 RA95 gameplay frames.
- Applying global shadow-overlay Y offsets (`-24`, `-12`, `+12`, `+24` pixels)
  does not improve the exact-frame comparison. `-12` fixes the top bad pixel
  locally but lowers SSIM to `0.9436` and over-darkens nearby pixels; this is
  not a global `Redraw_Shadow()` origin error.
- Native asset tracing with `RA_TRACE_MIX_HITS=1` shows `SHADOW.SHP` and
  `TRANS.ICN` are both loaded from `CONQUER.MIX`, and the top-bar fonts are
  loaded from the expected `HIRES.MIX`/`LOCAL.MIX` sources. The remaining D4
  artifact does not currently look like fallout from the `HIRES.MIX` before
  `LORES.MIX` porting fix.
- Using `Center_Coord()` / actual coordinates for the sight origin does not fix
  the target block. `RA_SIGHT_CENTER_COORD=1` leaves the sampled pixels unchanged
  and lowers SSIM to `0.9318`; `RA_SIGHT_ACTUAL_COORD=1` previously lowered SSIM
  to `0.9316`.
- Git history check: `MapClass::Sight_From()` and the coordinate-distance
  predicate are original-source code; the native `Distance(COORDINATE,COORDINATE)`
  implementation in `COORD.CPP` is also original C, not a ported asm replacement.
  The candidate port-sensitive area is therefore object discovery/sight state,
  not the radius loop itself.
- `WINE_CELL_SCAN=1` against RA95 at exact frame 60 found the original `CellClass`
  array at `0x03af0034` with legacy stride 58. The D4 neighborhood cells
  `6098/6099/6100/6226/6227/6228/6229/6354/6355/6356/6357/6483/6484/6485`
  all had `flags16=0x000c`, while far cells had `0x0000`. Under the original
  bit ordering those are mapped and visible. This rules out a simple native-only
  reveal state as the cause of the sampled black Wine pixels.
- `RA_SKIP_D4_SHADOW_CELLS=1` did not change the suspect native pixels, even
  though `RA_COLOR_SHADOW_CELLS=1` proved the native shadow pass visits the
  cells. The light pixels are already present in the base terrain layer or are
  written by a non-shadow terrain stamp path.
- `RA_TRACE_TEMPLATE_HEADERS=1` and `WINE_TEMPLATE_SCAN=1` show `CLEAR1.SNO`
  has the same expanded iconset header in native and RA95 memory:
  `wh=24,24 count=20 alloc=0 mapwh=1,1`, with `new_icons=40`,
  `new_trans=9276`, `new_cmap=9292`, `new_map=9256`. RA95 and native also agree
  on the sampled icon bytes for clear icon 3. That makes a key/MIX/header-layout
  mismatch unlikely for the D4 clear terrain cells.
- `strings` on the patched RA95 binary confirms the public-key material is
  embedded in the executable, including `PublicKey` and
  `1=AihRvNoIbTn85FZRYNZRcT+i6KpU+maCsEqr3Q5q+LDB5tH7Tz2qQ38V`; this matches
  `REDALERT/CONST.CPP`. The current evidence does not point at MIX key lookup.
- The native terrain stamp probe showed cell `6227` writing `CLEAR1` logical
  icon 3 at `stamp=240,96`, including probe pixels `(240,100)` and `(252,108)`.
  The shadow/shape path draws through a `WINDOW_TACTICAL` viewport at
  `TacPixelY=16`, so the native terrain layer was one top-tab offset above the
  shadow layer. A window-origin correction in `Buffer_Draw_Stamp_Clip()` raises
  the terrain layer into alignment and removes the D4 blocky fog artifact.
- A later probe of the native-only saturated pixels found the writer is the
  shroud shape path, not the infantry draw path. At `(279,79)`, native draws
  `SHADOW.SHP` at `shape=264,72`, `flags=0x1040`, source pixel 16 over terrain
  index 79, through translucent table index 0, producing palette index 137.
  The same probe pattern covers the purple pixel at `(286,86)`, although the
  exact final color varies between captures.
- A Wine process-memory scan found a matching RA95 translucent-table candidate
  at `0x00644a18`: `control[16]=0`, `control[15]=1`, and samples
  `s16_d79=137`, `s15_d79=140`. This means the table mapping itself is not yet
  enough to explain the saturated native pixels. The next likely axes are the
  active palette values for those indices or whether Wine draws a different
  shadow source/destination at the same screen coordinate.

### D12 Button-Shadow Probe

The top-button shadow difference is not in the capture path. `WINE_SCREEN_SCAN=1`
found two RA95 640-stride screen buffers at exact frame 60 where all nine sampled
button-shadow pixels match Wine's dark palette indices:

- `0x02a2ff00`, stride 640
- `0x02a9ff00`, stride 640

The early memory scan proved the final dark pixels were already present in RA95's
8-bit screen buffers, but it did not identify a separate button-shadow primitive.
The final native provenance trace showed the missing "button shadows" are not
produced by the buttons at all. They are sidebar-top pixels from `SIDE1NA.SHP`.
Native was drawing them correctly, then repeatedly overwriting them with the
inactive radar cover:

- `RadarClass::Draw_It` draws `RadarAnim` frame 0 at `(480,16)`,
  `160x141`, producing the bright/native values.
- `SidebarClass::Draw_It` then draws `SIDE1NA.SHP` at `(480,16)`,
  `160x160`, producing the Wine-matching dark values.
- Before the fix, `RadarClass::AI` unconditionally flagged the radar for redraw
  even when `IsRadarActive=0` and `DoesRadarExist=0`, so the next render drew
  `RadarAnim` frame 0 over the sidebar again.

Gating that `RadarClass::AI` block to actual jammed-radar state
(`DoesRadarExist && Get_Jammed(PlayerPtr)`) removes the repeated inactive-cover
redraw. After the fix, all nine sampled D12 pixels match Wine exactly at frame
60, and Allied L2 Wine-vs-native reports `SSIM=0.9974` for the local capture
session `2026-05-20T18-55-32-mission-allied-l2`.

### Allied L3

The pale native rectangles north of the lower island are not stale pixels and
not a global one-cell terrain shift. Native frame-1 and frame-10 traces show the
same cells already marked as `mapped=1 visible=0` before the first captured
gameplay render; later redraws make them visible. Targeted `Sight_From()` trace
shows the cells are revealed at `Frame=0` from the Greece unit centered at cell
`7738` (`cx=58 cy=60`) with sight range 3:

- `7354` (`cx=58 cy=57`, screen `168,228`)
- `7480` (`cx=56 cy=58`, screen `120,252`)
- `7481` (`cx=57 cy=58`, screen `144,252`)
- `7482` (`cx=58 cy=58`, screen `168,252`)
- `7608` (`cx=56 cy=59`, screen `120,276`)
- `7735` (`cx=55 cy=60`, screen `96,300`)

Two probes did not move the artifact:

- returning legacy global `IsMapped` / `IsVisible` from the `CellClass` query
  functions in `GAME_NORMAL`;
- returning legacy global `IsDiscoveredByPlayer` from
  `TechnoClass::Is_Discovered_By_Player()` in `GAME_NORMAL`.

An opaque-shadow diagnostic also leaves the rectangles open. That means the
selected `SHADOW.SHP` frames leave those pixels uncovered; the immediate cause
is not the ghost/translucency table. The remaining question is whether RA95 has
the same edge-of-sight cells mapped at the same internal state.

Wine Allied L3 is not yet a trustworthy frame reference:

- wall-clock frame 10 can produce clean gameplay, but it lacks the top-left
  mission message that native has, so it is not state-aligned;
- wall-clock frames 11+ often hit the RA95 `0x00534273` crash dialog;
- a process-memory scan found `0x0068dea0` advancing `10 -> 20/29/33`, but it
  caps at 33 and appears to be a transition/fade counter, not the gameplay
  `Frame`;
- candidate addresses `0x00642080`, `0x006544c8`, and `0x00655d18` remained
  at zero during the same probe; `0x0066b68c` only advanced to 2.

Next assertion: find the real RA95 gameplay `Frame` or another post-briefing
state variable, then gate Wine screenshots from process memory before judging
the Allied L3 shroud cells against native.

### Soviet Campaign

The flake now exposes both Allied and Soviet data sets. The Wine scenario patch
was extended to replace both `SCG01EA.INI` and `SCU01EA.INI`, and the autostart
patch gained a `--side` switch so Soviet missions can take the Soviet scenario
string path. That fixes the earlier wrong-level harness issue where Soviet
captures loaded an Allied mission.

Soviet visual sampling remains blocked by the same Wine stability problem:
early native captures show similar mapped/fog edge cells, but Wine often crashes
or lands in the debugger before a usable same-state gameplay reference.
