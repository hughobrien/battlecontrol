# TIM-724 — Side-select GDI click reaches TD, then crashes at 0x4112ae

## State after TIM-747 + this work

- TD boots, side-select menu renders (TIM-747 result confirmed).
- This work added xdotool-based menu navigation to `scripts/wine-gdi-m1.sh`
  (mirroring the pattern from `scripts/wine-gameplay.sh` for RA).
- 1024x768 Xvfb (was 800x600, matching `wine-allied-l1.sh`).
- Window origin auto-detection via `xdotool getwindowgeometry`.
- xdotool `mousemove+click 1` lands on the GDI portrait correctly.

## New blocker

Clicking the GDI portrait at game (160, 180) reaches TD's input handler.
TD begins GDI campaign initialisation and crashes:

```
wine: Unhandled page fault on read access to 00000000 at address 004112AE
Application Error: D:\C&C95.EXE
The instruction at 004112ae referenced memory at 00000000
The memory could not be read from
```

Captured in `e2e/tim724/gdi-m1/t25-briefing-advance.png` and
`t35-post-map.png`.

## Disassembly at the fault

```
411297:  bf 0c 43 54 00         mov  edi, 0x54430c
41129c:  8b 34 85 24 81 53 00   mov  esi, DWORD PTR [eax*4 + 0x538124]
4112a3:  a3 bc 82 53 00         mov  ds:0x5382bc, eax
4112a8:  57                     push edi
4112a9:  89 c8                  mov  eax, ecx
4112ab:  c1 e9 02               shr  ecx, 2
4112ae:  f2 a5                  repnz movs DWORD PTR es:[edi], DWORD PTR ds:[esi]   <-- FAULT
4112b0:  8a c8                  mov  cl, al
4112b2:  80 e1 03               and  cl, 0x3
4112b5:  f2 a4                  repnz movs BYTE PTR es:[edi], BYTE PTR ds:[esi]
4112b7:  5f                     pop  edi
4112b8:  55                     push ebp
4112b9:  e8 42 be 0b 00         call 0x4cd100
4112be:  83 c4 04               add  esp, 0x4
4112c1:  5d                     pop  ebp
4112c2:  5f                     pop  edi
4112c3:  5e                     pop  esi
4112c4:  5b                     pop  ebx
4112c5:  c3                     ret
```

This is a `rep movsd` block copy:

- destination `edi = 0x54430c` (fixed global in `.bss`)
- source `esi = [eax*4 + 0x538124]` (pointer table in `.bss`, indexed by `eax`)
- byte count in `ecx` (dword count after `shr ecx,2`)

The fault means the table entry at `[eax*4 + 0x538124]` is `NULL`. Side
selection passes the side index (0 = GDI) in `eax`, so the GDI entry of
this side-indexed pointer table has not been populated.

## Likely interpretation

`0x538124` looks like the `SideData` (or equivalent) pointer table that
gets filled by reading a per-side resource (a `.PAL`, a `.INI`, or a MIX
entry). The block copy at `0x4112a8..0x4112b5` would then snapshot that
side's data into the working buffer at `0x54430c` when the player picks a
side.

Candidates for the missing resource:

1. A side-specific palette (GDI vs NOD have different UI colour maps).
2. A side-specific text or rules INI loaded from `CONQUER.INI` /
   `RULES.INI` (TD doesn't really ship `RULES.INI` but has equivalents).
3. Side-specific shape sets (sidebar buttons, etc.) loaded from the MIX
   chain.

The `TEMPERAT.PAL` extraction added by `wine-gdi-m1.sh` is the *theatre*
palette, not the side palette — different concern.

This is downstream of TIM-747's render seam: the menu now draws, input now
reaches TD, but a TIM-743-style data-table init step is still missing for
the GDI campaign path.

## Suggested follow-up scope

A new child issue (TIM-7XX) should:

1. Add `WINEDEBUG=+relay,+seh` and capture the call stack at the fault to
   identify which function reads `[eax*4 + 0x538124]`.
2. Cross-reference `0x538124` writes to find where the table is populated
   (`grep`/`r2`/`ghidra` for stores to that address).
3. Determine the missing resource (palette / INI / MIX entry) by tracing
   the read sites.
4. Provide one of:
   - A copy of the missing resource into `STAGE` (no binary patch).
   - A `td-side-data-stub-patch.py` that returns a sane default for the
     missing entry, mirroring the `td-vqa-skip-patch.py` pattern.

## Current state of acceptance criteria

| Criterion                              | Status |
|----------------------------------------|--------|
| 1. wine-td.sh navigates main menu → GDI M1 start | ❌ crashes at GDI side click |
| 2. Frame 500 shows non-black terrain    | ❌ no gameplay reached |
| 3. Script exits cleanly with rc 0       | ✅ exits 0 (cleanup runs) |
| 4. ≥3 gameplay screenshots in docs      | ⚠️ 8 captures but pre-gameplay (menu + crash dialog) |

TIM-724 is blocked on the new follow-up child issue.
