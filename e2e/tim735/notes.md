# TIM-735 — GameInFocus pin in RA95.EXE (2026-05-15)

Implements the next step proposed by TIM-732: a static patch that pins
`GameInFocus = TRUE` in the retail RA95.EXE so the render path is no
longer gated on a `WM_ACTIVATEAPP(TRUE)` message that Xvfb+openbox never
delivers.

## What the patch does

`scripts/game-in-focus-patch.py` applies two cooperating writes to the
GameInFocus byte at `.bss` VA `0x0066B6B8`:

1. **Entry-point detour.** PE entry (file `0x1AD8CA`, VA `0x005BD4CA`)
   is rewritten from the original `mov [0x6D794C], 0x005594B0; jmp +0x85AF`
   to a 5-byte `jmp 0x005CC6BF` plus 10 NOPs. The jump target is a 22-byte
   shim placed in the existing 65-byte zero-padding region at file
   `0x1BCABF` / VA `0x005CC6BF`. The shim does:

       C6 05 B8 B6 66 00 01            mov byte [0x66B6B8], 1
       C7 05 4C 79 6D 00 B0 94 55 00   mov [0x6D794C], 0x005594B0  (replay)
       E9 B3 93 FF FF                  jmp 0x005C5A88              (continue to CRT)

2. **Spin-loop site rewrites.** Where `focus-skip-patch.py` had replaced
   the 6-byte JZ at offsets `0x154005`, `0x15F2F1`, `0x15F583` with NOPs
   (leaving the preceding `cmp byte [GIF],0` intact), this patch replaces
   the full 13 bytes (cmp + nops) with `mov byte [GIF],1` + 6 NOPs. So if
   any of the Watcom-emitted `do { … } while (!GameInFocus)` spin loops
   in Init_Game / title-pump / netdlg is entered after CRT init, the byte
   is re-pinned even if the runtime touched .bss.

The 1996 retail binary has no ASLR (fixed image base `0x00400000`), so
absolute addresses encoded in the shim are correct without adding .reloc
entries.

## Verification

The entry detour is confirmed to fire. Patching the cave's first byte
with `0xCC` (INT3) and running under Xvfb produces:

    wine: Unhandled exception 0x80000003 in thread 24 at address 005CC6BF

— exactly the cave VA, confirming the JMP from the entry point reaches
the shim before any other RA code executes.

The patch script is SHA-256 gated, idempotent, and saves a
`.game_in_focus_orig` backup. Re-runs of the same EXE are no-ops.

Accepted input SHAs:

- `b00745c2…` — probe-skip-patched
- `08f89ab8…` — probe + focus-skip
- `5e7d3c38…` — probe + focus-skip + vqa-skip

## What this patch does NOT fix

Running `scripts/wine-ra-cnc-ddraw-diag.sh` under Wine 10 + cnc-ddraw
7.5.0 + Xvfb+openbox with the GameInFocus pin applied still produces a
**black DDraw surface inside the "Red Alert" titled window**, identical
to the focus-skip-only baseline (both `t10/t15/t20.png` = 5912 bytes).

See `wine10-cnc-ddraw-baseline-no-patch.png` (focus-skip only) vs
`wine10-cnc-ddraw-with-game-in-focus-pin.png` (this patch) — pixel-
identical at 800×600, 5912 bytes each. The cmp-imm-flip variant
(changing every `cmp byte [GIF],0` → `cmp byte [GIF],1`) was also
tested and produces the same result. Inspection of wine.log shows both
runs reach the same parked state after 5 secondary `DSound` buffers
and a `NtGdiDdDDIOpenAdapterFromHdc` stub call.

This means the **TIM-732 hypothesis is incomplete**: GameInFocus is not
the (only) gate that keeps RA from painting title/menu content into the
cnc-ddraw surface under headless Wine. The pin is correct, demonstrably
executes, and is now in place for follow-up debugging — but it is not
sufficient on its own to satisfy TIM-735's "non-black RA content"
acceptance criterion.

## Next steps

Open a follow-up issue to identify the *actual* gate(s) on the title
render. Useful starting points:

- `WINEDEBUG=+relay,+seh` trace bracketed to the main RA thread to find
  the next blocking syscall or message after `NtGdiDdDDIOpenAdapterFromHdc`.
- `winedbg --gdb -- wine RA95.EXE` and break on `Map.Render` /
  `Render_Frame` to confirm whether the render code is *reached* and just
  produces black, vs *not reached* because main loop never enters it.
- Stub or replace cnc-ddraw's `BltFast` / `Flip` paths under Wine 10's
  GDI renderer — there may be a missing `GetDIBits` / `BitBlt` step in
  the present pipeline.
- Compare `WINEDEBUG=+message,+win` traces against the OG Allied CD on a
  hardware-Windows reference to spot the missing top-level message that
  unsticks the Watcom message pump.

## Reproducer

```bash
WINE=/usr/bin/wine \
    WINEPREFIX=$HOME/.wine-tim732-w10 \
    RUN_SECONDS=35 \
    ARTIFACT=/tmp/tim735/run \
    bash scripts/wine-ra-cnc-ddraw-diag.sh
```

Expected: same 5912-byte black-surface t20.png as the TIM-732 baseline.
The harness now runs `focus-skip-patch.py` then `game-in-focus-patch.py`
on the staged EXE before launching, so both pins are in effect.
