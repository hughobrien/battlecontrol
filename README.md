# battlecontrol

## Play in Browser

**[▶ Play RA](https://hughobrien.github.io/battlecontrol/ra.html)** &nbsp;|&nbsp; **[▶ Play TD](https://hughobrien.github.io/battlecontrol/td.html)**

No installation needed. You need legally-acquired game data — click **Open Game Folder** and select your local data directory. Works in any browser with [SharedArrayBuffer support](https://caniuse.com/sharedarraybuffer) (Chrome, Edge, Firefox).

![TD gameplay in browser](https://hughobrien.github.io/battlecontrol/screenshots/td-gameplay.png)

---

## v0.3 Release Notes

### What's included

| | Browser (WASM) — **primary deliverable** | Native Linux — CI-packaged, gdb/rr testbed |
|---|---|---|
| **Red Alert** | ✅ **Parity-verified** — Allied L1, Soviet L1 frame-level match against original Wine OG (per-pixel SSIM) | ✅ CI-packaged (`.tar.gz` in every release) |
| **Tiberian Dawn** | ✅ **Parity-verified** — GDI L1 frame-level match against original Wine OG; full campaign-completion smoke | ✅ CI-packaged (`.tar.gz` in every release) |

### What's new in v0.3 (since v0.2)

**Parity validation (all three L1 missions frame-level matched against Wine OG):**
- RA Allied L1 — WASM captures match original Windows binary within per-pixel SSIM tolerance ([TIM-710](/TIM/issues/TIM-710))
- RA Soviet L1 — same frame-level comparison, Soviet faction button coordinate working ([TIM-776](/TIM/issues/TIM-776))
- TD GDI L1 — screenshot comparison at mission start and game-loop frames ([TIM-768](/TIM/issues/TIM-768))
- Automated via `scripts/parity-compare.py` with translation-invariant SSIM ([TIM-797](/TIM/issues/TIM-797))

**CI regression gates (every push):**
- RA WASM boot, main-menu reachable, mission-start, audio-pitch probe ([TIM-773](/TIM/issues/TIM-773))
- TD WASM campaign-completion smoke — plays full GDI campaign to victory VQA ([TIM-774](/TIM/issues/TIM-774))

**Release artifacts (four binaries per release via `release.yml`):**
- RA-Linux, TD-Linux, RA-WASM, TD-WASM — all four packaged and attached to every GitHub release ([TIM-775](/TIM/issues/TIM-775))

**TD native Linux SDL2 rendering:**
- Keyboard/mouse input, 640×480 viewport, full gameplay (equivalent to RA's native path)

**Screenshot infrastructure:**
- `scripts/parity-compare.py` auto-registers new baseline captures with translation-invariant SSIM comparison

### How to play

**Browser (no install):**
1. Visit [▶ Play RA](https://hughobrien.github.io/battlecontrol/ra.html) or [▶ Play TD](https://hughobrien.github.io/battlecontrol/td.html)
2. Click **Open Game Folder** and select your local data directory containing the MIX files
3. The game loads automatically — no server upload, data stays on your machine

**Native Linux binaries** are now CI-packaged as `.tar.gz` downloads from the [GitHub Releases](https://github.com/hughobrien/battlecontrol/releases) page. These are development/testbed builds for debugging and CI — not performance-tuned for end users.

### Known limitations

- **Native Linux builds are developer testbeds, not player deliverables.** The native binaries are CI-packaged for convenience but are not performance-tuned for end users. The browser (WASM) build is the primary deliverable.
- **Save/load not exposed in WASM** — deferred to v0.4.0 (IDBFS persistence)
- **Multiplayer networking** — not implemented
- **Prerequisites**: You must supply legally-acquired game data (MIX files). Game data is not included and cannot be distributed.
- **Browser requirements**: Chrome or Edge (stable) required for SharedArrayBuffer / WASM threads. Firefox works with `dom.postMessage.sharedArrayBuffer.bypassCOOP_COEP.insecure.enabled = true`.

---

## v0.2 Release Notes

### What's included (v0.2)

| | Browser (WASM) — **primary deliverable** | Native Linux — ASAN/GDB/rr testbed |
|---|---|---|
| **Tiberian Dawn** | ✅ Fully playable — game loop, audio, graphics, real font rendering | Not yet |
| **Red Alert** | ✅ Fully playable — unit control, AI, VQA cinematics, audio, full game loop | ASAN-clean testbed (12 fps, 12 win/loss cycles) — for debugging only, not packaged for end users |

### What's new in v0.2 (since v0.1-beta)

**Red Alert WASM** — now fully playable in browser:
- `Start_Scenario` fires correctly; the full mission loop runs in WASM
- Unit selection and movement (left-click select, right-click move order)
- Enemy AI: units patrol, attack, and interact with the player
- VQA cinematics play correctly: skip of hi==0xFF blocks, SND2 IMA ADPCM audio, CPL0 palette fix (no 2-bit shift on 8-bit values)
- WASM audio pitch correct (AudioContext.sampleRate queried before SDL_OpenAudioDevice)

**Tiberian Dawn WASM** — full gameplay audit passed; all e2e specs green.

---

battlecontrol is a Linux and WebAssembly port of the EA-released game engine sources (RA + TD) from the [EA open-source release](https://github.com/electronicarts/CnC_Remastered_Collection). The upstream repo ships only an MSBuild/MSVC solution targeting Win32; this fork brings both games to a native Linux build using GCC/Clang, CMake, and SDL2.

> **Note — related EA source repositories:**
> EA released three separate source repositories that are easy to confuse:
>
> | Repo | Contents | Relationship to this fork |
> |---|---|---|
> | [electronicarts/CnC_Remastered_Collection](https://github.com/electronicarts/CnC_Remastered_Collection) | TiberianDawn.dll + RedAlert.dll plugin sources for the **2020 Remastered Collection** | **Upstream of this fork** |
> | [electronicarts/CnC_Red_Alert](https://github.com/electronicarts/CnC_Red_Alert) | Standalone **original 1996 Red Alert** source (Win32 game) | Separate project — not related to this fork |
> | [electronicarts/CnC_Tiberian_Dawn](https://github.com/electronicarts/CnC_Tiberian_Dawn) | Standalone **original 1995 Tiberian Dawn** source (MS-DOS game) | Separate project — not related to this fork |

> **Current status — v0.3.0:** Both engines are parity-verified against original Windows binaries (Wine OG) for all three L1 missions (RA Allied, RA Soviet, TD GDI). CI regression gates run on every push. Release artifacts include four binaries (RA-Linux, TD-Linux, RA-WASM, TD-WASM). The browser (WASM) build is the primary deliverable; native Linux binaries are CI-packaged development testbeds.

---

## What was done

### Phase 1 — Toolchain bootstrap (TIM-3 to TIM-5)

A CMake build system was added alongside the upstream MSVC solution. A `hello_linux` smoke target proved the toolchain (CMake ≥ 3.20, g++ 14 / clang++ 19, C++17) before any game source was touched.

### Phase 2 — Win32 shim layer (TIM-6 to TIM-65)

The RA source was written against Win32/MSVC and assumes a 32-bit ABI throughout. Getting it to compile on 64-bit Linux required building a compatibility shim layer under `linux/win32-stubs/`:

- **Type taxonomy** — `DWORD`, `WORD`, `BOOL`, `HANDLE`, `HWND`, `HINSTANCE`, and the full Win32 primitive hierarchy shimmed as LP64-safe typedefs
- **Windows.h surface** — `windows.h`, `mmsystem.h`, `winsock.h`, `ddeml.h`, `objbase.h` stubs covering the COM/IUnknown family, WAVEFORMATEX, Winsock 1 types, DDE handles
- **MSVC intrinsics** — `__int64`, `__cdecl`, `far`/`near`/`pascal`, `stricmp`/`strnicmp`, `_stricmp`, `_memicmp`
- **LP64 struct fixes** — ~40 source-level patches replacing `unsigned long` / `long` fields with `uint32_t` / `int32_t` wherever a Win32 struct was packed or serialised (COORDINATE, FTIMER.H, MapClass, ShapeBlock_Type, IControl_Type, CompHeaderType, and many more)
- **Header self-containment** — systematic audit and repair of the include graph so each header compiles stand-alone: ABSTRACT.H, STAGE.H, HOUSE.H, GSCREEN.H, TEMPLATE.H, JSHELL.H, SIDEBAR.H, RADAR.H, AUDIO.H, and the full "Big Six" object hierarchy

Error counts went from ~2 000 at pass-1 down to zero at pass-32.

### Phase 3 — Runtime stubs: ASM, audio, DirectDraw (TIM-100 to TIM-165)

The game's low-level subsystems were originally hand-written x86 assembly or DirectX APIs. Each was replaced with a portable C++ or SDL2 equivalent:

- **ASM stubs** (`TIM-160`, `TIM-164`) — every `ud2`-stubbed function converted to a working portable implementation; `IRANDOM.ASM` ported to C++ (`Random()`, `Get_Random_Mask()`)
- **Audio** (`TIM-148`/`TIM-149`) — `AUDIO.CPP` non-MSVC branch covers SDL2 device/mixer, ADPCM decode, streaming; the full audio substrate is feature-complete
- **DirectDraw / graphics surface** (`TIM-141`) — `DDRAW.CPP` non-MSVC path routes to SDL2; `SDL_SetPaletteColors` wired in; `GameInFocus` flag set correctly on Linux so `Map.Render` fires every frame

### Phase 4 — Link to zero undefined symbols (TIM-150 to TIM-157)

Getting a clean link required:

- Implementing all undefined symbols identified by a survey script (300+ across multiple passes)
- Ordering `-lSDL2` after object files (ld.bfd constraint)
- Removing the single remaining multidef: `TickCount` in `TIMERINI.CPP`

First clean link: **TIM-156 / commit b7a4439**.

### Phase 5 — Init and asset loading (TIM-172 to TIM-202)

- `_splitpath` shim + SHA-1 LP64 fixes got LOCAL.MIX and LORES.MIX loading correctly
- `CompHeaderType` LP64 fix (`int32_t` + packed) resolved a corruption that aborted `Init_Bulk_Data`
- HIRES.MIX nested inside REDALERT.MIX was discovered and cached; TITLE.PCX became accessible
- **First main menu render: TIM-172 / pass-51**

### Phase 6 — Input and scenario launch (TIM-206)

- `Build_Frame` LP64 offset array fix (`unsigned long → uint32_t`)
- `KeyFrameSlots` memset fix (`*4 → *sizeof(char*)`)
- `KF_DELTA` frames: LCW decompression was being called where XOR-delta was correct; fixed
- `IControl_Type` LP64 fix
- Synthetic LCLICK + KN_RETURN injection to navigate menus without `RA_AUTOSTART`
- **Menu navigation milestone: TIM-206 / pass-71** — `Start_Scenario` fires, 1076+ frames logged

### Phase 7 — In-game rendering (TIM-218 to TIM-283)

- `_ShapeBuffer` heap overlap fixed (decompress directly into `BigShapeBuffer`)
- `Buffer_Draw_Stamp_Clip` OOB write fixed (pass-70)
- `Buffer_Frame_To_Page` implemented; sidebar shapes and units became visible (pass-72)
- `HidPage.Lock()` Linux fix; radar cell rendering enabled (pass-76)
- Top bar (`TabClass::Draw_It`) rendering fixed (pass-78)
- Sidebar bottom gap filled with LTGREY at 640×480 (pass-77)
- Tac-bottom frame quality zones audited (pass-79)
- **640×480 full render milestone: TIM-250 / pass-69** — arctic terrain, 23% fill at frame 500

### Phase 8 — Simulation quality and release validation (TIM-283 to TIM-316)

- `RulesClass::Difficulty()` enabled; simulation freeze fixed (pass-81)
- Infantry movement verified; pathfinding and combat resolution audited
- AI mission diversity, building/production pipeline, factory triggers verified
- Allied win condition verified via reinforcement injection
- `MissionControl[-1]` ASAN OOB in TECHNO.CPP / FOOT.CPP fixed (pass-93)
- `AnimClass` pool exhaustion fixed (cycle-3 crash root cause, pass-92)
- **Testbed smoke test: TIM-316 / pass-94** — 12.1 fps, 12 win/loss cycles, 0 crashes, ASAN-clean (FPS is not a target — this is a debugging testbed; performance polish is post-WASM work)

---

## Method

The porting work was driven entirely by **test-driven iteration** at the binary level:

1. **Measure** — a smoke-test script runs the binary under Xvfb, captures frame counts, BMP screenshots, ASAN output, and exit codes
2. **Classify** — the failure mode (compile error, link error, assertion, SIGSEGV, ASAN report, wrong output) determines the next fix
3. **Fix minimally** — one change per commit, with the commit message recording pass number and exact outcome
4. **Gate on evidence** — a milestone is only called done when an automated script produces the expected log lines (e.g. "Map.Render fired", "frame 500 BMP saved", "12 win cycles observed")

Passes are numbered sequentially (pass-1 through pass-94) and each has a corresponding run script in `scripts/` or `SCRIPTS/`. This makes any pass reproducible in isolation.

**LP64 audit approach:** Win32 source uses `long` and `unsigned long` freely, assuming they are 32 bits. On LP64 Linux both are 64 bits. Rather than a blanket search-and-replace, each struct was audited against its serialisation context (MIX headers, save-game format, IPC layout) before any field was changed, to avoid silently shifting offsets.

**No forks of upstream logic:** where possible, fixes are conditional on `!_MSC_VER` or `__linux__` so the Windows build path is preserved intact.

---

## Building on Linux (ASAN/GDB/rr testbed — not a player deliverable)

> **Developer note:** The native Linux build exists as an ASAN/GDB/rr debugging testbed, not as a packaged product for end users. The browser (WASM) build at the top of this README is the deliverable. Use the native build when you need fast iteration under a memory sanitizer, `gdb`, or `rr` (Mozilla's record-and-replay debugger). FPS targets and installer polish are intentionally deferred until post-WASM work is needed.

### Prerequisites

```bash
# Debian / Ubuntu
sudo apt-get install -y build-essential g++ cmake libsdl2-dev xvfb

# Fedora
sudo dnf install -y @development-tools gcc-c++ cmake SDL2-devel

# Arch
sudo pacman -S --needed base-devel gcc cmake sdl2
```

### Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

For a debug + ASAN build:

```bash
cmake -S . -B build-asan \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined"
cmake --build build-asan -j$(nproc)
```

### Run

You need legally-acquired RA game data. Point the binary at your data directory:

```bash
./SCRIPTS/run-release.sh          # or see SCRIPTS/ for the current smoke script
```

Running headless (CI / no display):

```bash
Xvfb :99 -screen 0 1024x768x24 &
DISPLAY=:99 ./redalert
```

---

## Nix

A `flake.nix` is provided for Nix users on x86_64-Linux. This is primarily useful for **contributors and developers** entering the build environment — the native binary is a testbed, not an end-user deliverable. To play the game, use the [browser build](#play-in-browser) above.

### Contributors — drop into a build shell

```bash
git clone https://github.com/hughobrien/battlecontrol && cd battlecontrol
nix develop
# cmake, gcc, clang, SDL2, python3 etc. are all on PATH:
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined"
cmake --build build-asan -j$(nproc)
# Or run the full RA smoke-test script (sets RA_DATA_DIR internally):
bash scripts/first-run-pass-94.sh
```

### Build the testbed binary without entering the shell

```bash
nix build github:hughobrien/battlecontrol
# Testbed binary lands at ./result/bin/redalert (for ASAN/GDB use)
```

### First-time lock-file generation

On a fresh clone, generate the `flake.lock` pin with:

```bash
nix flake lock
```

Commit `flake.lock` to reproduce the exact build environment.

### nixpkgs pin

The flake targets `nixpkgs/nixos-unstable`. The generated `flake.lock` pins
the exact commit; reproducible builds require committing the lock file.

---

## How this was built

The entire porting effort — all ~94 passes from the first compile error to ASAN-clean gameplay — was driven by AI agents orchestrated through **[Paperclip](https://paperclip.ing)**. Paperclip is an AI agent coordination platform that lets you run a company of AI agents to execute multi-step software engineering projects end-to-end. The FoundingEngineer agent (CTO role) carried out the technical work across 300+ tasks, each tracked as a TIM-* issue in the Paperclip project board. No human wrote any of the porting code; the agents planned, implemented, debugged, and verified every change.

---

## Related work

Two other community projects have done similar Win32→Linux/cross-platform porting of the same engine sources:

- **[Vanilla-Conquer](https://github.com/TheAssemblyArmada/Vanilla-Conquer)** — a unified cross-platform port of Tiberian Dawn and Red Alert from the EA open-source release; targets Linux, macOS, and Windows with CMake + SDL2/OpenAL. The most mature community port and the closest analogue to this work.

- **[Chronoshift](https://github.com/TheAssemblyArmada/Chronoshift)** — a clean-room reimplementation of Red Alert from the ground up; uses the open-source release as a reference but rewrites the engine rather than porting the original source. More ambitious in scope; slower to reach playability.

This fork differs in approach: it ports the **original EA source** with minimal changes, using conditional compilation to preserve the upstream MSVC path, and advances through automated smoke-test gates rather than a top-down rewrite plan.

---

## License

GPL v3 with EA additional terms. See [LICENSE.md](LICENSE.md).

---

---

> **Upstream source:** [electronicarts/CnC_Remastered_Collection](https://github.com/electronicarts/CnC_Remastered_Collection)
