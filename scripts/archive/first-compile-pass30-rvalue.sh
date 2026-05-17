#!/usr/bin/env bash
# TIM-57 measurement: pass 30 (Group C source-level rvalue-binding cohort).
#
# Source-level continuation of the TIM-54 Group C lineage.
# Pre baseline (post-TIM-54 commit fdd497e): 249 OK / 52 Fail / 301 Total.
#
# Pass-29-C residual histogram identified 6 first-error TUs in the
# rvalue-binding bucket -- engine pattern `Foo(SomeStraw())` /
# `Foo(SomeFilePipe())` / `Foo(CCFileClass("X.INI"))` where the callee
# takes a non-const lvalue reference (Straw& / Pipe& / FileClass&).
# Under -fno-permissive (we run with no -fpermissive flag), C++ rejects
# this binding.
#
# Fix-shape applied: per-call-site named-temp refactor.
#
# Rationale: the alternative -- adding `const Straw&` / `const Pipe&`
# overloads -- would cascade into the `Get` / `Put` virtual surfaces
# of the Straw/Pipe base classes. Those classes also declare private
# copy ctors with non-const reference parameters as the upstream's own
# rvalue-deletion idiom, so a clean const-correctness propagation
# would require touching base-class ctors too. Named-temp refactor is
# local-only (11 sites across 6 TUs) and matches the issue's preferred
# "smallest blast-radius" shape.
#
# Sites edited (commit-pending):
#   REDALERT/CCINI.CPP:109  -- FileStraw(file)         -> named temp
#   REDALERT/CCINI.CPP:185  -- FilePipe(file)          -> named temp
#   REDALERT/INI.CPP:178    -- FileStraw(file)         -> named temp
#   REDALERT/INI.CPP:314    -- FilePipe(file)          -> named temp
#   REDALERT/READLINE.CPP:61 -- FileStraw(file)        -> named temp
#   REDALERT/INIT.CPP:310   -- CCFileClass("RULES.INI")        -> named temp
#   REDALERT/INIT.CPP:317   -- CCFileClass("AFTRMATH.INI")     -> named temp
#   REDALERT/SAVELOAD.CPP:941 -- CCFileClass(Scen.ScenarioName) -> named temp
#   REDALERT/SAVELOAD.CPP:1020 -- CCFileClass("MPLAYER.INI")   -> named temp
#   REDALERT/SCENARIO.CPP:531 -- CCFileClass("MPLAYER.INI")    -> named temp
#   REDALERT/SCENARIO.CPP:2469 -- CCFileClass("MISSION.INI")   -> named temp
#
# Same harness as passes 7-29 -- same flags, same shim regen, same
# stubs. Difference relative to pass-29-C is REDALERT/ source-level
# only (6 TUs); shims and stubs are unchanged.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass30-rvalue.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass30-rvalue.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass30-rvalue.attribution.txt"

mkdir -p "$LOG_DIR"
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
    echo "# TIM-57 first compile attempt -- pass 30 rvalue-binding cohort source-level"
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
