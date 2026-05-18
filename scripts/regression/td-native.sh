#!/usr/bin/env bash
# TD native regression — T5, T12 native smokes (full tier only)
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${REGRESSION_TIER:-ci}"
cd "$REPO_ROOT" || exit 1

if [ "$TIER" != "full" ]; then
	echo "==== TD native regression: skipped (full tier only) ===="
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

run scripts/regression/T5-td-native-menu.sh
run scripts/regression/T12-td-native-m2-smoke.sh

echo "==== TD native regression: $FAIL failures ===="
exit "$FAIL"
