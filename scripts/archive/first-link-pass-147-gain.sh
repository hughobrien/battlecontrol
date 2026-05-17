#!/usr/bin/env bash
# TIM-147 pass-43N link-side recovery measurement.
#
# Baseline (pass-43L): 184 undef-reference sites with the four
# whole-body-elided TUs (CCDDE, STATS, INTERNET, TCPIP) compiled
# without -DWIN32 (so each .o is empty / 0 syms).
#
# Bonus measurement after pass-43M (CCDDE+STATS substituted, INTERNET
# +TCPIP still empty): 158 undef-reference sites (-26).
#
# This pass: substitute INTERNET.o (62 syms) and TCPIP.o (65 syms)
# *in addition* to the already-substituted CCDDE.o (19) and STATS.o
# (34). Expect undef-sites to drop further (+127 newly-defined symbols
# of which an unknown-but-non-zero fraction will resolve previously-
# undefined references in sibling TUs).
#
# Method:
#   1. Take pass-43L's complete 300-object set.
#   2. Replace CCDDE.o, STATS.o, INTERNET.o, TCPIP.o with -DWIN32 builds.
#   3. Re-link with `g++ -no-pie -fuse-ld=bfd
#                       -Wl,--allow-multiple-definition
#                       -Wl,--warn-unresolved-symbols`
#   4. Diff undef sites against pass-43L's 184 baseline and 43M's 158.
#
# Same shape as build/first-link-survey-pass-43M-gain/.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
L43_DIR="$REPO_ROOT/build/first-link-survey-pass-43L"
PASS_DIR="$REPO_ROOT/build/first-link-survey-pass-43N-gain"
OBJ_DIR="$PASS_DIR/obj"
LINK_LOG="$PASS_DIR/link-warnonly.log"
OBJECTS_LIST="$PASS_DIR/objects.list"
UNDEF_FILE="$PASS_DIR/undef-symbols.txt"
README="$PASS_DIR/README.md"

mkdir -p "$PASS_DIR" "$OBJ_DIR"

CXX="${CXX:-g++}"

# Generate the include shim (idempotent; lock-protected).
SHIM_LOCK="$REPO_ROOT/build/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -DWIN32
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

TARGETS=( CCDDE STATS INTERNET TCPIP )
for t in "${TARGETS[@]}"; do
    "$CXX" "${CXXFLAGS[@]}" "$SRC_DIR/${t}.CPP" -o "$OBJ_DIR/${t}.o"
done

# Build the substituted object list:
# - Start from pass-43L's full 300-object set
# - For each target, point at our -DWIN32 build instead of 43L's empty .o
: > "$OBJECTS_LIST"
shopt -s nullglob
for o in "$L43_DIR"/obj/REDALERT/*.o "$L43_DIR"/obj/REDALERT/WIN32LIB/*.o; do
    base="$(basename "$o" .o)"
    sub_path=""
    for t in "${TARGETS[@]}"; do
        if [[ "$base" == "$t" ]]; then
            sub_path="$OBJ_DIR/${t}.o"
            break
        fi
    done
    if [[ -n "$sub_path" ]]; then
        echo "$sub_path" >> "$OBJECTS_LIST"
    else
        echo "$o" >> "$OBJECTS_LIST"
    fi
done
shopt -u nullglob

# Re-link with --warn-unresolved-symbols so we measure undef-site count
# without requiring the link to succeed.
mapfile -t OBJ_ARGS < "$OBJECTS_LIST"
"$CXX" -no-pie -fuse-ld=bfd \
    -Wl,--allow-multiple-definition \
    -Wl,--warn-unresolved-symbols \
    -o "$PASS_DIR/redalert.elf" \
    "${OBJ_ARGS[@]}" \
    >"$LINK_LOG" 2>&1
LINK_RC=$?

undef_sites=$(grep -c "undefined reference" "$LINK_LOG" || true)
multidef_sites=$(grep -c "multiple definition" "$LINK_LOG" || true)

# Extract unique unresolved symbol set.
grep "undefined reference" "$LINK_LOG" \
    | sed -nE "s/.*undefined reference to \`([^']+)'.*/\1/p" \
    | sort -u > "$UNDEF_FILE"
unique_unresolved=$(wc -l < "$UNDEF_FILE")

cat > "$README" <<EOF
# TIM-147 pass-43N link-side recovery measurement

Bonus measurement on top of pass-43N (compile floor 301/0/301).
Quantifies the link-time payoff from the 180 newly-defined symbols
across the four whole-body-elided TUs (CCDDE +19, STATS +34,
INTERNET +62, TCPIP +65) once cluster A1+A2+A3 graduates them.

## Method

1. Take the pass-43L baseline \`.o\` set (300 OK TUs, all built without -DWIN32).
2. Substitute the WIN32-enabled CCDDE.o, STATS.o, INTERNET.o, TCPIP.o.
3. Re-link with \`g++ -no-pie -fuse-ld=bfd
   -Wl,--allow-multiple-definition -Wl,--warn-unresolved-symbols\`.
4. Diff the unresolved-reference set against pass-43L (184) and 43M (158).

## Result

| Metric                           | 43L | 43M (CCDDE+STATS) | 43N (+INTERNET+TCPIP) |
|----------------------------------|----:|------------------:|----------------------:|
| undefined-reference sites        | 184 | 158               | $undef_sites          |
| unique unresolved symbols        |  57 |  53               | $unique_unresolved    |

## Files

- \`link-warnonly.log\` — re-link diagnostic.
- \`objects.list\` — the 300 .o paths with the four substituted targets.
- \`undef-symbols.txt\` — remaining unique unresolved symbols.
EOF

echo "Pass dir:           $PASS_DIR"
echo "Link log:           $LINK_LOG"
echo "Undef sites:        $undef_sites"
echo "Multidef sites:     $multidef_sites"
echo "Unique unresolved:  $unique_unresolved"
echo "Link rc:            $LINK_RC"
