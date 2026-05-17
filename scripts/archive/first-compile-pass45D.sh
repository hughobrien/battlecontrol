#!/usr/bin/env bash
# TIM-149 pass-45D: SDL input pump fallback in Fill_Buffer_From_System.
#
# Baseline: pass-45C tip (commit d2dcffc) — floor 305/0/308 at master
# tip (ebe43cc, TIM-153 umbrella-A expanded).  Pass-45D must keep that
# floor unchanged.
#
# === Diff vs pass-45C ===
#
# (1) MODIFIED REDALERT/KEY.CPP ONLY:
#       * WWKeyboardClass::Fill_Buffer_From_System(): under #ifndef _MSC_VER,
#         replaced the inert Win32 PeekMessage/GetMessage/TranslateMessage/
#         DispatchMessage pump (all of which are no-ops stubs under Linux)
#         with a call to SDL_Process_Input_Events(), which is already defined
#         in the same TU (lines ~153-208) and declared in sdl_input.h (already
#         #included at line 65 of KEY.CPP).
#       * The MSVC path (the existing Win32 pump) is unchanged — moved into
#         an #else branch.
#       * No change to Check(), Get(), Buff_Get(), or any other method.
#
# (2) No changes to any header, substrate, or other engine TU.
#
# === Why this pass ===
#
# Per the runtime-path-survey §3 (pump cadence): SDL_Process_Input_Events
# previously fired only from Wait_Vert_Blank (DDRAW.CPP), which means only
# rendering loops observed input. Menu/dialog loops (options screen,
# briefing screen, multiplayer lobby, etc.) call Check() / Get() in tight
# spin loops without triggering a render, so those loops would never drain
# the SDL queue and would spin forever waiting for a key that was never
# delivered.
#
# After this pass, any call to Check() — from a rendering loop or a tight
# menu loop — drains the SDL queue before inspecting the buffer. The
# behaviour is identical to the Win32 path where PeekMessage drives the
# same drain via the Windows message queue.
#
# The call in Wait_Vert_Blank (DDRAW.CPP) is harmless after this patch:
# SDL_PumpEvents + SDL_PeepEvents is idempotent, and the second drain
# in the same tick just returns 0 events.
#
# === Cascade-stop expectations ===
#
# Target outcome: floor unchanged at 305/0/308 (master tip ebe43cc).
# The change is #ifndef _MSC_VER-gated and touches only KEY.CPP, which
# is already OK in the floor. The only risk is if a concurrent agent
# touched KEY.CPP between heartbeats — spot-grep for "TIM-149 pass-45D"
# marker before staging.
#
# Realistic ceiling: 305/0/308. The change set is one branch replacement
# inside an existing function body. There are no new declarations, no
# header changes, no new #includes (sdl_input.h and SDL.h are already
# included at lines 65-66 of KEY.CPP).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45D.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45D.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45D.attribution.txt"

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
    echo "# TIM-149 first compile attempt -- pass 45D (SDL input pump fallback in Fill_Buffer_From_System)"
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
