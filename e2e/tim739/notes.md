# TIM-739 — Next render-gate after GameInFocus pin (2026-05-15)

## Root cause: Get_CD_Index() spin-loop on empty volume label

The GameInFocus pin (TIM-735 / PR #137) caused RA to reach the title-screen
render path, which then hit a second spin-loop: `Get_CD_Index()` in
`CONQUER.CPP:4675`.

### Code path

```cpp
// CONQUER.CPP:4675
for (;;) {
    sprintf(buffer, "%c:\\", 'A' + cd_drive);
    if (GetVolumeInformation(buffer, volume_name, ...)) {
        HANDLE h = CreateFile("%c:\\main.mix", ...);
        if (h != INVALID_HANDLE_VALUE) {
            CloseHandle(h);
            for (int i = 0; i < _Num_Volumes; i++) {
                if (!stricmp(_CD_Volume_Label[i], volume_name))
                    return(i);   // ← success path
            }
            // label mismatch: no exit → loops forever
        }
    }
    // timer only checked when GetVolumeInformation FAILS
}
```

`_CD_Volume_Label[] = {"CD1", "CD2"}` with `_Num_Volumes = 2`.

### Why it spins

The CD1 data directory is on a CIFS (Samba) mount:
`//bigthink.lan/cnc` → `/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1`.

For this path Wine's `GetVolumeInformationA("D:\\")` returns:
- retval = TRUE (the directory is accessible)
- volume label = "" (empty; CIFS has no xattr support, no label stored)

Wine's internal path: `NtQueryVolumeInformationFile` with class 1
(`FileFsVolumeInformation`) reads from `getxattr("user.wine.volume_label")`.
On a CIFS filesystem, this fails silently and returns empty.

`stricmp("CD1", "")` and `stricmp("CD2", "")` both return non-zero → label
comparison fails → no exit from `for(;;)`.

The countdown timer (`CountDownTimerClass timer; timer.Set(1*60)`) at line
4669 is only checked in the `GetVolumeInformation FAILS` branch (line 4720),
so with CIFS returning TRUE the timer check is never reached.

This was confirmed via `WINEDEBUG=+relay` trace: thread 0024 (RA's main
init thread) called `GetVolumeInformationA("D:\\")` 17,337 times during the
30-second run window — solid evidence of the spin-loop.

## Fix: cdlabel-patch.py

`scripts/cdlabel-patch.py` zeroes the first byte of `"CD1"` in the
`_CD_Volume_Label[]` array (file offset `0x1bfcb7` in the DGROUP section,
VA `0x5d2ab7`):

```
Before: 43 44 31 00  ("CD1\0")
After:  00 44 31 00  ("\0D1\0" — empty string with dead bytes)
```

`_CD_Volume_Label[0]` now points to an empty string `""`.  When Wine returns
`""` as the volume label, `stricmp("", "") == 0` → `Get_CD_Index` returns 0
→ CD check passes.  `_CD_Volume_Label[1]` (`"CD2"`) is unaffected.

## wine-ra-cnc-ddraw-diag.sh updated

`scripts/wine-ra-cnc-ddraw-diag.sh` now runs `cdlabel-patch.py` after
`game-in-focus-patch.py` in the staging step.

## Verification

Before patch (TIM-735 baseline):
- All frames: 5912 bytes (solid-black DDraw surface)

After cdlabel-patch (this fix):
- t5.png: 5912 bytes (black — CD check still running at t=5s)
- t10.png: **41,687 bytes** — RA title-screen intro frame visible
- t15.png: **41,941 bytes** — animation advancing
- t20.png: **39,923 bytes** — further animation

Screenshot `after-cdlabel-patch-t10.png` shows the Einstein close-up intro
frame rendered inside the "Red Alert" cnc-ddraw window under Wine 10 +
Xvfb + openbox. The image is interlaced (alternate scanlines black) — this
is a separate cnc-ddraw GDI stride artefact to fix in a follow-up.

## Reproducer

```bash
WINE=/usr/bin/wine \
    WINEPREFIX=$HOME/.wine-tim732-w10 \
    RUN_SECONDS=35 \
    ARTIFACT=/tmp/tim739/run \
    bash scripts/wine-ra-cnc-ddraw-diag.sh
```

Expected: t10.png / t20.png ≥ 20 KB (non-black content), compared to
pre-patch 5912-byte black-surface baseline.

## Follow-up: interlaced rendering

The rendered frames show every alternate scanline black — a stride or blit
artefact in cnc-ddraw's GDI renderer under Wine. The cnc-ddraw surface pitch
may be set to `width * 2` instead of `width * bytes-per-pixel`, causing
`SetDIBitsToDevice` to skip alternate lines. This should be investigated
in a follow-up issue.
