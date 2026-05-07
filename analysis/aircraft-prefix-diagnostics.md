# TIM-50 Pass-25 Chain Audit: Shared Prefix Diagnostic List

## Method

- Canonical TU: `REDALERT/AIRCRAFT.CPP`.
- Compile flags: same as pass-24 harness (`-std=c++17 -fsyntax-only -fno-strict-aliasing -w -include msvc-compat.h`).
- Capture: `-fmax-errors=200`, full diagnostic stream → `analysis/aircraft-diagnostics.txt`.
- Include graph: `g++ -E -H` → `analysis/aircraft-include-graph.txt` (390 entries).

"Prefix" = diagnostics that fire before any AIRCRAFT.CPP-specific code (i.e. inside an included header, not inside AIRCRAFT.CPP itself).

## Spot-check confirming cohort prefix

Same flags, four other 179-bucket TUs, top diagnostics only:

| TU             | First prefix diag                              | First post-prefix diag                                  |
| -------------- | ---------------------------------------------- | ------------------------------------------------------- |
| AIRCRAFT.CPP   | function.h:601 `expected initializer before 'Dialog_Message'` | AIRCRAFT.CPP:2136 `'min' was not declared`              |
| CONFDLG.CPP    | function.h:601 (same)                          | (no further diagnostics in this -fmax-errors=5 sample)  |
| 2KEYFRAM.CPP   | function.h:601 (same)                          | 2KEYFRAM.CPP:136 `cast from 'char*' to 'unsigned int'`  |
| AADATA.CPP     | function.h:601 (same)                          | AADATA.CPP:421 `'_makepath' was not declared`           |
| ABSTRACT.CPP   | function.h:601 (same)                          | (no further diagnostics in this -fmax-errors=5 sample)  |

**Key finding: there is exactly ONE diagnostic in the shared 179-TU prefix.** Post-prefix diagnostics already differ per TU — the cohort is held together solely by this single bucket. Clearing it will fragment the cohort.

## The Prefix Diagnostic List (n=1)

| # | file:line              | Class              | Snippet                                       | Proposed fix                                                                 | Cost |
| - | ---------------------- | ------------------ | --------------------------------------------- | ---------------------------------------------------------------------------- | ---- |
| 1 | `REDALERT/FUNCTION.H:601` (via shim) | Keyword macro / lowercase Win16 calling-convention | `int cdecl Dialog_Message(char *errormsg, ...);` | Add `#define cdecl` (empty) to `linux/win32-stubs/msvc-compat.h`, mirroring the TIM-29 fix for bare `far`/`near`/`pascal`. | 1-line shim |

### Why this is safe

- TIM-29 already shimmed bare `far`/`near`/`pascal` for the same reason: MSVC silently accepts these as legacy calling-convention/pointer qualifiers; g++ does not.
- 44 occurrences of bare `cdecl` exist across `REDALERT/`. All are calling-convention qualifiers on declarations / definitions in:
  - `.ASM` files (not compiled by g++) — irrelevant.
  - C++ headers and sources: `MEMCHECK.H`, `WWALLOC.H`, `CDFILE.CPP`, `WIN32LIB/GETSHAPE.CPP`, `WIN32LIB/DrawMisc.cpp`, `FUNCTION.H`. Every site is `<type> cdecl <ident>(...)`.
- `MEMCHECK.H:376` already does `#define cdecl` itself in its own conditional block, confirming this is the upstream-intended treatment on non-Borland targets.
- No use of `cdecl` as an identifier anywhere — define-as-empty is non-disruptive.
- Sister macros (`__cdecl`, `_cdecl`, `CDECL`) are already defined empty in `msvc-compat.h`. `cdecl` (bare) is the only spelling that was missed.

### Cascade-boundary check

This is a 1-line shim. Zero header restructuring, no shadow-shadowed includes touched, no engine class stubbed. Stays well inside the TIM-50 scope boundaries.

### Shadow-shadow audit (along the prefix)

The pass-25 audit included a walk of the post-shim include graph for AIRCRAFT.CPP (390 entries). No additional shadow-shadowed headers found beyond the TIM-49 `MOUSE.H` case along the diagnostic-active prefix path. The COM-stub graph (`objbase.h`/`dsound.h` interaction from TIM-47) compiled cleanly through the preprocessor.

## Verdict (pre-pass)

The 12-pass plateau at OK=95 is explained by the prefix consisting of exactly one diagnostic: each prior fix walked the prefix one bucket at a time, and the cohort never fragmented because the next-in-line diagnostic was always shared. Pass-25 should fragment the cohort because post-`cdecl` first errors are already TU-specific (per the spot-check above).
