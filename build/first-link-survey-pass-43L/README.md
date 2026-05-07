# TIM-140 pass-43L: link-side residual classification

Read-only forensic survey. No engine source / shim / build-flag edits.

## Inputs

- Master tip at survey time: commit `5b27958` (TIM-138 pass-40AP, OK 300 / FAIL 1 / Total 301).
- Sole compile FAIL: `REDALERT/WIN32LIB/DDRAW.CPP` — owned by WineExpert under [TIM-139](/TIM/issues/TIM-139). Skipped by this survey.

## Method

1. `scripts/first-link-survey-pass-43L.sh` re-runs the same compile pipeline (include-shim + flags) against every `*.cpp` under `REDALERT/` and `REDALERT/WIN32LIB/`, swapping `-fsyntax-only` for `-c` so each TU emits an object file.
2. The 300 OK TUs are linked bare (no `-l` flags) with `g++ -no-pie -fuse-ld=bfd` to surface the unresolved-symbol set.
3. A second permissive pass with `-Wl,--allow-multiple-definition -Wl,--warn-unresolved-symbols` enumerates the *full* undefined set (otherwise bfd bails after the first wave).
4. `scripts/first-link-survey-pass-43L-classify.sh` cross-references each undef symbol against `linux/win32-stubs/` (decl probe) and `REDALERT/*.cpp` (def probe) to assign L1..L5.
5. `/tmp/guard-probe.sh` (run inline; output stored as `guard-probe.txt`) walks each candidate def back through enclosing `#ifdef` directives so we can distinguish "no body anywhere" from "body exists but TU-elided behind `#ifdef WIN32`."

## Files

- `compile.log`, `compile-status.txt` — per-TU `-c` compile result; 300 OK / 0 FAIL / 1 SKIP (DDRAW).
- `link.log` — strict link (bfd, no extra flags). Stops on first wave of multi-defs (27 sites).
- `link-multidefok.log` — strict undef, permissive multi-def. 184 undef sites.
- `link-warnonly.log` — full undef enumeration (warnings, rc=0). Source of `undef-symbols-all.txt`.
- `link.invocation.txt` — exact `g++` link command + flag set.
- `objects.list` — the 300 `.o` paths fed into the link.
- `undef-symbols-all.txt` — 57 unique unresolved symbols.
- `multidef-symbols.txt` — 23 unique multi-defined symbols.
- `classified.txt` — per-symbol group / ref-site / TU count.
- `guard-probe.txt` — per-symbol enclosing-`#ifdef` analysis.
- `histogram.txt` — group totals (also reproduced below).

## Histogram

| Group | Unique symbols | Reference sites | Description |
|------:|---------------:|----------------:|-------------|
| L1    | 4              | 8               | True missing system lib (oleaut32 SafeArray*, kernel32 GetSystemTimeAsFileTime). |
| L2    | 0              | 0               | Pure shim-decl-no-body — none in the current undef set. |
| L3    | 23             | 27              | Multiple-definition / ODR violations. Four file-pair clusters (see below). |
| L4    | 35             | 87              | Engine symbol with no defined body in the linked .o set. **~31 of these have bodies in source that are silently TU-elided behind `#ifdef WIN32`** (see "elision iceberg" below); the remaining ~4 are truly bodyless. |
| L5    | 9              | 41              | DDRAW family — expected; covered by [TIM-139](/TIM/issues/TIM-139). |

Total link errors: 27 multi-def + 184 undef = **211 sites across 80 unique symbols** (excluding L5). DDRAW family adds 9 more unique symbols / 41 sites — these are expected gaps.

## L3 — multi-def clusters

Four pair-wise duplications. Each is a parallel implementation of the same class/table that the original DOS/Win32 build picked one of; our `*.cpp` glob picks both:

| Cluster | Files | Symbols |
|---------|-------|---------|
| WWKeyboard | `KEY.CPP` vs `KEYBOARD.CPP` | 14 `WWKeyboardClass::*` methods |
| LZWStraw   | `LZWSTRAW.CPP` vs `LZWOTRAW.CPP` | `LZWStraw` ctor/dtor/`Get()` |
| ADPCM tables | `ADPCM.CPP` vs `DTABLE.CPP` / `ITABLE.CPP` | `DiffTable`, `IndexTable` (data) |
| TickCount  | `TIMERINI.CPP` vs `GLOBALS.CPP` | `TickCount` (data) |

Fix shape: pick one TU per pair and exclude the other from the build's source glob. Mechanical, low cascade risk.

## L4 — the elision iceberg

The dominant story. `-fsyntax-only` accepts an empty TU as valid syntax, so any `.cpp` whose body is wrapped in `#ifdef WIN32` scored as compile-OK in pass-40AP — but at link time produces zero defined symbols.

Confirmed by `nm --defined-only` against the survey's `.o` files:

| TU | top-level guard | defined symbols in `.o` |
|----|----------------|-------------------------:|
| `REDALERT/TCPIP.CPP` | `#ifdef WIN32` (lines 56–906, whole body) | **0** |
| `REDALERT/INTERNET.CPP` | `#ifdef WIN32` (line 50) | **0** |
| `REDALERT/STATS.CPP` | `#ifdef WIN32` (line 41) | **0** |
| `REDALERT/CCDDE.CPP` | `#ifdef WIN32` (line 52) | **0** |
| `REDALERT/NETDLG.CPP` | partial `#ifdef WIN32` blocks | 28 (partial) |
| `REDALERT/NULLDLG.CPP` | partial `#ifdef WIN32` blocks | 23 (partial) |
| `REDALERT/DLLInterface.cpp` | partial `#ifdef WIN32` blocks | 638 (mostly emitted) |

That single `#ifdef WIN32` pattern accounts for ~31 of the 35 L4 symbols and ~80% of the unresolved sites: `TcpipManagerClass::*` (8), `Winsock`, `Server`, `ConnectionLost`, `PacketLater`, `Send_Statistics_Packet`, `GameStatisticsPacketSent`, `Register_Game_Start_Time`, `Register_Game_End_Time`, `Read_Game_Options`, `Spawn_WChat`, `SpawnedFromWChat`, `PlanetWestwood{IPAddress,IsHost,PortNumber}`, `Check_From_WChat`, `DDEServer`, `DDEServerClass::*` (5), `Send_Data_To_DDE_Server`, `Net_Reconnect_Dialog`, `Reconnect_Modem`, `MainWindow`, `ShowCommand`, `Stop_Execution`, `GetGameDef`, `LPCGetMPAddr`.

The truly bodyless residual (~4 symbols / ~5 sites): `Buffer_Frame_To_Page`, `Buffer_Print`, `Buffer_To_Buffer`, `LCW_Comp` (WIN32LIB asm primitives never ported), `Detect_MMX_Availability` / `CPUType` / `VendorID` (CPU-detect inline asm), `vtable for TurretClass` (missing virtual destructor body).

## Top-3 next-umbrella recommendations

### A. WIN32-elision survey + selective enable  *(forensic, high information return)*
- **What:** Inject `-D_LINUX_PORT` (or carve the right macro shape) into the include shim so the four whole-body `#ifdef WIN32` TUs (TCPIP, INTERNET, STATS, CCDDE) and the partial ones (NETDLG, NULLDLG) actually compile their bodies. Run a fresh first-compile pass (call it 43M) and capture the resulting per-TU error count.
- **Why first:** ~80% of the link-side residual is hidden behind these guards. We currently don't know whether enabling them produces ~50 new compile errors (cluster-friendly) or ~800 (whole-substrate rewrite). The survey *answers the roadmap question*.
- **Cascade risk:** HIGH for compile floor (300 → likely 290–294 in the short term as enabled bodies surface fresh errors). Zero risk to existing OK TUs that don't transit `WIN32`-guarded headers.
- **Owner shape:** FoundingEngineer (forensic pass), then split outputs to StaffEngineer per-TU.
- **Cost:** 1 macro injection in `scripts/generate-include-shim.py`, 1 pass run, 1 attribution table.

### B. L3 dedup — exclude duplicate parallel impls  *(cheap mechanical, bundled)*
- **What:** Update `SOURCES=( … )` glob (or per-pass exclusion list) to drop one of each pair: `KEY.CPP`, `LZWOTRAW.CPP`, plus a decision on `DTABLE.CPP`/`ITABLE.CPP` vs the inline tables in `ADPCM.CPP`, plus `TickCount` ownership between `TIMERINI.CPP` and `GLOBALS.CPP`. Re-run the link survey, expect L3 to drop to 0.
- **Why now:** Independent of A, low cascade risk, eliminates 27 link errors in one PR. Sets the precedent for build-time TU exclusions.
- **Cascade risk:** LOW. The four clusters don't interact. A single re-link verification proves the change.
- **Owner shape:** StaffEngineer. Clear success criterion ("`grep -c 'multiple definition' link.log == 0`").
- **Cost:** 4 file exclusions + 1 link verification. Half a pass.

### C. L1 tactical + L4-truly-bodyless stubs  *(focused, unblocks DLLInterfaceEditor + renderer asm seam)*
- **What:** Two thin C bodies and one stub layer:
  - `linux/win32-stubs/oleaut32-stub.cpp`: `SafeArrayCreate / SafeArrayAccessData / SafeArrayUnaccessData` returning `S_OK` with a malloc'd `SAFEARRAY` shape (used only by `DLLInterfaceEditor.cpp` editor RPC).
  - `linux/win32-stubs/kernel32-stub.cpp`: `GetSystemTimeAsFileTime` from `clock_gettime(CLOCK_REALTIME)`.
  - `linux/win32-stubs/wwlib-asm-stub.cpp`: no-op bodies for `Buffer_Frame_To_Page`, `Buffer_Print`, `Buffer_To_Buffer`, `LCW_Comp`, `Detect_MMX_Availability`, `CPUType`, `VendorID`. These are renderer/CPU-detect asm primitives; runtime correctness is umbrella D territory, but the link-time gap is closeable now.
  - `vtable for TurretClass`: add an out-of-line virtual dtor in `TURRET.CPP` (or wherever the class lives).
- **Why third:** L1 + L4-true together total only ~13 sites — small impact, but they unblock a clean link binary that exercises everything *except* the elided substrate, which is exactly what we want as a measurement baseline once umbrella A reports back.
- **Cascade risk:** LOW. New stub files with no engine includes can't regress compile floor.
- **Owner shape:** StaffEngineer; pilot the TurretClass vtable, then sweep.
- **Cost:** ~3 small new stub files + 1 engine-source vtable plug.

DDRAW (L5, 9 symbols / 41 sites) explicitly stays with WineExpert under [TIM-139](/TIM/issues/TIM-139). Once the native vs Wine path lands there, those symbols resolve as a unit.

## Roadmap verdict

**We are not one cluster from a runnable binary.** Order-of-magnitude estimate of the link-side residual surface:

- **Visible today:** 80 unique unresolved symbols (excluding L5), 211 link error sites.
- **Hidden behind `#ifdef WIN32`:** the entire network (TCPIP), internet/multiplayer (INTERNET), telemetry (STATS), and inter-process-comm (CCDDE) substrate, plus partial slabs of NETDLG/NULLDLG/DLLInterface. By analogy with the cluster-A through cluster-H sweep (which moved compile-floor 0 → 300 over passes 25–42AP), I expect umbrella A to surface **300–800 new compile errors** in this network/IPC subtree — a comparable 4–6-week effort.
- **Beyond that:** DDRAW substrate (TIM-139, native-or-Wine decision), audio substrate (DSAUDIO/SOSAUDIO not yet linked), input substrate (DirectInput shim coverage unverified), window/event-loop (no `WinMain`-replacement entry yet — `STARTUP.CPP` has `int main` but `MainWindow` and `ShowCommand` are unresolved).

Think of compile-floor 300/301 as having gotten the **headers and grammar layer** through the toolchain. The **bodies of the network/stats/IPC subtree are still at compile-floor 0** — we've just been blind to that because `-fsyntax-only` accepts empty TUs as valid.

Distance to runnable: **2 more umbrella waves at minimum** —
1. Umbrella A → re-enter compile-floor work for the WIN32-substrate subtree (estimated 300–800 errors to grind through).
2. Umbrella D-class (substrate runtimes): DDRAW via TIM-139, plus audio + input + window/event-loop. Each of those is itself a small cluster, but they're independent of A, so they can run in parallel under separate engineer ownership once A surfaces the per-TU shape.

**Recommended dispatch order:** B (cheap, instant L3 cleanup) and A (the big information return) in parallel; C as a follow-up once A's compile-floor regression has stabilized so the new stub linkage doesn't get unmasked under whatever WIN32 branch surfaces next.
