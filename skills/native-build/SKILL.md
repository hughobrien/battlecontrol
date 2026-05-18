---
name: native-build
description: Use when compiling C&C Red Alert or Tiberian Dawn for native Linux with GCC/Clang and SDL2. Trigger on symptoms like CMake configuration failures, missing SDL2 headers, case-sensitivity include errors, LP64 struct-layout crashes, link failures with undefined SDL2 symbols, or headless Xvfb rendering problems.
version: 0.1.0
---

# Native Linux Build Skill

> **Nix apps:** `nix run .#build-native`, `nix run .#toolchain-check`.
> Ask the agent to run these instead of typing raw commands.

You are working on the native Linux port of C&C Red Alert or Tiberian Dawn. The build
system uses CMake with Ninja, targets GCC or Clang, and links against SDL2 for graphics,
audio, and input.

Read `ARCH.md` and `BUILD-LINUX.md` for architectural context before starting.

---

## Phase 0 — Verify toolchain

```
toolchain_check()
```

One-command gate. Exits 0 if clang++ (>=19), cmake (>=3.20), ninja, python3, pkg-config, and SDL2 are all present.



---

## Phase 1 — Classify the symptom

| Symptom | Lens | Go to |
|---|---|---|
| `fatal error: 'function.h' file not found` | Case-folding include shim missing/outdated | §2.1 |
| Struct field offsets wrong; sizeof(MyClass) differs from Win32 | LP64 layout hazard | §2.2 |
| `undefined symbol: SDL_*` at link time | Linker order or missing SDL2 | §2.3 |
| Game renders black or blank window on Xvfb | SDL renderer/display setup | §2.4 |
| `WIN32` / `_MSC_VER` preprocessor path wrong | Compile definitions or ODR mismatch | §2.5 |
| MIX files fail to open at runtime | File I/O shim or game-data path | §2.6 |
| `_lrotl` / CRC mismatch or save-file corruption | LP64 `sizeof(long)==8` | §2.2 (E2) |

---

## §2.1 — Case-folding include shim

The upstream source uses mixed-case `#include "FUNCTION.H"` / `#include "function.h"`.
Linux is case-sensitive — these fail without shims.

**Fix:** Run the include shim generator after any header rename or new #include:

```bash
python3 scripts/generate-include-shim.py \
    --repo-root . \
    --shim-root build/include-shim \
    --quiet
```

The shim creates symlinks under `build/include-shim/{redalert,win32lib,tiberiandawn,td-win32lib}/`
mapping every `#include "..."` directive to a lower-cased symlink finding the actual file.

CMakeLists.txt already adds `-I build/include-shim/redalert` etc. to compile flags.

**When to regenerate:** after adding a new `#include` to any .CPP file, after creating a
new header, or after a fresh checkout (the shim is not committed).

---

## §2.2 — LP64 layout hazards

Win32 code assumes `sizeof(long)==4`. On LP64 Linux it is 8. This causes struct-layout
mismatches, binary I/O corruption, and CRC failures.

**Run the audit:**

```bash
python3 scripts/lint-lp64.py --errors-only   # gate: must be zero
python3 scripts/lint-lp64.py                  # review warnings
```

Four error rules (must fix):

| Rule | Pattern | Example bug |
|------|---------|-------------|
| E1: typedef-long | `typedef (unsigned) long NAME` | `COORDINATE` grew 4→8, misaligning every downstream struct |
| E2: _lrotl | `_lrotl` / `_lrotr` | CRC operates on 8 bytes instead of 4 |
| E3: ptr-to-int-cast | `(int)somePtr` | Pointer truncated from 64→32 bits |
| E4: packed-long-field | `long field` in `#pragma pack` | All subsequent fields shift by 4 bytes |

**Common fixes:**

- `typedef unsigned long COORDINATE` → `typedef uint32_t COORDINATE`
- `_lrotl(val, n)` → `_lrotl((uint32_t)(val), n)` (cast to 32-bit before rotate)
- Mixed `ReadFile`/`WriteFile` with `sizeof(long)` → use `sizeof(uint32_t)`
- `lseek(fd, offset, SEEK_SET)` where `offset` is `int`-sized → ensure `off_t` compatible

**After fixing:** run `scripts/probe-layout.cpp` to verify struct sizes match Win32 reference values.

**Known exclusions:** `BLOWFISH.H` P-arrays (self-consistent within Linux), `LZOCONF.H` (correct for 64-bit host), `linux/win32-stubs/` (intentionally uses Win32 ABI names).

---

## §2.3 — Linker order and missing SDL2 symbols

`ld.bfd` resolves symbols left-to-right. System libraries must come after object files.

**Correct (used in CMakeLists.txt):**
```cmake
target_link_libraries(ra PRIVATE $<TARGET_OBJECTS:ra_objects> SDL2)
#                                       ^-- objects first     ^-- libs after
```

If you see `undefined reference to SDL_*`, check that `-lSDL2` appears after all object
files on the link line. Verify `find_package(SDL2 REQUIRED)` succeeded during configure.

---

## §2.4 — SDL rendering on Xvfb

CI runs headless under Xvfb. The renderer uses `SDL_RENDERER_SOFTWARE` (no GPU).

```bash
# Idempotent Xvfb start (reuses existing, kills stale, sets DISPLAY + EXIT trap):
source scripts/xvfb-ensure.sh :99 640x480x24

Xvfb is auto-killed on shell exit via the EXIT trap set by `xvfb-ensure.sh`.

**Palette limitation:** `import -window root` returns blank images when the game uses
8-bit indexed surfaces under Xvfb with some SDL2 backends. For screenshot capture under
Xvfb, use `ffmpeg x11grab` instead.

**Focus-awareness:** The game only renders when the window has focus (tracked via
`SDL_WINDOWEVENT_FOCUS_*`). Under Xvfb without a window manager, the window may never
gain focus — set `SDL_VIDEO_X11_FORCE_EGL=0` or use a window manager like `fvwm`.

---

## §2.5 — Preprocessor paths and ODR violations

Both `ra` and `td` share include paths. Key compile definitions set by CMake:

- `-DLINUX=1 -DUNIX=1 -DPOSIX=1` (both targets)
- `-DWIN32=1` (td only — required because `TIBERIANDAWN/FUNCTION.H` has `WIN32` commented out)

**ODR hazard:** Without `-DWIN32=1`, `RawFileClass::Handle` is typed differently across
translation units in TD (`int` vs `void*`), causing struct-layout mismatch and crashes.

**msvc-compat.h** is force-included ([`-include`] flag) for both targets, providing:

- `_stricmp` → `strcasecmp`, `_strnicmp` → `strncasecmp`
- `_strdup` → `strdup`
- `strupr` / `strlwr` (in-place ASCII case conversion)
- `_splitpath` (POSIX reimplementation)

---

## §2.6 — Game data and MIX file loading

The POSIX file I/O shim (`linux/win32-stubs/posix_fileio.cpp`) implements `CreateFileA`,
`CloseHandle`, `ReadFile`, `WriteFile` over POSIX `open`/`read`/`lseek`.

Game data (`.MIX` files) must be present in the working directory at runtime. Use the
setup scripts to symlink from a game install:

```bash
# For TD:
bash scripts/setup-run-td.sh /path/to/TIBERIAN_DAWN/CD1

# For RA (remastered):
# Symlink CD1 MIX files into build/run-172/
mkdir -p build/run-172
ln -sf /path/to/RED_ALERT/CD1/*.MIX build/run-172/
```

---

## §2.7 — Debugging with sanitizers

Runtime memory errors (use-after-free, buffer overflow) are the most common
native-only failures that LP64 audit cannot catch. Build with sanitizers for
debugging:

```bash
# Configure with AddressSanitizer + UndefinedBehaviorSanitizer
cmake -S . -B build/ra-sanitize \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" \
  -DWIN32=1
cmake --build build/ra-sanitize

# Run — first crash prints a stack trace with line numbers
./build/ra-sanitize/ra
```

**Notes:**
- Sanitizers slow execution ~2× but catch memory errors deterministically.
- `-DWIN32=1` and `-include msvc-compat.h` can mask some sanitizer warnings
  due to the shim layer — add a suppression file if needed
  (`LSAN_OPTIONS=suppressions=lsan-suppressions.txt`).
- If `cmake --preset linux-sanitize` exists in `CMakePresets.json`, use that
  instead of the manual configure above.

---

## §3 — Standard build commands

### One-command build

```
build_native(target: "both", compiler: "gcc")
build_native(target: "ra", compiler: "clang")
```

### Smoke test (RA)

```
nix run .#smoke-ra
```

Expected: All RA sources compile (`grep -c '\.cpp' build/ra/CMakeFiles/ra.dir/src_files.cmake`), link OK, 1000+ frames without crash, ≥1 win cycle, FPS measured.

### Smoke test (TD)

```
nix run .#smoke-td
```

Expected: 10+ frames, cheat milestones pass (credits, tech unlock, map reveal, mission win at frame 200).

---

## §4 — Verification bar

| Gate | Tool / Command | Minimum proof |
|------|----------------|---------------|
| **Configure** | Run `build_native` once or `cmake --preset linux-native` | exits 0 |
| **Build RA** | `build_native(target: "ra")` | All RA sources compile (`grep -c '\\.cpp' build/ra/CMakeFiles/ra.dir/src_files.cmake` units), link exits 0 |
| **Build TD** | `build_native(target: "td")` | All TD sources compile, link exits 0 |
| **LP64 audit** | `nix run .#lint-lp64` | returns 0 |
| **Sanitizer** | `cmake --preset linux-sanitize && ./build/ra` (if preset exists) | No UAF/overflow at startup |
| **Smoke — RA** | `nix run .#smoke-ra` | 1000+ frames stable, ≥1 win, no SIGSEGV |
| **Smoke — TD** | `nix run .#smoke-td` | Cheat milestones pass, no crash |

---

## Reference

- `ARCH.md` — Architecture overview, platform abstraction layer
- `BUILD-LINUX.md` — Toolchain choices, distro-specific setup
- `docs/lp64-audit.md` — LP64 rule reference with bug examples
- `CMakeLists.txt` — Build targets, compile definitions, exclusions
- `CMakePresets.json` — `linux-native` preset
