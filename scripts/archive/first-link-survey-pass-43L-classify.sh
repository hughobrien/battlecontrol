#!/usr/bin/env bash
# TIM-140 pass-43L classifier: assign L1..L5 to every unresolved symbol
# captured by first-link-survey-pass-43L.sh.
#
# L1 -- missing system lib (declared in shim and no engine body needed)
# L2 -- Win32 shim symbol declared in linux/win32-stubs but no body
# L3 -- engine symbol multiply defined / ODR violation
# L4 -- engine symbol referenced but not defined anywhere in the tree
# L5 -- DDRAW-family unresolved expected (covered by TIM-139 / WineExpert)
#
# Read-only forensic. Output: classified.txt + histogram.txt.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURVEY_DIR="$REPO_ROOT/build/first-link-survey-pass-43L"
SYMS="$SURVEY_DIR/undef-symbols-all.txt"
LINK_LOG="$SURVEY_DIR/link-warnonly.log"
MULTIDEF_LOG="$SURVEY_DIR/link.log"
CLASSIFIED="$SURVEY_DIR/classified.txt"
HIST="$SURVEY_DIR/histogram.txt"

[[ -s "$SYMS" ]] || { echo "missing $SYMS" >&2; exit 1; }

# -- L5 substring set (DDRAW family).
is_l5() {
    case "$1" in
        AllSurfaces|DirectDrawObject|OverlappedVideoBlits|PaletteSurface|\
        Set_DD_Palette|"Set_Video_Mode(void*, int, int, int)"|\
        "SurfaceMonitorClass::Add_DD_Surface(IDirectDrawSurface*)"|\
        "SurfaceMonitorClass::Remove_DD_Surface(IDirectDrawSurface*)"|\
        "SurfaceMonitorClass::Restore_Surfaces()") return 0 ;;
    esac
    return 1
}

# -- L1 set (Linux system libs).
is_l1() {
    case "$1" in
        SafeArrayCreate|SafeArrayAccessData|SafeArrayUnaccessData|\
        GetSystemTimeAsFileTime) return 0 ;;
    esac
    return 1
}

# -- Locate any reference site for a symbol (case-insensitive on cpp/h).
locate_decl_in_stub() {
    local sym="$1"
    # Strip C++ argument list / scope for a name match in headers.
    local name="${sym%%(*}"
    name="${name##*::}"
    grep -RIl --include="*.h" --include="*.H" -F -e "$name" \
        "$REPO_ROOT/linux/win32-stubs" 2>/dev/null | head -3
}

# -- Look for any cpp/CPP definition of a free function / global by basename.
locate_def_in_engine() {
    local sym="$1"
    local name="${sym%%(*}"
    name="${name##*::}"
    grep -RIl --include="*.cpp" --include="*.CPP" -F -e "$name" \
        "$REPO_ROOT/REDALERT" 2>/dev/null | head -5
}

# Build per-symbol reference counts from link-warnonly.log.
declare -A REFCOUNT
while IFS= read -r line; do
    sym=$(printf '%s\n' "$line" | sed -nE "s/.*undefined reference to \`([^\`']+)['\`].*/\1/p")
    [[ -z "$sym" ]] && continue
    REFCOUNT["$sym"]=$(( ${REFCOUNT["$sym"]:-0} + 1 ))
done < <(grep "undefined reference" "$LINK_LOG" || true)

# Build per-symbol referencing TU set.
declare -A REFTUS
while IFS= read -r line; do
    sym=$(printf '%s\n' "$line" | sed -nE "s/.*undefined reference to \`([^\`']+)['\`].*/\1/p")
    [[ -z "$sym" ]] && continue
    tu=$(printf '%s\n' "$line" | sed -nE 's|.*/obj/([^:]+)\.o:.*|\1|p')
    [[ -z "$tu" ]] && tu=$(printf '%s\n' "$line" | sed -nE 's|^([A-Z0-9_]+\.CPP):.*|\1|p')
    [[ -z "$tu" ]] && continue
    REFTUS["$sym"]="${REFTUS["$sym"]:-} $tu"
done < <(grep "undefined reference" "$LINK_LOG" || true)

# Classification loop.
: > "$CLASSIFIED"
declare -A GROUP_COUNT GROUP_SITES
while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    name="${sym%%(*}"
    name="${name##*::}"

    if is_l5 "$sym"; then
        group="L5"
    elif is_l1 "$sym"; then
        group="L1"
    else
        # Probe codebase. If a stub header declares the bare name AND no
        # engine cpp defines it, call it L2. Otherwise L4.
        stub_hits=$(locate_decl_in_stub "$sym")
        engine_hits=$(locate_def_in_engine "$sym")
        if [[ -n "$stub_hits" && -z "$engine_hits" ]]; then
            group="L2"
        elif [[ -n "$stub_hits" && -n "$engine_hits" ]]; then
            # Ambiguous; default to L2 (shim-decl path) but flag.
            group="L2?"
        else
            group="L4"
        fi
    fi

    refs=${REFCOUNT["$sym"]:-0}
    tus=$(printf '%s\n' "${REFTUS["$sym"]:-}" | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l)
    printf '%-4s  refs=%-3d  tus=%-2d  %s\n' "$group" "$refs" "$tus" "$sym" >> "$CLASSIFIED"

    GROUP_COUNT["$group"]=$(( ${GROUP_COUNT["$group"]:-0} + 1 ))
    GROUP_SITES["$group"]=$(( ${GROUP_SITES["$group"]:-0} + refs ))
done < "$SYMS"

# L3 from the strict link.
multi_def_count=$(grep -c "multiple definition" "$MULTIDEF_LOG" || echo 0)
multi_def_pairs=$(grep "multiple definition" "$MULTIDEF_LOG" | \
    sed -nE "s|.*: multiple definition of \`([^']+)';.*|\1|p" | sort -u | wc -l)
GROUP_COUNT["L3"]="$multi_def_pairs"
GROUP_SITES["L3"]="$multi_def_count"

{
    echo "TIM-140 pass-43L unresolved-symbol classification"
    echo "  source: $LINK_LOG (undefined references)"
    echo "          $MULTIDEF_LOG (multiple definitions)"
    echo
    echo "Histogram (unique symbols / reference sites):"
    printf '  %-3s  %-7s  %-6s  description\n' "Grp" "symbols" "sites"
    for g in L1 L2 "L2?" L3 L4 L5; do
        sym=${GROUP_COUNT["$g"]:-0}
        site=${GROUP_SITES["$g"]:-0}
        case "$g" in
            L1)  desc="missing system lib" ;;
            L2)  desc="Win32 shim symbol declared but no body" ;;
            "L2?") desc="ambiguous: shim decl + engine cpp hit (manual review)" ;;
            L3)  desc="engine symbol multiply defined / ODR violation" ;;
            L4)  desc="engine symbol referenced but defined nowhere" ;;
            L5)  desc="DDRAW-family expected (TIM-139 / WineExpert scope)" ;;
        esac
        printf '  %-3s  %-7s  %-6s  %s\n' "$g" "$sym" "$site" "$desc"
    done
    echo
    echo "Per-symbol detail: $CLASSIFIED"
} > "$HIST"

cat "$HIST"
