# Debugging patterns

Repeatable techniques that have paid off when chasing rendering parity
bugs between the wine OG pipeline and the native Linux RA build. The
examples are drawn from real sessions — file paths and call IDs match
what you'll see in a current capture session.

Each pattern is structured as: when to reach for it → what it looks like
in code → what to watch for in the output.

---

## 1. One-shot capped logging in a hot path

**When:** You suspect a specific function is the culprit but it's called
thousands of times per frame (every shape draw, every cell render). You
want a useful trace without drowning the log.

**Pattern:** Two static counters — one for the first N calls overall,
one for a separate subset of "interesting" calls. Stop after each cap.

```cpp
#ifndef _MSC_VER
{
    static int s_call_count = 0;
    static int s_radar_logged = 0;
    bool radar_zone = (x >= 460 && x < 640 && y >= 0 && y < 260);
    bool log_first = (s_call_count < 60);
    bool log_radar = (radar_zone && s_radar_logged < 30);
    if (log_first || log_radar) {
        fprintf(stderr, "[CCDS] #%d shape=%p frame=%d x=%d y=%d w=%d h=%d\n",
                s_call_count, shapefile, shapenum, x, y, w, h);
        fflush(stderr);
    }
    if (log_radar) s_radar_logged++;
    s_call_count++;
}
#endif
```

**Watch for:** The first 60 calls usually cover all the init / first-frame
shapes you care about. The "zone" cap then catches the same call IDs across
later redraws so you can spot a particular shape coming back through a
different code path.

**Gotchas:**
- Always guard with `#ifndef _MSC_VER` so wine-side builds don't change.
- Always `fflush(stderr)` — RA's signal handlers and the wine driver
  truncate stderr without flushing on abnormal exit.
- The call-count `s_call_count` is the single most useful thing to log:
  it gives you a global timeline you can cross-reference between separate
  diagnostics.

---

## 2. State-change-only logging at a high-traffic entry point

**When:** A function like `SidebarClass::Draw_It` runs every frame, but
the interesting information is *which path* it takes — and that path
only changes a handful of times per session.

**Pattern:** Cache the last set of relevant state variables; only log when
something flips.

```cpp
static int  s_calls = 0;
static bool s_last_active = false;
static bool s_last_redraw = false;
if (s_calls < 30 || IsSidebarActive != s_last_active
    || IsToRedraw != s_last_redraw) {
    fprintf(stderr, "[SBDI] #%d active=%d redraw=%d complete=%d\n",
            s_calls, IsSidebarActive, IsToRedraw, complete);
    fflush(stderr);
    s_last_active = IsSidebarActive;
    s_last_redraw = IsToRedraw;
}
s_calls++;
```

**Watch for:** A single `[SBDI] #0 active=1 redraw=1 complete=1` line near
the start of the log, with no subsequent state changes, tells you the
sidebar is being rendered once (during the full-redraw frame) and skipped
on every redraw after. That's the expected pattern; absence of the first
line means the path never fires at all.

---

## 3. The TIM-275 one-time tripwire

**When:** You need to know whether a specific code path *ever* fires
during a run, but logging every entry would be too noisy.

**Pattern:** A single `static bool` guard that flips on first entry and
prints once.

```cpp
static bool s_diag = false;
if (!s_diag) {
    s_diag = true;
    fprintf(stderr, "TIM-275 Plot_Radar_Pixel diag: Lock=%d Mapped=%d\n",
            (int)LogicPage->Lock(), mapped_cells);
}
```

**Watch for:** *Absence* of this line in the log is the signal. If you
expect `Plot_Radar_Pixel` to fire and the line never appears, the
enclosing branch (e.g. `if (IsRadarActive)`) is never taken — which
immediately rules out a whole hypothesis about where the bug lives.

The convention `TIM-NNN` prefixes these tripwires by the ticket they
were added under, so old diagnostics stay greppable.

---

## 4. Targeted CRC lookup across loaded MIX files

**When:** A `MFCD::Retrieve("name.shp")` is returning the wrong variant
of a shape and you have multiple MIX files registered. You don't want to
dump every entry in every MIX (some have thousands).

**Pattern:** Compute the Westwood CRC for the filenames you care about
(see `scripts/extract_mix.py` for the algorithm), then iterate every
loaded MIX's index buffer searching for those CRCs.

```cpp
struct { unsigned crc; const char *name; } targets[] = {
    {0x3221db0b, "NATORADR.SHP"},
    {0x71e40a02, "SIDE1NA.SHP"},
};
for (auto &t : targets) {
    for (int i = 0; i < Count; i++) {
        if ((unsigned)HeaderBuffer[i].CRC == t.crc) {
            fprintf(stderr, "[MIX] HIT: %s in %s at idx[%d] sz=%d\n",
                    t.name, filename, i, HeaderBuffer[i].Size);
        }
    }
}
```

Place this inside `MixFileClass::MixFileClass` after `index read done` so
every newly-registered MIX runs it.

**Watch for:** If `NATORADR.SHP` appears in both `LORES.MIX` (sz=101157)
and `HIRES.MIX` (sz=366341), the size disparity tells you the resolution
of each variant. The first MIX with a hit is what `MFCD::Offset` will
return — load order is precedence order.

The Westwood CRC can be computed in Python:

```python
import struct, ctypes
def rotl(v, n): v &= 0xFFFFFFFF; return ((v << n) | (v >> (32-n))) & 0xFFFFFFFF
def crc(s):
    s = s.upper().encode()
    c = 0; idx = 0; stg = bytearray(4)
    for b in s:
        stg[idx] = b; idx += 1
        if idx == 4:
            c = (rotl(c,1) + struct.unpack('<I', stg)[0]) & 0xFFFFFFFF
            idx = 0; stg = bytearray(4)
    if idx > 0:
        c = (rotl(c,1) + struct.unpack('<I', bytes(stg))[0]) & 0xFFFFFFFF
    return ctypes.c_int32(c).value & 0xFFFFFFFF
```

---

## 5. Internal BMP capture vs X11 screen grab

**When:** You see a visual artifact and don't know whether it's in the
game's render buffer or in the SDL → X11 path.

**Pattern:** The native RA build has TIM-490 hooks
(`RA_Save_Gameplay_BMP`) that snapshot the SDL primary ARGB surface at
game-loop frames 10, 50, and 100. These bypass the X11 capture step:

```
/tmp/redalert-gameplay-f010.bmp  ← internal SDL ARGB buffer
/tmp/battlecontrol/<session>/native.png  ← X11 screen capture
```

**Watch for:** If both show the same artifact, the bug is upstream of the
SDL surface — i.e. in the game's pixel rendering. If they differ, the
SDL → X11 path is mistranslating something (palette, alpha, geometry).

---

## 6. Cropping the capture to focus the eye

**When:** A 1024×768 X11 grab is too busy to read at a glance, but the
artifact is in a 100×100 region.

**Pattern:** ImageMagick `magick` (not the deprecated `convert`) with the
`-crop WxH+X+Y +repage` form:

```bash
magick native.png -crop 200x200+650+170 +repage native-radar.png
magick redalert-gameplay-f050.bmp -crop 250x200+0+280 +repage bot-left.png
```

`+repage` resets the crop offset so the cropped PNG can be inspected
without coordinate confusion. The `Read` tool can then display the result.

---

## 7. Wine vs native as the structural diff

**When:** You can't tell whether a behaviour is a bug or by-design.

**Pattern:** The wine OG pipeline runs the retail 1996 RA95.EXE binary
(see `docs/wine-rendering-explainer.md`). That binary was compiled by
Westwood with `#if` toggles in their preferred configuration — so wine
output is effectively the "intended" output. Anywhere wine and native
diverge, the bug is in native or in a config divergence (data dir,
patches, load order, missing code path).

`scripts/capture-checkpoint.py mission allied-l1 --targets wine,native`
produces `wine.png`, `native.png`, and an amplified `diff-*.png` in
`/tmp/battlecontrol/<timestamp>-mission-allied-l1/`.

The SSIM is a useful coarse signal but the diff PNG is the real
informant — green and magenta blobs show *what* differs, not just *that*
something does.

---

## 8. Don't trust the obvious subsystem

The most expensive trap in this codebase: a rendering bug *looks* like a
rendering bug, but the actual fix is two subsystems away. Examples:

- Half-width sidebar + radar noise → looked like a stride/blit bug in
  `Buffer_Frame_To_Page`. Was actually `MFCD` load order.
- "Window appears, content rendered, every other row black" → looked like
  a Wine GDI issue. Was a missing scanline-doubling step in `cnc-ddraw`.
- "Wine renders correctly but SSIM-vs-native is low" → looked like
  a comparison-tool bug. Was actually game-state divergence from
  wall-clock-based frame timing.

The countermove is to **instrument widely before forming a hypothesis**:
log the actual coordinates / dimensions / pointer values flowing through
the suspect call site, then read them. The smoking gun in the load-order
bug was a single line of `[CCDS] w=80 h=80` when the rendered area was
expected to be 160-wide — that immediately ruled out "the renderer is
broken" and pointed at "the shape data we're feeding it is wrong."

---

## 9. Phase 1 of systematic-debugging is the iron rule

The `superpowers:systematic-debugging` skill is structured around
four phases, and the easiest one to skip is the first:

> NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.

The temptation is real. The HIRES1.MIX experiment in the load-order
session looked like it would work — the file even loaded successfully —
but a quick CRC lookup showed `NATORADR.SHP` wasn't actually in it.
Without the CRC check, "flipped #if 0, rebuilt, ran, saw no change,
flipped some other thing" would have eaten an hour. With the check the
real culprit (HIRES.MIX vs LORES.MIX ordering) showed up in one log line.

---

## See also

- `docs/wine-rendering-explainer.md` — the wine-side pipeline, layer by
  layer. The "Debugging by layer" section maps symptoms onto suspected
  layers.
- `skills/parity-comparison/SKILL.md` — the parity-compare workflow.
  §5 has bisection notes for SSIM regressions.
- `~/.claude/plugins/cache/superpowers-marketplace/superpowers/.../skills/systematic-debugging/`
  — the broader debugging framework, of which this doc is the project-
  specific tooling layer.
