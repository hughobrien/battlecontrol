# Design: Remove hardcoded `/opt` paths in favour of Nix store + env var resolution

**Date:** 2026-05-17
**Status:** Approved design, pending implementation plan

---

## Problem

The codebase hardcodes `/opt/redalert/` and `/opt/tiberiandawn/` in ~35 files
as default paths for Wine RA95.EXE / C&C95.EXE, game data, and DLLs. These
paths assume a manual download-and-copy setup that is inconsistent with the
project's current Nix-based ISO extraction and ephemeral WINEPREFIX workflow.

## Solution Overview

Three structural changes:

1. **EXE + data resolution** — all Wine scripts resolve the binary and MIX
   data through a consistent chain: explicit arg → env var → Nix store
   (`nix build --print-out-paths`) → error.  No hardcoded `/opt/...` fallback.

2. **Ephemeral WINEPREFIX** — every Wine script creates a fresh prefix under
   `/tmp`, populates it from the resolved paths, and cleans up on exit.
   No `$HOME/.wine-ra` or `$HOME/.wine-td` persistent prefixes.

3. **Patch script defaults removed** — 15 Python patch scripts lose their
   `/opt/...` argument defaults; they require an explicit EXE path.  All
   callers already pass one.

Native/WASM paths are unaffected: they already use `RA_ASSETS` / `TD_ASSETS`
env vars pointing to CnC Remastered Collection data.

---

## 1. EXE & Data Resolution Layer

Every Wine script (launch, campaign capture, VQA capture) needs to find the
game binary and its data.  The resolution order for both RA and TD:

```
1. Explicit positional argument to script    (highest priority)
2. Env var:  RA_EXE_PATH / TD_EXE_PATH
3. Nix store auto-resolve (via `nix build --print-out-paths`):
       RA_EXE=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null)
       RA_DATA=$(nix build .#ra-data       --impure --print-out-paths 2>/dev/null)
   This is the same pattern already used in `wine-cnc-capture.sh` and the
   flake's `capture-wine` app.  `--impure` is needed because the ISO input
   is a URL fetch (not a fixed-output hash).
4. Fatal error with instructions
```

### Game data (MIX files)

Already standardised on `RA_ASSETS` / `TD_ASSETS` env vars in the Nix flake.
Some Wine scripts currently hardcode the full path
`/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1`.  Change to:

```
1. Explicit positional argument
2. RA_ASSETS / TD_ASSETS env var
3. Error: "Set RA_ASSETS or pass a data directory"
```

### THIPX32.DLL

The stub at `tools/stub-thipx/thipx32.dll` is already the primary path in most
scripts, with a fallback to `/opt/redalert/game/THIPX32.DLL`.  Remove the
fallback — the stub must be present (it is auto-built in the Nix dev shell).
Scripts resolve it relative to the repo root.

### cnc-ddraw.dll

Already resolved via `nix build .#cnc-ddraw --print-out-paths` in
`wine-cnc-capture.sh`.  No change needed — this is the model to follow.

---

## 2. Ephemeral WINEPREFIX

Every Wine script currently uses either `$HOME/.wine-ra` or `$HOME/.wine-td`.
Replace with a fresh prefix under `/tmp`:

```bash
# Create and schedule cleanup
WINE_PREFIX=$(mktemp -d /tmp/wine-ra-XXXXXX)
trap 'rm -rf "$WINE_PREFIX"' EXIT

# Initialize
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null

# Apply required registry settings (GDI renderer, virtual desktop)
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Direct3D' \
  /v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true

# Stage EXE + DLLs + MIX data into a drive_c directory
STAGE="$WINE_PREFIX/drive_c/game"
mkdir -p "$STAGE"
cp "$RA_EXE"                    "$STAGE/RA95.EXE"
cp "$STUB_DIR/thipx32.dll"      "$STAGE/THIPX32.DLL"
for f in "$DATA_DIR"/*.MIX; do
  [[ -e "$f" ]] && ln -sf "$f" "$STAGE/"
done

# Run
cd "$STAGE"
DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" wine RA95.EXE
```

Properties:
- **Fresh every invocation** — no stale registry state.
- **No sudo** — `/tmp` is user-writable.
- **No leftover state** — trap cleans up on crash or timeout.
- **Same registry config** — GDI renderer and virtual desktop Desktop are
  applied to the fresh prefix.

All campaign capture scripts (`wine-allied-l1.sh`, `wine-soviet-l1.sh`,
`wine-gdi-m1.sh`, `wine-nod-l1.sh`, etc.) follow this same pattern, differing
only in the autostart INI and timing.

---

## 3. Patch Script Defaults Removed

15 Python patch scripts share this antipattern:

```python
if __name__ == "__main__":
    paths = sys.argv[1:] if len(sys.argv) > 1 else ["/opt/redalert/RA95.EXE", ...]
```

The fix is uniform — remove the default, require explicit paths:

```python
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    paths = sys.argv[1:]
```

Every caller already passes explicit paths (the setup scripts and capture
scripts always name the exact binary).  This change is pure dead-code removal.

### Full list of patch scripts

| # | File | Current `/opt` default(s) |
|---|------|--------------------------|
| 1 | `scripts/nocd-patch.py` | `/opt/redalert/RA95.EXE`, `/opt/redalert/game/RA95.EXE` |
| 2 | `scripts/ddscl-patch.py` | `/opt/redalert/RA95.EXE`, `/opt/redalert/game/RA95.EXE` |
| 3 | `scripts/focus-skip-patch.py` | `/opt/redalert/RA95.EXE`, `/opt/redalert/game/RA95.EXE` |
| 4 | `scripts/game-in-focus-patch.py` | `/opt/redalert/RA95.EXE`, `/opt/redalert/game/RA95.EXE` |
| 5 | `scripts/vqa-skip-patch.py` | `/opt/redalert/game/RA95.EXE` |
| 6 | `scripts/td-focus-skip-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 7 | `scripts/td-game-in-focus-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 8 | `scripts/td-vqa-skip-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 9 | `scripts/td-ddmode-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 10 | `scripts/td-setcoop-hwnd-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 11 | `scripts/td-activateapp-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 12 | `scripts/td-cdlabel-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 13 | `scripts/td-side-preview-skip-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 14 | `scripts/td-ioport-patch.py` | `/opt/tiberiandawn/C&C95.EXE` |
| 15 | `scripts/ra-data-verify.py` | `/opt/redalert/RA95.EXE.orig`, `/opt/redalert/RA95.EXE`, `/opt/redalert/game/RA95.EXE` |

---

## 4. File Change Inventory (all 37 files)

### Patch scripts (15) — remove defaults

Files 1–15 from the table above.  Each: replace default-path fallback with
`sys.exit(1)` when no args given.

### Setup scripts (2) — Nix-based, no `/opt`

**`scripts/wine-ra-setup.sh`** — currently downloads RA95.EXE + DLLs from
archive.org to `/opt/redalert`.  Replace body with: resolve from Nix store
(`nix build .#ra-patched-exe`, `nix build .#ra-thipx32-dll`,
`nix build .#ra-thipx16-dll`), print resolved paths.
The Nix derivation `ra-patched-exe` already applies NoCD + DDSCL + cdlabel
patches, so no additional patch calls are needed — the setup script is now
purely a resolver that prints "EXE at <path>, DLL at <path>".
Keep a commented-out block documenting the old manual approach for non-Nix
users who want to download from archive.org.

**`scripts/wine-td-setup.sh`** — same pattern for TD (C&C95.EXE from ZIP).
Resolve from Nix store, print paths.  No patching needed (the Nix
`ra-patched-exe` concept only exists for RA currently; TD setup prints the
resolved paths and suggests running `scripts/td-ddmode-patch.py` if needed).

### Core launch scripts (2) — ephemeral prefix + Nix resolution

**`scripts/wine-ra.sh`** — replace `/opt/redalert/RA95.EXE` default with
Nix store resolution; replace `$HOME/.wine-ra` with temporary prefix;
remove `game/RA95.EXE.orig` fallback.

**`scripts/wine-td.sh`** — same for TD; replace `/opt/tiberiandawn/C&C95.EXE`
default; replace `$HOME/.wine-td` with temporary prefix.

### Campaign capture scripts (8) — same ephemeral pattern

All follow the same structure: set `RA_EXE_PATH` / `TD_EXE_PATH`, set
`RA_DLL_DIR` / `TD_DLL_DIR`, create staging dir, launch, capture, clean up.
Replace `/opt/...` defaults with Nix store resolution; replace staging dir
with the ephemeral WINEPREFIX approach.

- `scripts/wine-allied-l1.sh`
- `scripts/wine-allied-m2.sh`
- `scripts/wine-soviet-l1.sh`
- `scripts/wine-soviet-m2.sh`
- `scripts/wine-gdi-m1.sh`
- `scripts/wine-gdi-m2.sh`
- `scripts/wine-nod-l1.sh`
- `scripts/wine-nod-m1.sh`

### Other capture/utility scripts (4)

- `scripts/wine-cnc-capture.sh`
- `scripts/wine-vqa-capture.sh`
- `scripts/wine-gameplay.sh`
- `scripts/wine-ra-difficulty-capture.sh`

### Misc (3)

- `scripts/build-stub-thipx.sh` — replace hardcoded `/opt/redalert/game/RA95.EXE.orig` with arg
- `installer/ra-installer.cpp` — change doc comment on fallback path; keep code as-is
  (installer targets end-users who aren't on Nix)
- `flake.nix` "capture-wine" app — already resolves from Nix store; verify
  alignment with new script interface

### Documentation (3)

- `skills/wine-testing/SKILL.md` — update example paths
- `tools/wine-input/README.md` — update `/opt/wine-devel` references
- `docs/tim709/README.md` — update `/opt/redalert` references (nice-to-have)

---

## 5. Non-Goals

- **Native/WASM data paths** — `RA_ASSETS` / `TD_ASSETS` already work and are
  unchanged.
- **Installer logic** — `installer/ra-installer.cpp` installs for non-Nix users
  who download a tarball.  The `/opt/redalert` fallback is a last-resort
  documented path; changing it would break the non-Nix install flow.
- **`/opt/wine-devel`** — only appears in docs and comments for manual Wine
  builds.  Not part of the automated workflow; leave as-is.
- **CI configuration** — GitHub Actions workflows do not reference `/opt`
  directly; no changes needed.

---

## 6. Success Criteria

1. `bash scripts/wine-ra.sh` (no args) resolves EXE from Nix store, creates
   ephemeral WINEPREFIX, captures title/menu screenshots, cleans up.
2. `bash scripts/wine-allied-l1.sh` (no args) resolves from Nix store,
   captures Allied L1 gameplay screenshot, cleans up.
3. Same for all 8 campaign scripts.
4. `python3 scripts/nocd-patch.py` (no args) exits with usage error.
5. All 15 patch scripts accept explicit paths and apply patches correctly.
6. No remaining references to `/opt/redalert` or `/opt/tiberiandawn` in
   actively-called code paths.

---

## 7. Verification

After all changes are implemented, run this checklist to confirm completeness.

The verification is split into three phases: grep audit, script behaviour
check, and full integration test.

### Phase 1: Grep audit

```bash
# Should return zero hits in actively-called scripts/patch files.
# Exclude docs (which may keep /opt for historical reference) and the
# installer (explicitly non-goaled).

echo "=== RA paths ==="
rg -n '/opt/redalert' --include='*.sh' --include='*.py' --include='*.cpp' \
  | grep -v 'docs/' | grep -v 'installer/' || echo "(clean)"

echo "=== TD paths ==="
rg -n '/opt/tiberiandawn' --include='*.sh' --include='*.py' --include='*.cpp' \
  | grep -v 'docs/' | grep -v 'installer/' || echo "(clean)"

echo "=== /opt/wine-devel ==="
rg -rn '/opt/wine-devel' --include='*.sh' --include='*.md' \
  | grep -v 'node_modules' | grep -v '.git/' || echo "(clean)"
```

Expected: only `docs/`, `installer/`, and `skills/` paths appear (all
non-goaled).  Zero hits in `scripts/`.

### Phase 2: Script behaviour check

```bash
# All patch scripts should reject no-arg invocation
for ps in scripts/*-patch.py scripts/*-patch-*.py; do
  [[ -f "$ps" ]] || continue
  if python3 "$ps" 2>&1 | grep -qi 'usage\|error\|argument required'; then
    echo "OK: $ps rejects no args"
  else
    echo "FAIL: $ps did not reject no-arg call"
  fi
done

# All Wine capture scripts should resolve from Nix store without /opt
# (dry-run or --help flags if they exist, otherwise check their --help output)
for ws in scripts/wine-*.sh; do
  [[ -f "$ws" ]] || continue
  if grep -q '/opt/' "$ws"; then
    echo "FAIL: $ws still contains /opt"
  else
    echo "OK: $ws has no /opt"
  fi
done
```

Expected: all patch scripts print a usage message; all `wine-*.sh` scripts
are free of `/opt`.

### Phase 3: Integration test

Run each core Wine script with no arguments and confirm success:

```bash
for script in scripts/wine-ra.sh scripts/wine-td.sh; do
  echo "=== Running $script ==="
  bash "$script" && echo "PASS: $script" || echo "FAIL: $script"
done
```

Then run one campaign capture per game to confirm the ephemeral prefix
path works end-to-end:

```bash
bash scripts/wine-allied-l1.sh
bash scripts/wine-gdi-m1.sh
```

Expected: each script creates a temp prefix under `/tmp/wine-*`, captures
screenshots to `e2e/screenshots/`, and the `/tmp` prefix is removed on exit.

### CI integration

The grep audit (Phase 1) should be added to CI as a new gate that fails if
any `scripts/` file contains `/opt/redalert` or `/opt/tiberiandawn`.  This
prevents regression if a new script is added with a hardcoded path.
