#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_dir="${RA_MINGW_RUN_DIR:-/tmp/battlecontrol-mingw-ra}"
ra_exe="${RA_MINGW_EXE:-$repo_root/build-mingw32/ra.exe}"
data_dir="${DATA_DIR:-${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}}"

if [[ ! -f "$ra_exe" ]]; then
	echo "missing Win32 RA executable: $ra_exe" >&2
	echo "build it with: cmake --preset mingw32 && cmake --build build-mingw32 --target ra" >&2
	exit 1
fi

required_env=(MINGW_SDL2_DEV MINGW_SDL3_BIN MINGW_GCC_LIB MINGW_MCFGTHREAD)
for name in "${required_env[@]}"; do
	if [[ -z "${!name:-}" ]]; then
		echo "missing $name; enter nix develop so the MinGW runtime paths are exported" >&2
		exit 1
	fi
done

mkdir -p "$run_dir"
cp "$ra_exe" "$run_dir/ra.exe"
cp "$MINGW_SDL2_DEV/bin/SDL2.dll" "$run_dir/"
cp "$MINGW_SDL3_BIN/bin/SDL3.dll" "$run_dir/"
cp "$MINGW_GCC_LIB/i686-w64-mingw32/lib/libgcc_s_sjlj-1.dll" "$run_dir/"
cp "$MINGW_GCC_LIB/i686-w64-mingw32/lib/libstdc++-6.dll" "$run_dir/"
cp "$MINGW_MCFGTHREAD/bin/libmcfgthread-2.dll" "$run_dir/"

cd "$data_dir"
exec wine "$run_dir/ra.exe" "$@"
