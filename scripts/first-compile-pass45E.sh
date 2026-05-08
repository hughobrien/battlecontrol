#!/usr/bin/env bash
# TIM-149 pass-45E: main() entry point, Confine_Rect C++ body, link stubs.
#
# Baseline: pass-45D tip (commit e4c9401) — floor 301/0/301.
# Pass-45E must keep that floor unchanged.
#
# === Diff vs pass-45D ===
#
# (1) MODIFIED REDALERT/STARTUP.CPP:
#       * Changed `#ifdef WIN32` guards around DLL_Startup / main() to
#         `#if defined(WIN32) && defined(_MSC_VER)`. Rationale: wwstd.h:46
#         pre-defines WIN32=1 for any TU transiting wwlib32.h (documented
#         in project memory), so the original guard made STARTUP.CPP export
#         DLL_Startup instead of main() on GCC/Linux.
#       * Added `#if defined(WIN32) && !defined(_MSC_VER)` block below the
#         MSVC-only command-line parsing section: provides `instance` and
#         `command_show` local variables consumed by the shared window/audio
#         init block that follows (Create_Main_Window, etc.).
#       * `getch()` error-path call now compiles via the new conio.h stub.
#
# (2) MODIFIED REDALERT/WIN32LIB/DrawMisc.cpp:
#       * `Confine_Rect`: under #ifndef _MSC_VER, added a C++ replacement
#         for the MASM body that was removed in TIM-124. Clamps the rectangle
#         (x,y,w,h) to fit within (0,0,width,height), returns 1 if adjusted.
#
# (3) MODIFIED linux/win32-stubs/conio.h:
#       * Added `getch()` inline stub: maps to `getchar()`. Used by
#         STARTUP.CPP DOS error-path branches that print a prompt and
#         wait for a keypress before exiting.
#
# (4) MODIFIED linux/win32-stubs/stop-execution-stub.cpp:
#       * Added `DLL_Startup(const char*)` NOP body. DLLInterface.cpp and
#         DLLInterfaceEditor.cpp retain extern+call sites for this symbol;
#         on Linux the standalone binary never invokes them, but the linker
#         requires the symbol to be present. Returns 0.
#
# (5) MODIFIED scripts/first-link-pass-157.sh:
#       * Added skip rule for REDALERT/STUB.CPP: it contains a competing
#         DOS-era `main()` that conflicts with STARTUP.CPP's `main()` in the
#         link. It is excluded from the Linux object set.
#
# === Why this is the right next step ===
#
# Per the runtime-path-survey §1 ("First-runtime-exercise gating"): the
# smallest post-link step toward a runnable binary is ensuring STARTUP.CPP
# exports main(). Without this pass, the Linux link produces DLL_Startup
# rather than main() — ld produces "undefined reference to main" at link
# time and the binary cannot be invoked. Pass-45E closes that gap and
# makes the first link attempt to produce redalert.elf viable.
#
# The DLL_Startup stub and STUB.CPP skip are companion link fixes required
# for a clean link — DLLInterface call sites resolve, and the duplicate
# main() from STUB.CPP is excluded.
#
# === Cascade-stop expectations ===
#
# Target: floor unchanged at 301/0/301. The changes to STARTUP.CPP and
# DrawMisc.cpp are both in the floor source set.
# Spot-check: STARTUP.CPP and DrawMisc.cpp must stay OK.
#
# Realistic ceiling: 301/0/301. The STARTUP.CPP change is a guard
# refinement; the DrawMisc.cpp change adds a function body under
# #ifndef _MSC_VER that replaces an empty body — both trivially type-check.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45E.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45E.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45E.attribution.txt"

mkdir -p "$LOG_DIR"

SHIM_LOCK="$LOG_DIR/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -std=c++17
    -fsyntax-only
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    -include "$STUB_DIR/msvc-compat.h"
)

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0

{
    echo "# TIM-149 first compile attempt -- pass 45E (main() entry point + Confine_Rect body + link stubs)"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files (REDALERT/ + WIN32LIB/)"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$LOG_FILE"

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    tu_log="$(mktemp)"

    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$LOG_FILE"

    if "$CXX" "${CXXFLAGS[@]}" "$src" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$SUMMARY_FILE"
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$SUMMARY_FILE"
        primary=$(grep -m1 -E ': (fatal error|error):' "$tu_log" || true)
        if [[ -n "$primary" ]]; then
            echo "$rel -> $primary" >> "$ATTRIB_FILE"
        else
            echo "$rel -> (no diagnostic captured)" >> "$ATTRIB_FILE"
        fi
    fi

    cat "$tu_log" >> "$LOG_FILE"
    rm -f "$tu_log"
done

include_misses=$(grep -cE "fatal error: .*: No such file or directory" \
    "$LOG_FILE" || true)

{
    echo
    echo "----- totals -----"
    echo "ok:                  $ok"
    echo "fail:                $fail"
    echo "total:               $total"
    echo "include-not-found:   $include_misses"
} | tee -a "$SUMMARY_FILE" >> "$LOG_FILE"

echo "Log:        $LOG_FILE"
echo "Summary:    $SUMMARY_FILE"
echo "Attribution: $ATTRIB_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
