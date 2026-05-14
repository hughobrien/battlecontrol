# LP64 Static Audit

Distilled from real bugs fixed during the Linux port of Red Alert and Tiberian Dawn
([TIM-173], [TIM-206], [TIM-241]–[TIM-243], [TIM-423], [TIM-453]).

## What this catches

The Win32 C++ codebase was written assuming LP32 or LLP64 (MSVC 32-bit):

| Type          | Win32 size | LP64 Linux size | Hazard                      |
|---------------|------------|------------------|-----------------------------|
| `long`        | 4 bytes    | 8 bytes          | struct layout, arithmetic   |
| `unsigned long` | 4 bytes  | 8 bytes          | same                        |
| `void*`       | 4 bytes    | 8 bytes          | pointer truncation in int   |
| `LONG`/`ULONG`| 4 bytes    | 8 bytes          | via `typedef long LONG`     |
| `HRESULT`     | 4 bytes    | 8 bytes          | via `typedef long HRESULT`  |

## Running the audit

```bash
# From the repository root:
python3 scripts/lint-lp64.py

# Via CMake (after configuring a build dir):
cmake --build build --target lint-lp64

# Errors only (stricter gate):
python3 scripts/lint-lp64.py --errors-only

# Custom directories:
python3 scripts/lint-lp64.py --dirs REDALERT
```

Exit codes: `0` = clean, `1` = errors found, `2` = warnings only.

## Rule reference

### Errors (must fix before each native-boot milestone)

| Rule | Pattern | Bug example |
|------|---------|-------------|
| E1:typedef-long | `typedef (unsigned) long NAME` | `typedef unsigned long COORDINATE` grew from 4→8 bytes, misaligning every downstream struct ([TIM-241]) |
| E2:_lrotl | `_lrotl` / `_lrotr` | CRC rotation on `unsigned long` silently operates on 64 bits; CRC mismatch breaks save-file loads ([TIM-173], [TIM-453]) |
| E3:ptr-to-int-cast | `(int)somePtr` | Pointer truncation; pointer alignment checks using `(int)ptr & 0xff000000` always pass on LP64 |
| E4:packed-long-field | `long field` inside `#pragma pack` struct | All fields after the `long` shift by 4 bytes relative to their Win32 layout, breaking binary I/O ([TIM-202]) |

### Warnings (investigate before each native-boot milestone)

| Rule | Pattern | Risk |
|------|---------|------|
| W1:long-field | `(unsigned) long field` in a struct | Field grows 4→8 bytes, inflating class size and misaligning successors ([TIM-242], [TIM-243]) |
| W2:sizeof-long | `sizeof(long)` as a constant | Returns 8, not 4; breaks buffer allocation and record-size assertions |
| W3:long-offset-array | `(unsigned) long arr[N]` | Binary-file offset tables assume 4-byte elements; each entry doubles on LP64 ([TIM-206], [TIM-423]) |
| W4:LONG-field | `LONG`/`ULONG` in a struct | `windows.h` `typedef long LONG`; same size hazard as W1 |
| W5:HRESULT-field | `HRESULT` in a struct | `windows.h` `typedef long HRESULT`; 8 bytes on LP64 |
| W6:ptr-to-long-cast | `(long)somePtr` | On Win32 `sizeof(long)==sizeof(void*)==4`; semantically fragile on LP64 |

## False positives and exclusions

The script excludes `linux/win32-stubs/` by default — those files intentionally
use `long` to match Win32 ABI names. MEMCHECK.H (a third-party debug library)
is also excluded.

Remaining known noise:

- **BLOWFISH.H `unsigned long` P-arrays and S-boxes**: On LP64 the Blowfish
  S-box additions can carry into bit 32, producing different ciphertext than the
  Win32 binary.  The algorithm is self-consistent within the Linux build (saves
  are portable within a single platform).  Cross-platform save compatibility is
  not a goal of this port; no fix required.  Documented in the source file.
  ([TIM-633])

- **LZOCONF.H `lzo_uint` / `lzo_int`**: LZO defines these as `unsigned long` /
  `long` via an ULONG_MAX ladder.  On LP64 `lzo_uint` is 8 bytes, which is
  correct for a 64-bit host but differs from the Win32 ABI.  Audit the LZO
  call sites if mixing compressed streams between platforms.

## Workflow: port checklist integration

Add to your per-port pre-boot checklist (see `docs/emscripten-playbook.md`):

1. Run `python3 scripts/lint-lp64.py --errors-only` — all errors must be zero.
2. Review W1/W3 warnings in any new header files added to the port.
3. After fixing a `typedef long` (E1), run `scripts/probe-layout.cpp` to verify
   struct sizes match the Win32 reference values.

[TIM-173]: /TIM/issues/TIM-173
[TIM-202]: /TIM/issues/TIM-202
[TIM-206]: /TIM/issues/TIM-206
[TIM-241]: /TIM/issues/TIM-241
[TIM-242]: /TIM/issues/TIM-242
[TIM-243]: /TIM/issues/TIM-243
[TIM-423]: /TIM/issues/TIM-423
[TIM-453]: /TIM/issues/TIM-453
[TIM-633]: /TIM/issues/TIM-633
