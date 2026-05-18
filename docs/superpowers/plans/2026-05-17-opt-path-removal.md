# /opt Path Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) for syntax tracking.

**Goal:** Remove all hardcoded `/opt/redalert` and `/opt/tiberiandawn` defaults from scripts, replacing with Nix store resolution + ephemeral WINEPREFIX.

**Architecture:** Three structural changes: (1) EXE/data resolution via env var / Nix store chain, (2) ephemeral WINEPREFIX under `/tmp`, (3) patch scripts require explicit paths. Native/WASM data (`RA_ASSETS`/`TD_ASSETS`) unchanged.

**Tech Stack:** Bash (Wine scripts), Python (patch scripts), Nix (package resolution)

---

## File Map

### Patch scripts (15) — remove argument defaults, require explicit path

Each file needs the same one-line `if __name__` guard change. All callers already pass explicit paths. Files 1–6 are RA, 7–14 are TD, 15 is data-verify.

| # | File | Mod |
|---|------|-----|
| 1 | `scripts/nocd-patch.py` | `__main__` guard |
| 2 | `scripts/ddscl-patch.py` | `__main__` guard |
| 3 | `scripts/focus-skip-patch.py` | `__main__` guard |
| 4 | `scripts/game-in-focus-patch.py` | `__main__` guard |
| 5 | `scripts/vqa-skip-patch.py` | `__main__` guard |
| 6 | `scripts/td-focus-skip-patch.py` | `__main__` guard |
| 7 | `scripts/td-game-in-focus-patch.py` | `__main__` guard |
| 8 | `scripts/td-vqa-skip-patch.py` | `__main__` guard |
| 9 | `scripts/td-ddmode-patch.py` | `__main__` guard |
| 10 | `scripts/td-setcoop-hwnd-patch.py` | `__main__` guard |
| 11 | `scripts/td-activateapp-patch.py` | `__main__` guard |
| 12 | `scripts/td-cdlabel-patch.py` | `__main__` guard |
| 13 | `scripts/td-side-preview-skip-patch.py` | `__main__` guard |
| 14 | `scripts/td-ioport-patch.py` | `__main__` guard |
| 15 | `scripts/ra-data-verify.py` | `__main__` guard |

### Core launch scripts (2) — ephemeral prefix + Nix store resolution

| # | File | Mod |
|---|------|-----|
| 16 | `scripts/wine-ra.sh` | Major: replace `/opt` defaults, replace `$HOME/.wine-ra` with temp prefix |
| 17 | `scripts/wine-td.sh` | Major: same for TD |

### Setup scripts (2) — Nix store resolution, no download

| # | File | Mod |
|---|------|-----|
| 18 | `scripts/wine-ra-setup.sh` | Replace download body with Nix store resolution |
| 19 | `scripts/wine-td-setup.sh` | Same for TD |

### Campaign capture scripts (8) — ephemeral prefix pattern

| # | File | Mod |
|---|------|-----|
| 20 | `scripts/wine-allied-l1.sh` | Ephemeral prefix + Nix resolution |
| 21 | `scripts/wine-allied-m2.sh` | Same |
| 22 | `scripts/wine-soviet-l1.sh` | Same |
| 23 | `scripts/wine-soviet-m2.sh` | Same |
| 24 | `scripts/wine-gdi-m1.sh` | Same |
| 25 | `scripts/wine-gdi-m2.sh` | Same |
| 26 | `scripts/wine-nod-l1.sh` | Same |
| 27 | `scripts/wine-nod-m1.sh` | Same |

### Other capture/utility scripts (4)

| # | File | Mod |
|---|------|-----|
| 28 | `scripts/wine-cnc-capture.sh` | Ephemeral prefix + Nix resolution |
| 29 | `scripts/wine-vqa-capture.sh` | Same |
| 30 | `scripts/wine-gameplay.sh` | Same |
| 31 | `scripts/wine-ra-difficulty-capture.sh` | Same |

### Misc (3)

| # | File | Mod |
|---|------|-----|
| 32 | `scripts/build-stub-thipx.sh` | Replace hardcoded `/opt/redalert/game/RA95.EXE.orig` with arg |
| 33 | `installer/ra-installer.cpp` | Doc-comment only (non-goaled for code change) |
| 34 | `flake.nix` capture-wine app | Verify alignment |

### Verification (2)

| # | File | Mod |
|---|------|-----|
| 35 | CI grep gate | Add to CI workflow or ci-local.sh |
| 36 | Manual verification | Run Phase 1-3 checks from spec Section 7 |

---

### Task 1: Patch script `__main__` guards — RA side (6 files)

**Files (modify):**
- `scripts/nocd-patch.py`
- `scripts/ddscl-patch.py`
- `scripts/focus-skip-patch.py`
- `scripts/game-in-focus-patch.py`
- `scripts/vqa-skip-patch.py`
- `scripts/ra-data-verify.py`

This task covers the six RA-side Python patch scripts. Each has the same structural pattern in its `__main__` block: a default list falling back to `/opt/redalert/...`. The fix is identical for all.

- [ ] **Step 1: Edit `scripts/nocd-patch.py` `__main__` guard**

Current code (around line 98-103):
```python
if __name__ == "__main__":
    paths = (
        sys.argv[1:]
        if len(sys.argv) > 1
        else [
            "/opt/redalert/RA95.EXE",
            "/opt/redalert/game/RA95.EXE",
        ]
    )
```

Replace with:
```python
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    paths = sys.argv[1:]
```

Also update the docstring comment describing expected SHA-256 to remove mention of `/opt/redalert/RA95.EXE.orig`.

- [ ] **Step 2: Edit `scripts/ddscl-patch.py` `__main__` guard**

Same pattern. Current code (around line 140-148):
```python
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    dry = "--dry-run" in sys.argv
    paths = (
        args
        if args
        else [
            "/opt/redalert/RA95.EXE",
            "/opt/redalert/game/RA95.EXE",
        ]
    )
```

Replace with:
```python
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    dry = "--dry-run" in sys.argv
    paths = args
```

- [ ] **Step 3: Edit `scripts/focus-skip-patch.py` `__main__` guard**

Current code (around line 93-97):
```python
if __name__ == "__main__":
    paths = args if args else [
        "/opt/redalert/RA95.EXE",
        "/opt/redalert/game/RA95.EXE",
    ]
```

Replace with:
```python
if __name__ == "__main__":
    if not args:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    paths = args
```

- [ ] **Step 4: Edit `scripts/game-in-focus-patch.py` `__main__` guard**

Current code (around line 211-215):
```python
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    ...
    paths = (
        args
        if args
        else [
            "/opt/redalert/RA95.EXE",
            "/opt/redalert/game/RA95.EXE",
        ]
    )
```

Replace with the same pattern as ddscl-patch.py (Step 2 code).

- [ ] **Step 5: Edit `scripts/vqa-skip-patch.py` `__main__` guard**

Current code (around line 106-109):
```python
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    ...
    paths = args if args else ["/opt/redalert/game/RA95.EXE"]
```

Replace with the same `if not args: usage; exit` pattern.

- [ ] **Step 6: Edit `scripts/ra-data-verify.py` `__main__` guard**

Current code (around line 27-34):
```python
if __name__ == "__main__":
    dirs = sys.argv[1:] if len(sys.argv) > 1 else [
        "/opt/redalert/RA95.EXE.orig",
        "/opt/redalert/RA95.EXE",
        "/opt/redalert/game/RA95.EXE",
    ]
```

Also the docstring at line 26 mentions `/opt/redalert/RA95.EXE.orig`. Change to:
```python
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {__file__} <data-dir> [data-dir ...]", file=sys.stderr)
        sys.exit(1)
    dirs = sys.argv[1:]
```

Update docstring to remove the `/opt/redalert` reference — replace with "Pass the game data directory containing MAIN.MIX and REDALERT.MIX."

- [ ] **Step 7: Verify all 6 RA patch scripts reject no-arg invocation**

Run:
```bash
for ps in scripts/nocd-patch.py scripts/ddscl-patch.py scripts/focus-skip-patch.py \
         scripts/game-in-focus-patch.py scripts/vqa-skip-patch.py scripts/ra-data-verify.py; do
  echo "=== $ps ==="
  python3 "$ps" 2>&1 || true
  echo ""
done
```

Expected: each prints a usage message and exits with code 1. No traceback.

- [ ] **Step 8: Commit**

```bash
git add scripts/nocd-patch.py scripts/ddscl-patch.py scripts/focus-skip-patch.py \
       scripts/game-in-focus-patch.py scripts/vqa-skip-patch.py scripts/ra-data-verify.py
git commit -m "refactor: remove /opt defaults from RA patch scripts"
```

---

### Task 2: Patch script `__main__` guards — TD side (8 files)

**Files (modify):**
- `scripts/td-focus-skip-patch.py`
- `scripts/td-game-in-focus-patch.py`
- `scripts/td-vqa-skip-patch.py`
- `scripts/td-ddmode-patch.py`
- `scripts/td-setcoop-hwnd-patch.py`
- `scripts/td-activateapp-patch.py`
- `scripts/td-cdlabel-patch.py`
- `scripts/td-side-preview-skip-patch.py`
- `scripts/td-ioport-patch.py`

Each follows the same pattern as the RA scripts, defaulting to `/opt/tiberiandawn/C&C95.EXE` instead.

- [ ] **Step 1: Edit all 9 TD patch scripts**

For each file, the `__main__` block has a default list like:
```python
paths = args if args else ["/opt/tiberiandawn/C&C95.EXE"]
```

Some also have a more complex structure with `--dry-run` handling. In each case:

1. Add `if not args:` guard after sys.argv parsing that prints usage and exits with code 1.
2. Remove the `else "/opt/tiberiandawn/C&C95.EXE"` fallback.
3. Ensure paths variable always points to `args` (never the default list).

The exact replacement text for each file depends on the existing `__main__` structure. Refer to the specific file and apply the same pattern as Task 1.

Files `scripts/td-cdlabel-patch.py` and `scripts/td-ioport-patch.py` have a slightly different pattern:
```python
if __name__ == "__main__":
    paths = args if args else ["/opt/tiberiandawn/C&C95.EXE"]
```
Change to:
```python
if __name__ == "__main__":
    if not args:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    paths = args
```

- [ ] **Step 2: Verify all 9 TD patch scripts reject no-arg invocation**

Run:
```bash
for ps in scripts/td-*.py; do
  echo "=== $ps ==="
  python3 "$ps" 2>&1 || true
  echo ""
done
```

Expected: each prints a usage message and exits with code 1. No traceback.

- [ ] **Step 3: Commit**

```bash
git add scripts/td-focus-skip-patch.py scripts/td-game-in-focus-patch.py \
       scripts/td-vqa-skip-patch.py scripts/td-ddmode-patch.py \
       scripts/td-setcoop-hwnd-patch.py scripts/td-activateapp-patch.py \
       scripts/td-cdlabel-patch.py scripts/td-side-preview-skip-patch.py \
       scripts/td-ioport-patch.py
git commit -m "refactor: remove /opt defaults from TD patch scripts"
```

---

### Task 3: Core RA launch script — `scripts/wine-ra.sh`

**Files (modify):** `scripts/wine-ra.sh`

This is the most substantial change. The script currently:
- Defaults `RA_EXE_PATH` to `/opt/redalert/RA95.EXE`
- Falls back to `/opt/redalert/game/RA95.EXE.orig` if not found
- Defaults `DATA_DIR` to `/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1`
- Uses `WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra}"` (persistent prefix)
- Creates a staging dir via `mktemp -d` and symlinks MIX files into it

New behaviour:
- Default `RA_EXE_PATH`: no arg → `RA_EXE_PATH` env var → Nix store → error
- Default `DATA_DIR`: no arg → `RA_ASSETS` env var → error
- `WINEPREFIX`: always ephemeral under `/tmp/wine-ra-XXXXXX`, cleaned up on exit
- Staging dir is `$WINEPREFIX/drive_c/game/` (standard Wine layout)

- [ ] **Step 1: Read the full current script**

Run: `cat -n scripts/wine-ra.sh`

Understanding the current structure is critical. Key sections:
- Lines 82-99: argument defaults (`RA_EXE_PATH`, `DATA_DIR`, `WINE_PREFIX`)
- Lines 96-99: `/opt/redalert/game/RA95.EXE.orig` fallback
- Lines 119-140: Wine staging (creates `$RA_STAGE`, symlinks MIXes, copies EXE)
- Lines 143-152: Wine prefix init (`wineboot --init`)
- Lines 154-158: Registry config (GDI renderer, virtual desktop)
- Lines 163-169: Xvfb startup
- Lines 174-197: Launch, dialog dismiss, screenshot capture
- Lines 200-220: Results/output

- [ ] **Step 2: Replace argument defaults section (lines ~82-99)**

Current:
```bash
RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/RA95.EXE}}"
# If patched EXE not found, fall back to original in game/
if [[ ! -f "$RA_EXE_PATH" ]]; then
	RA_EXE_PATH="/opt/redalert/game/RA95.EXE.orig"
fi
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra}"
DISPLAY_NUM="${WINE_DISPLAY:-:98}"
```

Replace with:
```bash
# Argument defaults: arg → env var → Nix store → error
RA_EXE_PATH="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE_PATH" ]]; then
  RA_EXE_PATH=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE_PATH" ]] || [[ ! -f "$RA_EXE_PATH" ]]; then
  echo "ERROR: RA95.EXE not found."
  echo "  Pass as first argument, set RA_EXE_PATH, or run from nix develop."
  exit 1
fi

DATA_DIR="${2:-${RA_ASSETS:-}}"
if [[ -z "$DATA_DIR" ]]; then
  echo "ERROR: RA game data directory not found."
  echo "  Pass as second argument or set RA_ASSETS."
  exit 1
fi

SCREENSHOT_DIR="${3:-e2e/screenshots}"
DISPLAY_NUM="${WINE_DISPLAY:-:98}"
```

- [ ] **Step 3: Replace Wine prefix section (lines ~119-152)**

Remove the persistent prefix and staging dir. Replace with ephemeral prefix:

Current staging block (lines ~114-158):
```bash
# ─── Wine prefix + staging ───────────────────────────────────────────────────

echo "=== Wine staging ==="
RA_STAGE="$(mktemp -d)"
trap 'rm -rf "$RA_STAGE"' EXIT

# Link MIX data into staging directory.
for f in "$DATA_DIR"/*.MIX; do
	[[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done
# Write REDALERT.INI with intro skipping (cannot symlink, need write access).
cat >"$RA_STAGE/REDALERT.INI" <<'INIEOF'
...
INIEOF
# Copy EXE and IPX DLLs to staging.
cp "$RA_EXE_PATH" "$RA_STAGE/RA95.EXE"
# Use stub THIPX32.DLL ...
STUB_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/stub-thipx"
if [[ -f "$STUB_DIR/thipx32.dll" ]]; then
	cp "$STUB_DIR/thipx32.dll" "$RA_STAGE/THIPX32.DLL"
else
	# Fallback: copy original THIPX DLLs if stub not built
	THIPX_DIR="$(dirname "$RA_EXE_PATH")"
	for dll in THIPX32.DLL THIPX16.DLL; do
		[[ -f "$THIPX_DIR/$dll" ]] && cp "$THIPX_DIR/$dll" "$RA_STAGE/$dll"
	done
fi

if [[ ! -d "$WINE_PREFIX" ]]; then
	echo "  Creating Wine prefix at $WINE_PREFIX..."
	WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null
fi
echo "  Staging: $RA_STAGE"
echo ""

# Configure Wine GDI renderer + virtual desktop (needed under Xvfb for DirectDraw).
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
	'HKCU\Software\Wine\Explorer\Desktops' \
	/v Default /t REG_SZ /d "640x480" /f >/dev/null 2>&1 || true
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
	'HKCU\Software\Wine\Direct3D' \
	/v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true
```

Replace with:
```bash
# ─── Ephemeral WINEPREFIX + staging ──────────────────────────────────────────

echo "=== Wine staging ==="

# Create ephemeral prefix under /tmp
WINE_PREFIX="$(mktemp -d /tmp/wine-ra-XXXXXX)"
trap 'rm -rf "$WINE_PREFIX"' EXIT

# Stage directory inside the prefix
RA_STAGE="$WINE_PREFIX/drive_c/game"
mkdir -p "$RA_STAGE"

# Initialize the prefix
echo "  Prefix: $WINE_PREFIX"
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null

# Configure Wine GDI renderer + virtual desktop
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Explorer\Desktops' \
  /v Default /t REG_SZ /d "640x480" /f >/dev/null 2>&1 || true
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Direct3D' \
  /v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true

# Link MIX data into staging
for f in "$DATA_DIR"/*.MIX; do
  [[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done

# Write REDALERT.INI (intro skipping)
cat >"$RA_STAGE/REDALERT.INI" <<'INIEOF'
[Sound]
Card=0
Port=3F8h
IRQ=4
DMA=-1

[Options]
HardwareFills=no

[Intro]
PlayIntro=no
INIEOF

# Copy EXE into staging
cp "$RA_EXE_PATH" "$RA_STAGE/RA95.EXE"

# Use stub THIPX32.DLL
STUB_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/stub-thipx"
if [[ -f "$STUB_DIR/thipx32.dll" ]]; then
  cp "$STUB_DIR/thipx32.dll" "$RA_STAGE/THIPX32.DLL"
fi

echo "  Staging: $RA_STAGE"
echo ""
```

- [ ] **Step 4: Update the launch command (lines ~174-197)**

The launch section currently uses `$RA_STAGE` as CWD and `$WINE_PREFIX`. That's unchanged (the variable names stay the same, only their values changed to the ephemeral prefix). Verify the launch command reads:

```bash
(
  cd "$RA_STAGE"
  DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" \
    WINEDEBUG=-all AUDIODEV=null \
    timeout 45 wine RA95.EXE
) >"$LOG" 2>&1 &
```

This should still be correct — verify no changes needed.

- [ ] **Step 5: Run the script with game data to verify it works**

Run:
```bash
bash scripts/wine-ra.sh
```

Expected: resolves EXE from Nix store, creates prefix under `/tmp/wine-ra-*`, captures title/menu screenshots to `e2e/screenshots/`, cleans up prefix on exit. Verify `/tmp` is clean after.

- [ ] **Step 6: Commit**

```bash
git add scripts/wine-ra.sh
git commit -m "refactor: ephemeral WINEPREFIX + Nix store resolution in wine-ra.sh"
```

---

### Task 4: Core TD launch script — `scripts/wine-td.sh`

**Files (modify):** `scripts/wine-td.sh`

Same structural changes as Task 3 but for Tiberian Dawn. The `/opt/tiberiandawn/C&C95.EXE` default needs replacing.

- [ ] **Step 1: Read the full current script**

Run: `cat -n scripts/wine-td.sh`

- [ ] **Step 2: Replace argument defaults**

Current (around lines 39-44):
```bash
CC95_EXE_PATH="${1:-${CC95_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-td}"
DISPLAY_NUM="${WINE_DISPLAY:-:99}"
```

Replace with:
```bash
# Argument defaults: arg → env var → error
CC95_EXE_PATH="${1:-${CC95_EXE_PATH:-}}"
if [[ -z "$CC95_EXE_PATH" ]] || [[ ! -f "$CC95_EXE_PATH" ]]; then
  echo "ERROR: C&C95.EXE not found."
  echo "  Pass as first argument, set TD_EXE_PATH, or download manually."
  echo "  See: bash scripts/wine-td-setup.sh"
  exit 1
fi

DATA_DIR="${2:-${TD_ASSETS:-}}"
if [[ -z "$DATA_DIR" ]]; then
  echo "ERROR: TD game data directory not found."
  echo "  Pass as second argument or set TD_ASSETS."
  exit 1
fi

SCREENSHOT_DIR="${3:-e2e/screenshots}"
DISPLAY_NUM="${WINE_DISPLAY:-:99}"
```

Note: Unlike RA, there is no `.#td-patched-exe` Nix package. TD's EXE comes from manual download. The setup script (`wine-td-setup.sh`) handles this. So for TD there's no Nix auto-resolve — just env var or explicit path.

- [ ] **Step 3: Replace Wine prefix section**

Current uses `$HOME/.wine-td`. Replace with ephemeral prefix under `/tmp/wine-td-XXXXXX`, same pattern as Task 3 Step 3 (but with `TD_STAGE` and CONQUER.INI instead of REDALERT.INI).

The staging block currently (around lines ~70-105):
```bash
TD_STAGE="$(mktemp -d)"
trap 'rm -rf "$TD_STAGE"' EXIT
# Link MIX data ...
# Copy EXE ...
# CONQUER.INI ...
# Wine prefix init ...
```

Replace with ephemeral prefix pattern — same as Task 3 Step 3 but using:
- `WINE_PREFIX="$(mktemp -d /tmp/wine-td-XXXXXX)"`
- `TD_STAGE="$WINE_PREFIX/drive_c/game"`
- CONQUER.INI instead of REDALERT.INI
- Virtual desktop `640x400` (TD uses 640x400, RA uses 640x480)

- [ ] **Step 4: Run the script with game data to verify**

Run:
```bash
bash scripts/wine-td.sh
```

Expected: creates prefix under `/tmp/wine-td-*`, captures screenshots to `e2e/screenshots/`, cleans up.

- [ ] **Step 5: Commit**

```bash
git add scripts/wine-td.sh
git commit -m "refactor: ephemeral WINEPREFIX + env var resolution in wine-td.sh"
```

---

### Task 5: Setup scripts — `wine-ra-setup.sh` and `wine-td-setup.sh`

**Files (modify):**
- `scripts/wine-ra-setup.sh`
- `scripts/wine-td-setup.sh`

These are the "first-time setup" scripts that download EXEs from archive.org. Replace the download body with Nix store resolution. The Nix derivations already produce the patched EXEs.

- [ ] **Step 1: Edit `scripts/wine-ra-setup.sh`**

Current body: downloads RA95.EXE via HTTP range request to `/opt/redalert/`, verifies SHA, applies NoCD + DDSCL patches, downloads DLLs.

Replace the body with:

```bash
set -euo pipefail

echo "=== RA95.EXE + DLL resolution via Nix store ==="
echo ""

# Resolve ra-patched-exe from Nix store
RA_EXE=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || {
  echo "ERROR: Could not resolve ra-patched-exe from Nix store."
  echo "  Run from nix develop shell."
  exit 1
}

# Resolve DLLs
RA_THIPX32=$(nix build .#ra-thipx32-dll --impure --print-out-paths 2>/dev/null) || true
RA_THIPX16=$(nix build .#ra-thipx16-dll --impure --print-out-paths 2>/dev/null) || true

echo "  RA95.EXE:   $RA_EXE ($(stat -c%s "$RA_EXE") bytes)"
echo "  THIPX32.DLL: $RA_THIPX32"
echo "  THIPX16.DLL: $RA_THIPX16"
echo ""
echo "  The Nix derivation applies NoCD + DDSCL patches automatically."
echo "  No additional patching needed."
echo ""
echo "  To use with wine-ra.sh:"
echo "    bash scripts/wine-ra.sh \"$RA_EXE\""
```

Keep the top comments documenting the old manual download approach for non-Nix users (wrap in a comment block).

- [ ] **Step 2: Edit `scripts/wine-td-setup.sh`**

Same pattern but for TD. Note: there is no `.#td-patched-exe` Nix package yet (TD patches are applied manually). Resolve what's available:

```bash
set -euo pipefail

echo "=== C&C95.EXE + DLL resolution via Nix store ==="
echo ""

# Check if EXE path was passed or set via env var
CC95_EXE_PATH="${1:-${CC95_EXE_PATH:-}}"
if [[ -z "$CC95_EXE_PATH" ]]; then
  echo "ERROR: C&C95.EXE path not provided."
  echo "  Usage: bash scripts/wine-td-setup.sh <path-to-C&C95.EXE>"
  echo ""
  echo "  C&C95.EXE must be extracted from the C&C Gold ZIP."
  echo "  See the script header for manual download instructions."
  exit 1
fi

if [[ ! -f "$CC95_EXE_PATH" ]]; then
  echo "ERROR: File not found: $CC95_EXE_PATH"
  exit 1
fi

echo "  C&C95.EXE: $CC95_EXE_PATH ($(stat -c%s "$CC95_EXE_PATH") bytes)"
echo ""
echo "  To use with wine-td.sh:"
echo "    bash scripts/wine-td.sh \"$CC95_EXE_PATH\""
```

Keep the top comments documenting the old manual ZIP download approach.

- [ ] **Step 3: Verify both scripts work**

Run:
```bash
bash scripts/wine-ra-setup.sh
# Expected: resolves from Nix store, prints paths, no /opt mentioned

bash scripts/wine-td-setup.sh
# Expected: asks for path (since no Nix package for TD EXE yet)
```

- [ ] **Step 4: Commit**

```bash
git add scripts/wine-ra-setup.sh scripts/wine-td-setup.sh
git commit -m "refactor: replace /opt download with Nix store resolution in setup scripts"
```

---

### Task 6: Campaign capture scripts — RA side (4 files)

**Files (modify):**
- `scripts/wine-allied-l1.sh`
- `scripts/wine-allied-m2.sh`
- `scripts/wine-soviet-l1.sh`
- `scripts/wine-soviet-m2.sh`

Each campaign script follows the same structure as `wine-ra.sh` but with autostart INI injection and different timing. The `/opt/redalert/game/RA95.EXE.focus_orig` and `/opt/redalert/game` DLL dir defaults must be replaced.

- [ ] **Step 1: Edit `scripts/wine-allied-l1.sh`**

This script is the model for all RA campaign scripts. Current defaults:
```bash
RA_EXE_PATH="${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE.focus_orig}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
```

Replace with:
```bash
RA_EXE_PATH="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE_PATH" ]]; then
  RA_EXE_PATH=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE_PATH" ]] || [[ ! -f "$RA_EXE_PATH" ]]; then
  echo "ERROR: RA95.EXE not found. Set RA_EXE_PATH or run from nix develop."
  exit 1
fi
# DLL dir is same directory as the EXE
RA_DLL_DIR="$(dirname "$RA_EXE_PATH")"
```

The campaign script currently creates its own staging dir (named `$STAGE` or with `mktemp`). Replace that with the ephemeral WINEPREFIX pattern: create prefix under `/tmp/wine-ra-XXXXXX`, use `drive_c/game/` as staging, init prefix, apply registry settings, stage EXE + DLLs + MIX data, launch, capture.

The autostart INI logic (writing `SC*.INI` and `RA_AUTOSTART_SCENARIO.FLAG`) stays the same — only the staging mechanism changes.

- [ ] **Step 2: Apply the same changes to `wine-allied-m2.sh`**

Same pattern as Step 1. Read the file first to check for any mission-specific differences, then apply the same EXE resolution + ephemeral prefix changes.

- [ ] **Step 3: Apply the same changes to `wine-soviet-l1.sh`**

Same pattern.

- [ ] **Step 4: Apply the same changes to `wine-soviet-m2.sh`**

Same pattern.

- [ ] **Step 5: Verify one RA campaign script works**

Run:
```bash
bash scripts/wine-allied-l1.sh
```

Expected: resolves EXE from Nix store, creates ephemeral prefix under `/tmp/wine-ra-*`, captures Allied L1 gameplay screenshot, cleans up. If no game data available, verify it fails gracefully with a clear error message.

- [ ] **Step 6: Commit**

```bash
git add scripts/wine-allied-l1.sh scripts/wine-allied-m2.sh \
       scripts/wine-soviet-l1.sh scripts/wine-soviet-m2.sh
git commit -m "refactor: ephemeral WINEPREFIX + Nix resolution in RA campaign scripts"
```

---

### Task 7: Campaign capture scripts — TD side (4 files)

**Files (modify):**
- `scripts/wine-gdi-m1.sh`
- `scripts/wine-gdi-m2.sh`
- `scripts/wine-nod-l1.sh`
- `scripts/wine-nod-m1.sh`

Same pattern as Task 6 but for TD. The TD campaign scripts currently default to `/opt/tiberiandawn/C&C95.EXE` and `/opt/tiberiandawn` DLL dir.

- [ ] **Step 1: Edit `scripts/wine-gdi-m1.sh`**

Current defaults:
```bash
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
```

Replace with:
```bash
TD_EXE_PATH="${1:-${TD_EXE_PATH:-}}"
if [[ -z "$TD_EXE_PATH" ]] || [[ ! -f "$TD_EXE_PATH" ]]; then
  echo "ERROR: C&C95.EXE not found. Set TD_EXE_PATH or pass as first argument."
  exit 1
fi
# DLL dir is same directory as the EXE
TD_DLL_DIR="$(dirname "$TD_EXE_PATH")"
```

Replace the staging dir with ephemeral WINEPREFIX under `/tmp/wine-td-XXXXXX`, same pattern as Task 6. The TD prefix uses 640x400 virtual desktop (not 640x480), and the GDI renderer setting is the same.

- [ ] **Step 2: Apply the same changes to the remaining 3 TD scripts**

`wine-gdi-m2.sh`, `wine-nod-l1.sh`, `wine-nod-m1.sh` — same pattern.

- [ ] **Step 3: Verify one TD campaign script works**

Run:
```bash
bash scripts/wine-gdi-m1.sh
```

Expected: clean error if EXE not found, or runs with ephemeral prefix if EXE is available.

- [ ] **Step 4: Commit**

```bash
git add scripts/wine-gdi-m1.sh scripts/wine-gdi-m2.sh \
       scripts/wine-nod-l1.sh scripts/wine-nod-m1.sh
git commit -m "refactor: ephemeral WINEPREFIX + env var resolution in TD campaign scripts"
```

---

### Task 8: Other capture/utility scripts (4 files)

**Files (modify):**
- `scripts/wine-cnc-capture.sh`
- `scripts/wine-vqa-capture.sh`
- `scripts/wine-gameplay.sh`
- `scripts/wine-ra-difficulty-capture.sh`

- [ ] **Step 1: Edit `scripts/wine-cnc-capture.sh`**

Current default (line ~18):
```bash
RA_EXE="${1:-/opt/redalert/RA95.EXE}"
DATA_DIR="${2:-/mnt/redalert}"
```

Replace with:
```bash
RA_EXE="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE" ]]; then
  RA_EXE=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE" ]] || [[ ! -f "$RA_EXE" ]]; then
  echo "ERROR: RA95.EXE not found. Set RA_EXE_PATH or run from nix develop."
  exit 1
fi

DATA_DIR="${2:-${RA_ASSETS:-}}"
if [[ -z "$DATA_DIR" ]]; then
  echo "ERROR: RA game data directory not found. Set RA_ASSETS."
  exit 1
fi
```

This script already uses a staging dir (`STAGE` variable) — replace that with ephemeral WINEPREFIX under `/tmp/wine-cnc-XXXXXX` (same pattern as Task 3 Step 3). The `nix build .#cnc-ddraw` call is already correct — no `/opt` there.

- [ ] **Step 2: Edit `scripts/wine-vqa-capture.sh`**

Current defaults:
```bash
RA_EXE_PATH="${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE.focus_orig}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
```

Replace with Nix store resolution (same pattern as Task 6 Step 1). Replace staging dir with ephemeral WINEPREFIX.

- [ ] **Step 3: Edit `scripts/wine-gameplay.sh`**

Current defaults:
```bash
RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE}}"
DATA_DIR="${2:-/opt/redalert/game}"
```

Replace with Nix store resolution + env var fallback. Replace staging with ephemeral WINEPREFIX.

- [ ] **Step 4: Edit `scripts/wine-ra-difficulty-capture.sh`**

Current defaults:
```bash
RA_EXE="${RA_EXE:-/opt/redalert/game/RA95.EXE}"
DLL_DIR="${DLL_DIR:-/opt/redalert/game}"
```

Replace with Nix store resolution + env var fallback. Replace staging with ephemeral WINEPREFIX.

- [ ] **Step 5: Verify no `/opt` in any of the 4 files**

Run:
```bash
for f in scripts/wine-cnc-capture.sh scripts/wine-vqa-capture.sh \
         scripts/wine-gameplay.sh scripts/wine-ra-difficulty-capture.sh; do
  if grep -q '/opt/' "$f"; then echo "FAIL: $f still has /opt"; else echo "OK: $f clean"; fi
done
```

- [ ] **Step 6: Commit**

```bash
git add scripts/wine-cnc-capture.sh scripts/wine-vqa-capture.sh \
       scripts/wine-gameplay.sh scripts/wine-ra-difficulty-capture.sh
git commit -m "refactor: ephemeral WINEPREFIX in remaining capture/utility scripts"
```

---

### Task 9: `scripts/build-stub-thipx.sh` — remove hardcoded `/opt`

**Files (modify):** `scripts/build-stub-thipx.sh`

- [ ] **Step 1: Edit the script**

Current reference (line ~39):
```bash
RA_EXE="/opt/redalert/game/RA95.EXE.orig"
```

And lines ~48-49:
```bash
install -m 644 "$OUT" /opt/redalert/game/THIPX32.DLL 2>/dev/null || true
echo "  /opt/redalert/game/THIPX32.DLL"
```

The script builds a stub `THIPX32.DLL` and installs it next to a (non-existent under new scheme) RA95.EXE. Change to install to a user-provided directory:

```bash
INSTALL_DIR="${1:-}"
if [[ -z "$INSTALL_DIR" ]]; then
  echo "Usage: $0 <install-dir>"
  echo "  Builds stub THIPX32.DLL and installs to <install-dir>/"
  echo "  Example: $0 /tmp/ra-stage"
  exit 1
fi
```

Replace the install lines with:
```bash
install -m 644 "$OUT" "$INSTALL_DIR/THIPX32.DLL"
echo "  $INSTALL_DIR/THIPX32.DLL"
```

And remove the `RA_EXE="/opt/redalert/game/RA95.EXE.orig"` line entirely (it was only used as a reference for the install location).

- [ ] **Step 2: Verify**

Run: `grep -n '/opt' scripts/build-stub-thipx.sh`
Expected: no output (no matches).

- [ ] **Step 3: Commit**

```bash
git add scripts/build-stub-thipx.sh
git commit -m "refactor: remove /opt from build-stub-thipx.sh, require install dir arg"
```

---

### Task 10: Grep audit and CI gate

**Files (modify):**
- `.github/workflows/ci.yml` (or add a step to `scripts/ci-local.sh`)

- [ ] **Step 1: Run the full grep audit**

Run the Phase 1 commands from the spec:

```bash
echo "=== RA paths ==="
rg -n '/opt/redalert' --include='*.sh' --include='*.py' --include='*.cpp' \
  | grep -v 'docs/' | grep -v 'installer/' || echo "(clean)"

echo "=== TD paths ==="
rg -n '/opt/tiberiandawn' --include='*.sh' --include='*.py' --include='*.cpp' \
  | grep -v 'docs/' | grep -v 'installer/' || echo "(clean)"
```

Expected: zero hits in `scripts/`. If any remain, go back and fix them.

- [ ] **Step 2: Add CI gate to `scripts/ci-local.sh`**

Add a check at the end of `scripts/ci-local.sh` (or to `scripts/ci-wasm-smoke.sh` if more appropriate):

```bash
# ── Phase 6: /opt audit ──────────────────────────────────────────────────
echo ""
echo "=== /opt path audit ==="
if rg -q '/opt/(redalert|tiberiandawn)' scripts/ 2>/dev/null; then
  echo "FAIL: scripts/ still contains /opt/redalert or /opt/tiberiandawn"
  rg -n '/opt/(redalert|tiberiandawn)' scripts/
  ERRORS=$((ERRORS + 1))
else
  echo "  OK: no /opt paths in scripts/"
fi
```

- [ ] **Step 3: Run `ci_local` to verify**

Run:
```bash
ci_local
```

Expected: passes all gates including the new /opt audit step.

- [ ] **Step 4: Commit**

```bash
git add scripts/ci-local.sh
git commit -m "ci: add /opt path audit gate to ci-local.sh"
```

---

### Task 11: Documentation updates

**Files (modify):**
- `skills/wine-testing/SKILL.md`
- `tools/wine-input/README.md`

- [ ] **Step 1: Update `skills/wine-testing/SKILL.md`**

Grep for `/opt` references:
```bash
grep -n '/opt' skills/wine-testing/SKILL.md
```

Update any example commands that reference `/opt/redalert` or `/opt/tiberiandawn`. The skill should document the new workflow: ephemeral WINEPREFIX + Nix store resolution. Key changes:
- Example `cp /opt/redalert/RA95.EXE ...` → reference Nix store paths
- Remove instructions that assume data lives in `/opt`

- [ ] **Step 2: Update `tools/wine-input/README.md`**

Replace `/opt/wine-devel/bin/wine` references with `wine` (the standard PATH resolution in the Nix dev shell).

- [ ] **Step 3: Commit**

```bash
git add skills/wine-testing/SKILL.md tools/wine-input/README.md
git commit -m "docs: update /opt references in Wine skill and tools README"
```

---

### Self-review checklist

After writing all tasks, verify:

- [ ] **Spec coverage:** Does every section of the design doc have a corresponding task?
  - Section 1 (EXE resolution): Tasks 3, 4, 5, 6, 7, 8
  - Section 2 (ephemeral WINEPREFIX): Tasks 3, 4, 6, 7, 8
  - Section 3 (patch script defaults): Tasks 1, 2
  - Section 4 (file inventory): All tasks covered 37 files
  - Section 5 (non-goals): Installer, wine-devel, CI — correctly excluded
  - Section 6 (success criteria): Covered by verification tasks
  - Section 7 (verification): Task 10 (grep audit + CI gate), Task 11 (docs)

- [ ] **Placeholder scan:** No "TBD", "TODO", "add appropriate handling" in any task. Every code block is concrete.

- [ ] **No `/opt` references in new code:** All the replacement code blocks use `nix build --print-out-paths` or env vars, never `/opt`.
