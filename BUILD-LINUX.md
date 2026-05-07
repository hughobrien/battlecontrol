# Building on Linux

This is the in-progress Linux port of [Command & Conquer: Red Alert](https://github.com/electronicarts/CnC_Remastered_Collection). Upstream ships only an MSBuild/MSVC build for Windows; this document covers the Linux toolchain bootstrap.

> **Status (TIM-3):** the toolchain is wired up and proven end-to-end with a smoke-test executable (`hello_linux`). The full RedAlert tree does **not** build yet — that is the next ticket (TIM-4).

## Verified host

The commands below were run against:

- Debian GNU/Linux 13 (trixie), x86_64
- `g++ (Debian 14.2.0-19) 14.2.0` (primary)
- `clang++ 19.1.7` (secondary, also verified)
- `cmake 3.31.6`
- `GNU Make 4.4.1`

Other modern Linux distros (Ubuntu 24.04+, Fedora 40+, Arch) should work as long as the version pins below are satisfied.

## Toolchain choices

| Decision | Choice | Rationale |
|---|---|---|
| Build system | **CMake (>= 3.20)** | Cross-platform, generator-agnostic (Make/Ninja), trivial IDE integration via `compile_commands.json`, native `find_package` support for SDL2/OpenAL/etc. once we add subsystem deps. CMake also runs out-of-tree, which keeps the upstream EA source layout untouched. |
| Compiler (primary) | **g++ 14** | Default on Debian 13 / Ubuntu 24.04. C++17 fully supported. |
| Compiler (secondary) | **clang++ 19** | Used as a second opinion for warnings and to keep the codebase compiler-agnostic. |
| C++ standard | **C++17** | Sufficient for the planned shim layer (`std::filesystem`, `std::string_view`, `std::optional`). The upstream is C++03-era — we don't need anything newer than 17. |
| Target ABI | **x86_64 / LP64** | Modern Linux. Note: this exposes `sizeof(long) == 8`, which is exactly the landmine flagged in the [TIM-2 porting brief](#) — the upstream Win32 source assumes `DWORD == 32 bits` regardless. The compat shim (TIM-4+) must lock `DWORD` at `uint32_t`. |

If a dep is ambiguous (e.g. SDL2 vs SDL3, OpenAL vs PulseAudio): we will pick **SDL2** for graphics+audio+input and revisit only if it blocks us. SDL2 is in every distro, has stable Linux packaging, and the porting brief assumes it.

## Install build prerequisites

### Debian / Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y build-essential g++ cmake git
# Secondary compiler (optional):
sudo apt-get install -y clang
```

### Fedora

```bash
sudo dnf install -y @development-tools gcc-c++ cmake git
sudo dnf install -y clang     # optional
```

### Arch

```bash
sudo pacman -S --needed base-devel gcc cmake git
sudo pacman -S --needed clang  # optional
```

## Clean-checkout walkthrough

The following sequence takes a fresh machine to a successful smoke-test build:

```bash
git clone https://github.com/electronicarts/CnC_Remastered_Collection.git
cd CnC_Remastered_Collection

# Configure (out-of-tree build into ./build)
cmake -S . -B build -G "Unix Makefiles"

# Compile
cmake --build build -j

# Run the smoke test
./build/hello_linux
```

Expected output (gcc 14 on x86_64 Linux):

```
CnC RedAlert Linux toolchain smoke test
  __cplusplus       : 201703
  compiler          : gcc 14.2.0
  sizeof(void*)     : 8
  sizeof(long)      : 8
  sizeof(long long) : 8
  sizeof(int)       : 4
Toolchain OK.
```

`Toolchain OK.` on the last line means CMake, the C++17 compiler, and the linker are all wired up correctly.

### Selecting the compiler

To use clang instead of gcc, point CMake at the compiler binary at configure time:

```bash
cmake -S . -B build-clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build-clang -j
./build-clang/hello_linux
```

### Build types

Default is `RelWithDebInfo`. Switch with `-DCMAKE_BUILD_TYPE=Debug` (or `Release`):

```bash
cmake -S . -B build-debug -DCMAKE_BUILD_TYPE=Debug
cmake --build build-debug -j
```

### Faster builds with Ninja (optional)

```bash
sudo apt-get install -y ninja-build
cmake -S . -B build -G Ninja
cmake --build build
```

## What's in this build today

Only the `hello_linux` smoke target. It exists to prove:

- CMake configures cleanly on Linux.
- The selected compiler accepts C++17 (`__cplusplus == 201703`).
- The link step works end-to-end (the executable runs).
- The host ABI is LP64 (informs the compat shim work in TIM-4).

It does **not** compile any upstream RedAlert source. That is intentional and is the goal of the next ticket.

## Not yet supported / next steps

The upstream `REDALERT/` tree depends on Windows-only APIs (DirectDraw, DirectSound, Win32 messaging, Winsock, MFC resource scripts, MSVC inline assembly, MASM). Bringing it to a clean compile on Linux is tracked in **TIM-4** and follow-ups: it requires a Win32 type shim, a CRT shim, replacement of inline `__asm` blocks with portable C++, and SDL2-backed graphics/audio/input subsystems. See the TIM-2 porting brief for the full plan.

## Game data and licensing

This repository contains source code only. The repo's `LICENSE.md` (GPL v3 with EA additional terms) covers the source. Running the eventual port requires legally-acquired Red Alert game data files; **do not commit any game assets, MIX files, MSVC redistributables, or other binaries to this repo.**
