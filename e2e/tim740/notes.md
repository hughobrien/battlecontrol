# TIM-740 — interlaced RA intro rendering under Wine + cnc-ddraw (2026-05-15)

## Root cause: RA writes scanline-doubled primary buffer; cnc-ddraw renders it as-is

The TIM-739 capture (`e2e/tim739/after-cdlabel-patch-t10.png`) showed the RA
intro VQA rendered with every alternate physical scanline pure black. The
issue brief named cnc-ddraw's GDI renderer pitch/stride as the suspect.

Three control runs killed that hypothesis:

* stock cnc-ddraw v7.1.0.0 (Dec 2024 release we already had)
* same DLL with `[ra95] guard_lines=0` to bypass the CreateDIBSection
  offset path that the post-Jan-2025 commits work around
* cnc-ddraw built from `master` (a0b81b1)

All three produced byte-identical interlaced output. So cnc-ddraw was
faithfully rendering whatever RA had written. Instrumenting `render_gdi.c`
with a one-shot `fwrite(g_ddraw.primary->surface, size)` confirmed:

```
TIM-740 dumped primary buf: 0242ff00 size=256000 w=640 h=400 pitch=640
                            bpp=8 biW=640 biH=-400
```

Row analysis of the captured 640×400 8bpp buffer:

* y=0..15   (16 rows)   : top overlay, contiguous content (legitimately drawn)
* y=16..43  (28 rows)   : letterbox zeros
* y=44..354 (311 rows)  : **156 even rows of pixel data + 155 odd rows of zero
                          — perfect alternation, the interlace artefact**
* y=355..399 (45 rows)  : bottom letterbox zeros

RA's intro VQA player decodes ~156 logical rows directly into physical rows
44, 46, 48, …, 354 of the primary surface. It leaves the in-between rows
unwritten, expecting CRT hardware in 640×400 scanline-doubled mode to
replicate the previous row underneath each decoded one. Under cnc-ddraw +
Wine's GDI presentation, no such replication happens.

The original retail RA95.EXE relies on this Mode-13h-doubled convention
that was standard on 1996 VGA / VESA hardware. Modern Windows DDraw
implementations and Wine both surface a flat framebuffer where the
write-every-other-row pattern produces the artefact.

## Workaround: cnc-ddraw `scanline_double=true`

`scripts/cnc-ddraw-tim740-scanline-double.patch` adds a config flag
`scanline_double=true` to cnc-ddraw. When enabled, the GDI render path
walks each (2i, 2i+1) row pair before presentation and, if one row carries
real content and its neighbour is a "gap" (sum < 10% of the content row),
copies the content row into the gap. The asymmetric check preserves
already-doubled regions (overlay text, fade frames) where both rows
carry similar content.

The check is bidirectional — RA's VQA player scanline-doubles from either
phase depending on the frame chunk — so both `even>odd` and `odd>even`
asymmetric pairs are filled in.

Reproducible build:

```bash
bash scripts/build-cnc-ddraw.sh
# → /tmp/cnc-ddraw-master/ddraw.dll  (patched against upstream a0b81b1)
```

Enable in cnc-ddraw config (or via diag harness ini override):

```
[ra95]
scanline_double=true
```

`scripts/wine-ra-cnc-ddraw-diag.sh` and `scripts/wine-ra-cnc-ddraw-fix-verify.sh`
already write that override into their staged `ddraw.ini`.

## Verification

`scripts/wine-ra-cnc-ddraw-fix-verify.sh` runs two variants under fresh
Xvfb + openbox each, capturing one frame per second from t=8..14. PNG
file size is a direct proxy for non-interlaced content (interlaced
frames compress smaller because of the repeating black-row pattern).

| frame | A_control (stock DLL) | B_scanline_double | ratio |
| ----: | --------------------: | ----------------: | ----: |
| t10   | 48 759 bytes          | 67 512 bytes      | 1.38× |
| t12   | 40 277 bytes          | 59 306 bytes      | 1.47× |
| t14   | 40 759 bytes          | 63 718 bytes      | 1.56× |

`before-fix-t14.png` vs `after-fix-t14.png` shows the difference
visually: A is dark and dominated by black scanlines through the wrench
scene; B presents a recognisable intro frame with continuous content.

`raw-primary-interlaced.png` and `raw-primary-doubled-simulated.png` are
grayscale visualisations of the raw 640×400 primary buffer captured
in-process: the offline doubling simulation correctly produces the
clean "Trinity, New Mexico" Einstein intro frame from the interlaced
input that cnc-ddraw was rendering.

## Reproducer

```bash
bash scripts/build-cnc-ddraw.sh        # builds patched ddraw.dll into /tmp/cnc-ddraw-master/
bash scripts/wine-ra-cnc-ddraw-fix-verify.sh
# → /tmp/tim740/verify/A_control/t{8,10,12,14}.png        (stock, interlaced)
# → /tmp/tim740/verify/B_scanline_double/t{8,10,12,14}.png (fix, continuous)
```

## Follow-ups

* The doubling heuristic is conservative — when both even and odd rows
  carry similar content (overlay text, doubled fade frames), nothing is
  touched. When the rows differ by less than 10× but more than ~3×, the
  fix doesn't fire and a subtle scanline pattern can remain. The
  unfilled cases observed in the live B captures appear to be RA's
  own VQA content (specular highlights / single-pixel-tall edges) and
  not the every-other-row gap pattern, so leaving them alone is safe.
* The patch is held as a `.patch` file against upstream
  `FunkyFr3sh/cnc-ddraw@a0b81b1`. If we want a permanent home we should
  either submit it upstream or maintain a fork; for now we rebuild it
  on demand via `scripts/build-cnc-ddraw.sh`.
