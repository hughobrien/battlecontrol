# Cell / template / shroud rendering — parity bug

**Commit:** `ab0ef32` (master) — all blitter fixes already shipped.

**Capture baseline:** `/tmp/battlecontrol/2026-05-20T01-46-14-mission-allied-l1/` (frame 10, wine vs native side-by-side). Both `wine.png` and `native.png` present.

## Symptoms (native vs wine, mission allied-l1, frame 10, snow theater)

1. **Road fragmentation.** The vertical road through the centre of the explored area renders as disconnected pieces in native. Some road cells show correct road tiles; intervening cells show plain snow/clearing. The centre APC sits on snow where wine shows road underneath.

2. **Land tiles inside fog-of-war.** Three distinct clusters of white/land tiles appear inside what should be solid-black shroud at the upper edge of the explored island. Native shows terrain where wine shows opaque black.

3. **Stray text artefacts.** The string fragment "TIBHQ FREN" appears rendered on the map — strongly suggests an out-of-bounds read somewhere that picks up string-table or sprite-name data and interprets it as icon pixels.

4. **Side-by-side:** wine.png and native.png are pixel-aligned at frame 10 (same camera position), so per-pixel diff is valid.

## Already verified / ruled out (2+ hours of investigation)

### Blitter — verified correct
- `Buffer_Frame_To_Page` at `linux/win32-stubs/wwlib-asm-stub.cpp` handles `SHAPE_FADING` remap (commit `127edc2`) and `SHAPE_GHOST` translucency (commit `19964fd`). Both verified via color-marker tests and end-to-end capture.
- `Buffer_Fill_Rect` at `REDALERT/WIN32LIB/DrawMisc.cpp:717-728` — real C++, verified via red-fill diagnostic (FOW cells correctly filled).
- `CC_Draw_Shape` → `Buffer_Frame_To_Page` call chain verified for shroud-edge ghost icons (correct `IsTranslucent` / `Translucent` blend logic matching `REDALERT/KEYFBUFF.ASM:1834-1857`).

### IControl_Type offsets — verified correct
- `REDALERT/WIN32LIB/DrawMisc.cpp:1126-1127` — `Buffer_Draw_Stamp` reads `base+16` for Icons, `base+28` for TransFlag.
- **Dual-offset diagnostic test**: rendered terrain with BOTH LP64 (+16/+28) and Win32 (+12/+24) Icons offsets in parallel, marking disagreements in green. Result: **zero green pixels**. The LP64 and Win32 Icons offsets returned identical values for all drawn cells, confirming the LP64 IControl_Type layout matches the on-disk file format.
- `TILE.H:72-88` and `COMPAT.H:137-153` both define the same LP64 IControl_Type layout.
- `sizeof(IControl_Type)` = 40 on LP64 (vs 32 on Win32) because MapWidth/MapHeight/ColorMap were added — but these are at offsets 8-11 and 32, which DON'T conflict with the existing field positions (Size@12, Icons@16, etc.). The layout is self-consistent.

### LCW decompression — verified correct
- `REDALERT/LCW.CPP:69` — `LCW_Uncomp` is real C++ (not a stub).
- `REDALERT/LCWSTRAW.CPP:123` — `LCWStraw::Get` wraps LCW_Uncomp for MapPack deserialisation. Real code, no LP64 issues.
- Only `LCW_Comp` is a stub (`wwlib-asm-stub.cpp:289`, returns 0) — but compression is only used for save-game writing, not map loading.

### Theater / asset loading — nothing found
- `CONST.CPP:649-653` — Theaters array correct (SNOW→"SNO", TEMPERATE→"TEM").
- `TDATA.CPP:689` — template SHP loaded via `MFCD::Retrieve(terrain.IniName + Theaters[theater].Suffix)` — correct concatenation.

### Types / structs — checked and clear
- `CELL` = `signed short` (2 bytes), `COORDINATE` = `uint32_t` — LP64-safe.
- CellClass has no `long` or pointer fields — no sizeof discrepancy for pointer arithmetic.
- ShapeBlock_Type already has the `#pragma pack(push, 2)` and `int32_t Offsets[]` LP64 fix (`REDALERT/WIN32LIB/SHAPE.H:125-134`).

## Closest lead from instrumentation

A one-time `CellClass::Draw_It` fprintf dump (cell_number, TType, TIcon, x, y) showed 134 cells rendered at frame 10. Template types in use were: 173, 178, 185, 187 (most common), plus 60, 61, 73, 93, 94. Icon indices ranged 0-6 — all within apparently valid ranges for their templates. The log is at `/tmp/ra-cell-draw.log` (captured but instrumentation was reverted after).

The data did NOT show obviously out-of-bounds icon indices — so the "TIBHQ FREN" text artefact is likely NOT from an icon-index overflow within a single template. It might be from reading icon pixel data past the end of the loaded template buffer (i.e., the Icons offset pointing too far, or the Width/Height being wrong for a specific template).

## Suggested next attack

1. **Trace the "TIBHQ FREN" bytes.** Grep the game data for that string — it's likely from `CONQUER.ENG` (language strings) or a `*.INI` file. If those bytes sit adjacent in memory to a template SHP buffer, it confirms the icon-data-pointer is reading past its buffer.

2. **Dump template IControl_Type headers at load time.** Add a one-shot fprintf in `TDATA.CPP:690` after `MFCD::Retrieve`, dumping `(Width, Height, Count, MapWidth, MapHeight, Size, Icons, TransFlag)` for the ARROAD template (or whichever template type 178 is). Compare against what the rendering code reads.

3. **Pixel-probe the exact artefact.** In the frame-10 native capture, identify the screen coordinates of the "TIBHQ FREN" text. Then trace which cell(s) cover those pixels, and what template icon index is selected for those cells. Log the icon source data pointer read by `Buffer_Draw_Stamp` for that specific call.

4. **Check if the bug reproduces on a different mission/theater.** Mission allied-l1 uses snow theater. Try a temperate mission (e.g. Soviet mission 1) at frame 10. If the bug is theater-specific, the theater MIX loading path is the culprit.

5. **Focus on smudge/overlay rendering**, not base terrain. In RA, roads are actually **smudges** (scorch marks / vehicle tracks), not template tiles. Check `SmudgeTypeClass::Draw_It` at `REDALERT/SDATA.CPP` and the smudge loading path — this is a completely different code path from `CellClass::Draw_It` that was not investigated.

## Files most likely to contain the bug (in priority order)

1. **`REDALERT/SDATA.CPP`** — smudge type data loading and `SmudgeTypeClass::Draw_It`. Roads are smudges, not templates. UNINVESTIGATED.
2. **`REDALERT/MAP.CPP:921-990`** — `Write_Binary`/`Read_Binary` — MapPack serialisation. The cell template encoding.
3. **`REDALERT/LCWSTRAW.CPP:123-174`** — LCW decompression wrapper — verify the `Control == DECOMPRESS` path's buffer management isn't corrupting edge cases.
4. **`REDALERT/CONQUER.CPP:3703`** — `Get_Radar_Icon` — builds radar icons from template data. If this path writes to the template buffer, it could corrupt the floor tile data.

## Capture comparison command

```bash
WINE_BIN="$(command -v wine)" WINE_DATA_DIR="$RA_ASSETS" \
RA_BIN=<path-to-ra> DATA_DIR="$RA_ASSETS" \
python3 scripts/capture-checkpoint.py mission allied-l1 --frame 10 --targets wine,native
```

Latest build: `scripts/build-native.sh ra` (uses CMakePresets.json → clang).
