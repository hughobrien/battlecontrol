#!/usr/bin/env bash
# TIM-128 measurement: pass 40AI (cluster-H __asm{} body-stub on DrawMisc.cpp).
#
# Direct successor to TIM-127/pass-40AH. After pass-40AH graduated MiscAsm.cpp
# via Strategy B (per-TU body stub), this pass applies the same fix to the
# largest cluster-H TU per the TIM-104 pre-survey: REDALERT/WIN32LIB/DrawMisc.cpp.
# This is also the TIM-122 retry under Strategy B.
#
# Sites in this commit (atomic, single TU): 20 active __asm{} bodies in
# REDALERT/WIN32LIB/DrawMisc.cpp (pre-stub line numbers in parens):
#   * Buffer_Draw_Line                  (line 137)
#   * Buffer_Fill_Rect                  (line 1098)
#   * Buffer_Clear                      (line 1312)
#   * Linear_Blit_To_Linear             (line 1433)
#   * Linear_Scale_To_Linear            (line 1946)
#   * Init_Stamps                       (line 2691)
#   * Buffer_Draw_Stamp                 (line 2782)
#   * Buffer_Draw_Stamp_Clip            (line 2990)
#   * Buffer_Remap                      (line 3328)
#   * Apply_XOR_Delta                   (line 3535)
#   * Apply_XOR_Delta_To_Page_Or_Viewport (line 3673)
#   * XOR_Delta_Buffer                  (line 3734)
#   * Copy_Delta_Buffer                 (line 3885)
#   * Build_Fading_Table                (line 4101)
#   * Bump_Color                        (line 4404)
#   * Buffer_Put_Pixel                  (line 4516)
#   * Clip_Rect                         (line 4629)
#   * Confine_Rect                      (line 4781)
#   * Buffer_To_Page                    (line 5231)
#   * Buffer_Get_Pixel                  (line 5467)
#
# One further __asm{} occurrence remains in source but is inactive --
# it sits inside a `#if (0)//ST 5/10/2019` block (post-stub line ~1835),
# guarding a disabled re-implementation path. Left untouched.
#
# All 20 active bodies are replaced in-place with
#   `{ /* __asm body removed for syntax-only build (TIM-124) */ }`
# turning the inner braces into a regular C++ compound statement so the
# parse-class first-error (`expected '(' before '{'` at :137:15) drains.
# Missing-return on int/unsigned/long return paths is suppressed by the
# harness `-w` flag, same as the COORD.CPP pilot, IRANDOM.CPP, and
# MiscAsm.cpp graduations.
#
# Pre baseline (pass-40AH tip, commit 2575142):
#   294 OK / 7 FAIL / 301 Total.
#
# Realistic ceiling: 295 OK / 6 FAIL (+1) -- DrawMisc.cpp graduates.
#   Floor on Tier-B `__asm{}` reaches 6 FAIL (Tier-D residuals only --
#   DDRAW, SPRITE, MPLIB/MPMGRD DOS-modem, DLLInterface/Editor Glyphx --
#   per TIM-104 pre-survey).
# Realistic floor:   294 OK / 7 FAIL (+0) -- a fresh first-error of
#   different shape surfaces in DrawMisc.cpp. Per cascade stop-and-handback
#   rule (cluster H), revert the body-stub edit, comment with the new
#   first-error, and hand back; do not chain another fix on this TU.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AI.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AI.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AI.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass invocations end-to-end via flock.
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
    echo "# TIM-128 first compile attempt -- pass 40AI (cluster-H __asm{} body-stub on DrawMisc.cpp)"
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
