# Command & Conquer: Remastered Collection — Linux Port

This is an ongoing Linux port of **Command & Conquer: Remastered Collection** (TiberianDawn + RedAlert) from the [EA open-source release](https://github.com/electronicarts/CnC_Remastered_Collection). The upstream repo ships only an MSBuild/MSVC solution targeting Win32; this fork brings both games to a native Linux build using GCC/Clang, CMake, and SDL2.

> **Note — related EA repositories:**
> EA released three separate C&C source repositories that are easy to confuse:
>
> | Repo | Contents | Relationship to this fork |
> |---|---|---|
> | [electronicarts/CnC_Remastered_Collection](https://github.com/electronicarts/CnC_Remastered_Collection) | TiberianDawn.dll + RedAlert.dll plugin sources for the **2020 Remastered Collection** | **Upstream of this fork** |
> | [electronicarts/CnC_Red_Alert](https://github.com/electronicarts/CnC_Red_Alert) | Standalone **original 1996 Red Alert** source (Win32 game) | Separate project — not related to this fork |
> | [electronicarts/CnC_Tiberian_Dawn](https://github.com/electronicarts/CnC_Tiberian_Dawn) | Standalone **original 1995 Tiberian Dawn** source (MS-DOS game) | Separate project — not related to this fork |

> **Current status:** The game runs to completion on Linux. A release build sustains ~12 fps, navigates 12 win/loss cycles, and exits cleanly. ASAN-clean. The full rendering pipeline — title screen, main menu, sidebar, radar, tactical map, units — works end-to-end.

---

## What was done

### Phase 1 — Toolchain bootstrap (TIM-3 to TIM-5)

A CMake build system was added alongside the upstream MSVC solution. A `hello_linux` smoke target proved the toolchain (CMake ≥ 3.20, g++ 14 / clang++ 19, C++17) before any game source was touched.

### Phase 2 — Win32 shim layer (TIM-6 to TIM-65)

The Red Alert source was written against Win32/MSVC and assumes a 32-bit ABI throughout. Getting it to compile on 64-bit Linux required building a compatibility shim layer under `linux/win32-stubs/`:

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
- **Release smoke test: TIM-316 / pass-94** — 12.1 fps, 12 win/loss cycles, 0 crashes, ASAN-clean

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

## Building on Linux

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

You need legally-acquired Red Alert game data. Point the binary at your data directory:

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

A `flake.nix` is provided for Nix users on x86_64-Linux.

### One-liner run

```bash
# From a directory containing your Red Alert game data (MAIN.MIX etc.):
cd /path/to/red-alert-data
nix run github:owner/repo

# Or set the data path explicitly:
RA_DATA_DIR=/path/to/red-alert-data nix run github:owner/repo
```

The game data is **not** included — you must supply legally-acquired files
(MAIN.MIX, REDALERT.MIX, and supporting MIX files).

### Contributors — drop into a build shell

```bash
git clone https://github.com/owner/repo && cd repo
nix develop
# Now cmake, gcc, clang, SDL2, python3 etc. are all on PATH:
cmake -S . -B build && cmake --build build -j$(nproc)
# Or run the full RA smoke-test script:
bash scripts/first-run-pass-94.sh
```

### Build the binary without entering the shell

```bash
nix build github:owner/repo
# Binary lands at ./result/bin/redalert
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

Two other community projects have done similar Win32→Linux/cross-platform porting of the C&C engine:

- **[Vanilla-Conquer](https://github.com/TheAssemblyArmada/Vanilla-Conquer)** — a unified cross-platform port of Tiberian Dawn and Red Alert from the EA open-source release; targets Linux, macOS, and Windows with CMake + SDL2/OpenAL. The most mature community port and the closest analogue to this work.

- **[Chronoshift](https://github.com/TheAssemblyArmada/Chronoshift)** — a clean-room reimplementation of Red Alert from the ground up; uses the open-source release as a reference but rewrites the engine rather than porting the original source. More ambitious in scope; slower to reach playability.

This fork differs in approach: it ports the **original EA source** with minimal changes, using conditional compilation to preserve the upstream MSVC path, and advances through automated smoke-test gates rather than a top-down rewrite plan.

---

## License

GPL v3 with EA additional terms. See [LICENSE.md](LICENSE.md).

---

---

# Original README

# Command & Conquer Remastered Collection

This repository includes source code for TiberianDawn.dll, RedAlert.dll and the Map Editor for the Command & Conquer Remastered Collection. This release provides support to the [Steam Workshop](https://steamcommunity.com/workshop/browse/?appid=1213210) for the C&C Remaster Collection.


## Dependencies

The following dependencies must be installed to successfully build the solution;

- Windows 8.1 SDK
- MFC for Visual Studio C++ 


## Compiling (Win32 Only)

To use the compiled binaries, you must own the game. The C&C Remastered Collection is available for purchase on [EA App](https://www.ea.com/games/command-and-conquer/command-and-conquer-remastered/buy/pc) or [Steam](https://store.steampowered.com/app/1213210/Command__Conquer_Remastered_Collection/).

The quickest way to build all configurations in the project is open [CnCRemastered.sln](CnCRemastered.sln) in Microsoft Visual Studio (we recommend using 2017 as later versions report an error due to a packing mismatch with the Windows SDK headers) and select "Build" from the toolbar, then select "Batch Build". Click the "Select All" button, then click the "Rebuild" button.

When the solution has finished building, the compiled binaries can be found in the newly created `bin` folder in the root of the repository.


## Contributing

This repository will not be accepting any contributions (pull requests, issues, etc). If you wish to create changes to the source code and encourage collaboration, please create a fork of the repository under your GitHub user/organization space.


## Support

This repository is for preservation purposes only and is archived without support. 


## License

This repository and its contents are licensed under the GPL v3 license, with additional terms applied. Please see [LICENSE.md](LICENSE.md) for details. 
