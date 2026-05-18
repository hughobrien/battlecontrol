#!/usr/bin/env bash
# RA native regression — T6, T11 native smokes (full tier only)
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${REGRESSION_TIER:-ci}"
cd "$REPO_ROOT" || exit 1

if [ "$TIER" != "full" ]; then
	echo "==== RA native regression: skipped (full tier only) ===="
	exit 0
fi

FAIL=0
run() {
	local script="$1"
	echo "---- $script ----"
	bash "$script" || {
		rc=$?
		[ "$rc" -eq 77 ] || FAIL=$((FAIL + 1))
	}
}

run scripts/regression/T6-ra-native-smoke.sh
run scripts/regression/T11-ra-native-m2-smoke.sh

echo "==== RA native regression: $FAIL failures ===="
exit "$FAIL"
