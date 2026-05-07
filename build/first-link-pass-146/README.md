# TIM-146 first-link-pass-146 — Umbrella C stubs

Adds three new stub TUs and a TurretClass vtable anchor. Closes the L1
(system-lib) and bodyless-L4 (asm-seam + vtable) link gaps surfaced by
the [TIM-143](../../) pass-43M survey.

## What changed

Code:

- `linux/win32-stubs/oleaut32-stub.cpp` — NOP bodies for
  `SafeArrayCreate` (returns NULL), `SafeArrayAccessData`,
  `SafeArrayUnaccessData` (both return `E_NOTIMPL`). Editor-only call
  sites in `DLLInterfaceEditor.cpp` are guarded by `SUCCEEDED(...)`.
- `linux/win32-stubs/kernel32-stub.cpp` — real
  `GetSystemTimeAsFileTime` via `clock_gettime(CLOCK_REALTIME)`,
  converted to Win32's "100-ns intervals since 1601-01-01"
  representation. Trivially correct for the EVENT.CPP heartbeat math.
- `linux/win32-stubs/wwlib-asm-stub.cpp` — `extern "C"` NOP bodies for
  `Buffer_To_Buffer`, `Buffer_Print`, `Buffer_Frame_To_Page`,
  `LCW_Comp`, `Detect_MMX_Availability`; data symbols `CPUType` (0)
  and `VendorID` (16-byte vendor-string buffer).
- `REDALERT/TURRET.CPP` — empty bodies for the previously
  declared-only virtuals `Code_Pointers` and `Decode_Pointers`. These
  anchor the `TurretClass` vtable per the Itanium ABI key-function
  rule (the existing out-of-line dtor was not the key function).

Build plumbing:

- `scripts/first-link-pass-146.sh` — mirrors pass-144 with
  `linux/win32-stubs/*.cpp` added to the source set and an explicit
  `LZWOTRAW.CPP` skip (TIM-144's working-tree rename did not survive a
  checkout round-trip; LZWStraw is canonical in `LZWSTRAW.CPP`).

## Before / after

| Metric                      | pass-144 | pass-146 |   Δ   |
|-----------------------------|---------:|---------:|------:|
| compile OK                  |      301 |      301 |  ±0  |
| compile FAIL                |        0 |        0 |  ±0  |
| undef-reference sites       |      157 |      133 | **−24** |
| unique unresolved symbols   |       71 |       60 | **−11** |
| multiple-def errors         |       19 |       20 |   +1  |

11 unique symbols closed:

- `Buffer_Frame_To_Page`
- `Buffer_Print`
- `Buffer_To_Buffer`
- `CPUType`
- `Detect_MMX_Availability`
- `GetSystemTimeAsFileTime`
- `LCW_Comp`
- `SafeArrayAccessData`
- `SafeArrayCreate`
- `SafeArrayUnaccessData`
- `VendorID`

`vtable for TurretClass` was undef per pass-43M, but had already been
masked out of pass-144's link.log by intervening commits (callers no
longer required the symbol). The anchor is still correct: pass-146's
`TURRET.o` now emits `_ZTV11TurretClass` as a weak vtable, so any
future caller will resolve.

## New multidef (cascade-stop, not chased here)

`_Kbd` — multiple definition between `KEYBOARD.o` and `KEY.o`. This is
TIM-145 in-flight: KEY.CPP recently grew `_Kbd` while KEYBOARD.CPP
already had it. The KEYBOARD/KEY consolidation already on the
follow-up list (TIM-144 cascade-stops doc) covers this. **Filed for
follow-up; not closed in this pass.**

## Files

- `compile-status.txt` — per-TU OK/FAIL/SKIP table.
- `compile.log` — full per-TU compile diagnostics.
- `link.log` — link diagnostic (warnings + undef refs).
- `link-summary.txt` — counts and multidef summary.
