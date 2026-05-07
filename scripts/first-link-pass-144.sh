#!/usr/bin/env bash
# TIM-144 verification: first-link-pass-144 — L3 dedup (partial).
#
# Drops three redundant TU pairs from the link, eliminating their
# "multiple definition" errors:
#
#   LZWOTRAW.CPP  — renamed to .disabled; LZWSTRAW.CPP is canonical.
#                   LZWOTRAW.CPP was an LZO-backed variant of LZWStraw
#                   (same class name / methods, different algorithm).
#                   Dropped: LZWStraw ctor/dtor/Get (3 symbols → 6 errors).
#
#   DTABLE.CPP    — data-only file that ADPCM.CPP #includes directly
#                   (extern "C" { #include "dtable.cpp" }). Compiling it
#                   standalone too creates DiffTable duplicate. Skipped
#                   explicitly; file stays as .CPP so the include shim
#                   can still resolve ADPCM.CPP's #include.
#
#   ITABLE.CPP    — same pattern as DTABLE.CPP. IndexTable duplicate.
#
# Cascade-stops (not handled here; document for Founding Engineer):
#
#   KEYBOARD.CPP vs KEY.CPP (18 multidef errors):
#     TIM-145 placed SDL_Process_Input_Events + _Kbd global in
#     KEYBOARD.CPP. KEY.CPP has the more complete class (Put_Mouse_Message,
#     Available_Buffer_Room, bool Message_Handler vs void). Dropping either
#     TU surfaces new undefs. Resolution requires migrating the TIM-145
#     SDL pump from KEYBOARD.CPP into KEY.CPP (uncommenting _Kbd) before
#     KEYBOARD.CPP can be retired. This is a follow-up task, not a
#     mechanical dedup.
#
#   TIMERINI.CPP vs GLOBALS.CPP (TickCount — 1 multidef error):
#     TIMERINI.CPP owns WinTimerClass::* methods, TimerSystemOn (used in
#     CONNECT.CPP), and CountDownTimerClass CountDown. Dropping it would
#     cascade to new undefs. GLOBALS.CPP owns all main game globals and
#     cannot be dropped. The TickCount duplicate requires a targeted
#     source-level remove of the TimerClass TickCount(BT_SYSTEM) line from
#     TIMERINI.CPP — a follow-up task.
#
# Baseline (TIM-140 pass-43L): 27 "multiple definition" link errors.
# Expected post-dedup: 20 remaining (18 KEYBOARD + 1 TickCount + 1 other).
#   (Actual verified count reported in Summary file after run.)
#
# Compile note: compile floor at time of writing is 301 OK / 0 FAIL.
# DDRAW.CPP was fixed by TIM-141/TIM-145 so it is included in this pass.
# No -fsyntax-only here — we emit .o files for the link.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-link-pass-144"
OBJ_DIR="$PASS_DIR/obj"
COMPILE_LOG="$PASS_DIR/compile.log"
COMPILE_STATUS="$PASS_DIR/compile-status.txt"
LINK_LOG="$PASS_DIR/link.log"
LINK_SUMMARY="$PASS_DIR/link-summary.txt"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB"

: > "$COMPILE_LOG"
: > "$COMPILE_STATUS"
: > "$LINK_LOG"
: > "$LINK_SUMMARY"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -std=c++17
    -c
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
skipped=0
i=0

{
    echo "# TIM-144 first-link-pass-144 compile-to-object stage"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files (REDALERT/ + WIN32LIB/)"
    echo "# dedup skips: LZWOTRAW.CPP, DTABLE.CPP, ITABLE.CPP"
    echo "# cascade-stops: KEYBOARD.CPP, TIMERINI.CPP"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$COMPILE_LOG"

OBJECTS=()
for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    # L3 dedup skips (TIM-144):
    #   LZWOTRAW.CPP: LZO-backed LZWStraw variant (same class name as
    #     LZWSTRAW.CPP). Drop the LZO variant; keep LZWSTRAW.CPP.
    #   DTABLE.CPP / ITABLE.CPP: data-init files #include-d by ADPCM.CPP
    #     directly (extern "C" { #include "dtable.cpp" }). Compiling
    #     standalone creates duplicate DiffTable / IndexTable. Must stay
    #     as .CPP files so the include shim serves ADPCM.CPP's #include.
    case "$rel" in
        REDALERT/LZWOTRAW.CPP|REDALERT/DTABLE.CPP|REDALERT/ITABLE.CPP)
            skipped=$((skipped + 1))
            echo "SKIP $rel  # L3 dedup" >> "$COMPILE_STATUS"
            continue
            ;;
    esac

    base="$(basename "$src" .cpp)"
    base="${base%.CPP}"
    case "$rel" in
        REDALERT/WIN32LIB/*) obj="$OBJ_DIR/REDALERT/WIN32LIB/${base}.o" ;;
        *)                    obj="$OBJ_DIR/REDALERT/${base}.o" ;;
    esac

    tu_log="$(mktemp)"
    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$COMPILE_LOG"

    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$COMPILE_STATUS"
        OBJECTS+=( "$obj" )
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$COMPILE_STATUS"
    fi

    cat "$tu_log" >> "$COMPILE_LOG"
    rm -f "$tu_log"
done

{
    echo
    echo "----- compile totals -----"
    echo "ok:      $ok"
    echo "fail:    $fail"
    echo "skipped: $skipped"
    echo "total:   $total"
    echo "(skipped: LZWOTRAW.CPP, DTABLE.CPP, ITABLE.CPP)"
    echo "(L3 cascade-stops: KEYBOARD.CPP, TIMERINI.CPP still linked)"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

# ---- Link attempt ----
LINK_BIN="$PASS_DIR/redalert.elf"
LINK_FLAGS=( -o "$LINK_BIN" -no-pie -fuse-ld=bfd )

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" >"$LINK_LOG" 2>&1
LINK_RC=$?

multidef_count=$(grep -c "multiple definition" "$LINK_LOG" 2>/dev/null || echo 0)
undef_count=$(grep -c "undefined reference" "$LINK_LOG" 2>/dev/null || echo 0)

{
    echo "# TIM-144 first-link-pass-144 link summary"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]}"
    echo "# link rc: $LINK_RC"
    echo "#"
    echo "# Baseline (pass-43L): 27 multidef, 184 undef"
    echo "#"
    echo "# Results:"
    echo "multidef: $multidef_count"
    echo "undef:    $undef_count"
    echo "#"
    echo "# Cascade-stops (still open):"
    echo "#   KEYBOARD.CPP vs KEY.CPP — TIM-145 SDL pump conflict (18 multidef)"
    echo "#   TIMERINI.CPP vs GLOBALS.CPP — TickCount, WinTimerClass (1 multidef)"
    echo "#"
    grep "multiple definition" "$LINK_LOG" | sort -u
} > "$LINK_SUMMARY"

echo "Pass dir:       $PASS_DIR"
echo "Compile status: $COMPILE_STATUS"
echo "Link log:       $LINK_LOG"
echo "Link summary:   $LINK_SUMMARY"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC multidef=$multidef_count undef=$undef_count"
