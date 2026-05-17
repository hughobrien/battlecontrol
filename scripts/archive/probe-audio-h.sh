#!/usr/bin/env bash
# TIM-36 probe: AUDIO.H self-containment check.
#
# Compiles a single TU that does nothing but `#include "audio.h"`
# under the same flags as the pass harness (minus -fmax-errors=20,
# which is a measurement artifact, not part of the contract). Writes
# the full diagnostic stream to build/probe-audio-h.log with a banner
# so the artifact is self-describing.
#
# Acceptance gate (per TIM-36): the log contains zero diagnostic
# lines whose path component contains `audio.h`. Secondary diagnostics
# from sibling headers are out of scope for this ticket and will be
# scoped into TIM-37 (pass 15 re-measure) by the CEO.
#
# Usage:
#   bash scripts/probe-audio-h.sh
# Exit code:
#   0 if zero audio.h diagnostics are present.
#   1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
PROBE_TU="$LOG_DIR/probe-audio-h.cpp"
LOG_FILE="$LOG_DIR/probe-audio-h.log"

mkdir -p "$LOG_DIR"

CXX="${CXX:-g++}"

# Regenerate the case-folding shim so this probe is reproducible
# from a clean checkout (matches the pass-harness contract).
python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -std=c++17
    -fsyntax-only
    -fno-strict-aliasing
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    -include "$STUB_DIR/msvc-compat.h"
)

{
    echo "# TIM-36 probe: AUDIO.H self-containment"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# probe TU: $PROBE_TU"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
    echo "----- compiler output -----"
} > "$LOG_FILE"

"$CXX" "${CXXFLAGS[@]}" "$PROBE_TU" >>"$LOG_FILE" 2>&1
compile_status=$?

audio_h_diags=$(grep -c 'audio\.h:' "$LOG_FILE" || true)

{
    echo
    echo "----- audit -----"
    echo "compile exit: $compile_status"
    echo "audio.h diagnostic lines: $audio_h_diags"
} >> "$LOG_FILE"

echo "Log: $LOG_FILE"
echo "compile exit=$compile_status audio.h diagnostics=$audio_h_diags"

if [[ "$audio_h_diags" -ne 0 ]]; then
    exit 1
fi
exit 0
