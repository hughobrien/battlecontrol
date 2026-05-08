#!/usr/bin/env bash
# TIM-156 verification: first-link-pass-156 (pass-47) — SDL2 surface/render layer.
#
# Adds -lSDL2 to the link command so the 66 L5 SDL_* undef sites from
# pass-153 resolve against the installed libSDL2.  The rendering and
# surface seam (SDL_CreateRGBSurfaceWithFormat, SDL_CreateRenderer,
# SDL_BlitSurface, SDL_UpdateTexture, SDL_RenderPresent, etc.) was already
# implemented in DDRAW.CPP under #ifndef _MSC_VER by TIM-141 commits; the
# audio seam (SDL_OpenAudioDevice / SDL_CloseAudioDevice / etc.) was
# implemented by TIM-148 pass-44.  All 30 unique SDL_* symbols (66 sites)
# close here.
#
# Remaining undefs after this pass:
#   Umbrella A residue — TcpipManagerClass::*, Winsock, DDEServer/DDEServerClass
#   (require struct infrastructure, tracked under TIM-143 umbrella A).
#
# Mirrors first-link-pass-153.sh shape exactly; only delta is -lSDL2 in
# LINK_FLAGS and the pass directory / summary messages.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-link-pass-156"
OBJ_DIR="$PASS_DIR/obj"
COMPILE_LOG="$PASS_DIR/compile.log"
COMPILE_STATUS="$PASS_DIR/compile-status.txt"
LINK_LOG="$PASS_DIR/link.log"
LINK_SUMMARY="$PASS_DIR/link-summary.txt"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

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
shopt -s nullglob
STUB_SOURCES=( "$STUB_DIR"/*.cpp )
shopt -u nullglob

total=$(( ${#SOURCES[@]} + ${#STUB_SOURCES[@]} ))
ok=0
fail=0
skipped=0
i=0

{
    echo "# TIM-156 first-link-pass-156 compile-to-object stage"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: ${#SOURCES[@]} engine + ${#STUB_SOURCES[@]} stub .cpp files"
    echo "# dedup skips: LZWOTRAW.CPP (renamed), DTABLE.CPP, ITABLE.CPP"
    echo "# cascade-stops: KEYBOARD.CPP, TIMERINI.CPP"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$COMPILE_LOG"

OBJECTS=()

compile_one() {
    local src="$1"
    local obj="$2"
    local rel="${src#$REPO_ROOT/}"
    local tu_log
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
}

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    if [[ "$rel" == "REDALERT/DTABLE.CPP" || "$rel" == "REDALERT/ITABLE.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel  # L3 dedup: included by ADPCM.CPP" >> "$COMPILE_STATUS"
        continue
    fi
    if [[ "$rel" == "REDALERT/LZWOTRAW.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel  # L3 dedup: LZWStraw duplicate (canonical = LZWSTRAW.CPP)" >> "$COMPILE_STATUS"
        continue
    fi

    base="$(basename "$src" .cpp)"
    base="${base%.CPP}"
    case "$rel" in
        REDALERT/WIN32LIB/*) obj="$OBJ_DIR/REDALERT/WIN32LIB/${base}.o" ;;
        *)                    obj="$OBJ_DIR/REDALERT/${base}.o" ;;
    esac
    compile_one "$src" "$obj"
done

for src in "${STUB_SOURCES[@]}"; do
    i=$((i + 1))
    base="$(basename "$src" .cpp)"
    obj="$OBJ_DIR/STUBS/${base}.o"
    compile_one "$src" "$obj"
done

{
    echo
    echo "----- compile totals -----"
    echo "ok:      $ok"
    echo "fail:    $fail"
    echo "skipped: $skipped"
    echo "total:   $total"
    echo "(skipped: DTABLE.CPP, ITABLE.CPP, LZWOTRAW.CPP)"
    echo "stub objects: ${#STUB_SOURCES[@]}"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

# ---- Link attempt ----
# -lSDL2: closes all 66 L5 SDL_* undef sites (30 unique symbols).
# ld.bfd requires libraries AFTER the object files for proper symbol
# resolution even with shared libraries; -lSDL2 after OBJECTS ensures
# the linker accumulates all unresolved SDL_ references before searching
# the library.
# Remaining unresolved after this pass: TcpipManagerClass, Winsock,
# DDEServer — Umbrella A residue tracked under TIM-143.
LINK_BIN="$PASS_DIR/redalert.elf"
LINK_FLAGS=( -no-pie -fuse-ld=bfd )

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 >"$LINK_LOG" 2>&1
LINK_RC=$?

multidef_count=$(grep "multiple definition" "$LINK_LOG" 2>/dev/null | wc -l)
undef_count=$(grep "undefined reference" "$LINK_LOG" 2>/dev/null | wc -l)

# Closed-symbol diff vs pass-153 baseline.
PASS153_LOG="$REPO_ROOT/build/first-link-pass-153/link.log"
if [[ -f "$PASS153_LOG" ]]; then
    pass153_undef=$(grep "undefined reference" "$PASS153_LOG" 2>/dev/null | wc -l)
    delta=$(( pass153_undef - undef_count ))
else
    pass153_undef="(missing)"
    delta="(n/a)"
fi

{
    echo "# TIM-156 first-link-pass-156 (pass-47) link summary"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]} (engine + ${#STUB_SOURCES[@]} stub TUs)"
    echo "# link rc: $LINK_RC"
    echo "# delta flag: added -lSDL2"
    echo "#"
    echo "# Baselines:"
    echo "#   pass-43L (pre-CCDDE/STATS): 184 undef"
    echo "#   pass-146 (post-L4 C-stubs): 133 undef"
    echo "#   pass-153 (post-umbrella-A NOP stubs): $pass153_undef undef"
    echo "#"
    echo "# Results:"
    echo "multidef:           $multidef_count"
    echo "undef:              $undef_count"
    echo "delta vs pass-153:  $delta (closed by -lSDL2)"
    echo "#"
    echo "# SDL_* symbol classification:"
    echo "#   rendering: SDL_CreateRGBSurfaceWithFormat SDL_CreateRenderer"
    echo "#              SDL_CreateTexture SDL_DestroyRenderer SDL_DestroyTexture"
    echo "#              SDL_FreeSurface SDL_RenderClear SDL_RenderCopy"
    echo "#              SDL_RenderPresent SDL_UpdateTexture SDL_UpperBlit"
    echo "#              SDL_SetPaletteColors"
    echo "#   window:    SDL_CreateWindow SDL_DestroyWindow SDL_HideWindow"
    echo "#              SDL_MaximizeWindow SDL_MinimizeWindow SDL_RaiseWindow"
    echo "#              SDL_SetWindowSize SDL_ShowWindow"
    echo "#   events:    SDL_PeepEvents SDL_PumpEvents"
    echo "#   audio:     SDL_CloseAudioDevice SDL_LockAudioDevice"
    echo "#              SDL_OpenAudioDevice SDL_PauseAudioDevice"
    echo "#              SDL_UnlockAudioDevice"
    echo "#   init:      SDL_InitSubSystem SDL_QuitSubSystem SDL_WasInit"
    echo "#"
    echo "# Deferred (Umbrella A residue):"
    grep "undefined reference" "$LINK_LOG" | grep -v "SDL_" | \
        sed "s/.*undefined reference to \`\([^']*\)'.*/\1/" | sort -u | \
        sed 's/^/#   /'
    echo "#"
    grep "multiple definition" "$LINK_LOG" | sort -u
} > "$LINK_SUMMARY"

echo "Pass dir:       $PASS_DIR"
echo "Compile status: $COMPILE_STATUS"
echo "Link log:       $LINK_LOG"
echo "Link summary:   $LINK_SUMMARY"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC multidef=$multidef_count undef=$undef_count delta=$delta"
