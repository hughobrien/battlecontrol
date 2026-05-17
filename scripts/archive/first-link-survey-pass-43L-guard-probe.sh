#!/usr/bin/env bash
# For each unresolved symbol, find a defining cpp/CPP and check whether
# the definition site is inside an #ifdef WIN32 / WINSOCK_IPX / similar guard.
SURVEY_DIR="$1"
SYMS="$SURVEY_DIR/undef-symbols-all.txt"
OUT="$SURVEY_DIR/guard-probe.txt"
: > "$OUT"
while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    name="${sym%%(*}"; name="${name##*::}"
    # Find candidate defining files
    files=$(grep -lF "$name" REDALERT/*.cpp REDALERT/*.CPP REDALERT/WIN32LIB/*.cpp REDALERT/WIN32LIB/*.CPP 2>/dev/null)
    if [[ -z "$files" ]]; then
        printf 'NO-DEF      %s\n' "$sym" >> "$OUT"
        continue
    fi
    found_def=""
    found_guard=""
    for f in $files; do
        # Look for a definition line (signature with body, not just comment/decl)
        lineno=$(grep -nE "^(extern\s+)?[A-Za-z_:][A-Za-z0-9_:* &]*\s+(\*\s*)?${name}\s*[\(=]" "$f" | head -1 | cut -d: -f1)
        [[ -z "$lineno" ]] && continue
        # Walk backwards to find an enclosing #ifdef
        guard=$(awk -v ln="$lineno" '
            NR < ln {
                if ($0 ~ /^#ifdef[[:space:]]+(WIN32|_WIN32|WINSOCK_IPX|MPEGMOVIE|WOLAPI_INTEGRATION|FIXIT_VERSION_3|CHEAT_KEYS|VIRTUAL_SUBLIMINAL_MESSAGING)/)
                    stack[++top] = $0
                else if ($0 ~ /^#ifndef[[:space:]]+(WIN32|_WIN32|WINSOCK_IPX)/)
                    stack[++top] = $0
                else if ($0 ~ /^#if[[:space:]]/) stack[++top] = $0
                else if ($0 ~ /^#endif/ && top > 0) top--
            }
            END { for (i=1; i<=top; i++) printf "%s | ", stack[i] }
        ' "$f")
        found_def="$f:$lineno"
        found_guard="$guard"
        break
    done
    if [[ -n "$found_guard" ]]; then
        printf 'GUARD       %-55s  %s  guard={ %s}\n' "$sym" "$found_def" "$found_guard" >> "$OUT"
    elif [[ -n "$found_def" ]]; then
        printf 'OPEN-DEF    %-55s  %s\n' "$sym" "$found_def" >> "$OUT"
    else
        printf 'NO-DEF      %s\n' "$sym" >> "$OUT"
    fi
done < "$SYMS"
echo "wrote $OUT"
wc -l "$OUT"
echo "--- summary ---"
awk '{print $1}' "$OUT" | sort | uniq -c | sort -rn
