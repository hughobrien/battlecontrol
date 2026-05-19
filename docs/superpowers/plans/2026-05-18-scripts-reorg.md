# Scripts Reorganization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the flat `scripts/` directory into game-specific `ra/` and `td/` subdirectories and update all active references.

**Architecture:** Pure file move + reference update. No functional changes, no new files. `flake.nix` needs no changes (it only references shared scripts). Historical/archival docs (e2e/tim* notes, docs/tim* findings, completed plans) are frozen snapshots and should NOT have their references updated.

**Tech Stack:** bash, git mv, sed

---

### Task 1: Move RA-specific scripts to `scripts/ra/`

**Files:**
- Modify: `scripts/` (move out)
- Create: `scripts/ra/`

- [ ] **Step 1: Create `scripts/ra/` directory and git-move RA scripts**

```bash
mkdir -p scripts/ra
git mv scripts/ra-autostart-patch.py scripts/ra/
git mv scripts/ra-scenario-patch.py scripts/ra/
git mv scripts/wine-ra.sh scripts/ra/
```

- [ ] **Step 2: Verify**

```bash
ls -la scripts/ra/
# Should show: ra-autostart-patch.py, ra-scenario-patch.py, wine-ra.sh
```

---

### Task 2: Move TD-specific scripts to `scripts/td/`

**Files:**
- Modify: `scripts/` (move out)
- Create: `scripts/td/`

- [ ] **Step 1: Create `scripts/td/` directory and git-move TD scripts**

```bash
mkdir -p scripts/td
git mv scripts/td-activateapp-patch.py scripts/td/
git mv scripts/td-ddmode-patch.py scripts/td/
git mv scripts/td-focus-skip-patch.py scripts/td/
git mv scripts/td-game-in-focus-patch.py scripts/td/
git mv scripts/td-ioport-patch.py scripts/td/
git mv scripts/td-scenario-patch.py scripts/td/
git mv scripts/td-setcoop-hwnd-patch.py scripts/td/
git mv scripts/td-side-preview-skip-patch.py scripts/td/
git mv scripts/td-vqa-skip-patch.py scripts/td/
git mv scripts/wine-td.sh scripts/td/
git mv scripts/wine-gdi-m1.sh scripts/td/
git mv scripts/wine-gdi-m2.sh scripts/td/
git mv scripts/wine-nod-l1.sh scripts/td/
git mv scripts/wine-nod-m1.sh scripts/td/
git mv scripts/setup-run-td.sh scripts/td/
git mv scripts/run-td-cheat.sh scripts/td/
```

- [ ] **Step 2: Verify**

```bash
ls -la scripts/td/
# Should show all 16 files
```

---

### Task 3: Move regression scripts to `scripts/{ra,td}/regression/`

**Files:**
- Modify: `scripts/regression/` (move out)
- Create: `scripts/ra/regression/`, `scripts/td/regression/`

- [ ] **Step 1: Create subdirs and move regression scripts**

```bash
mkdir -p scripts/ra/regression scripts/td/regression
git mv scripts/regression/T11-ra-native-m2-smoke.sh scripts/ra/regression/
git mv scripts/regression/T6-ra-native-smoke.sh scripts/ra/regression/
git mv scripts/regression/T12-td-native-m2-smoke.sh scripts/td/regression/
git mv scripts/regression/T5-td-native-menu.sh scripts/td/regression/
```

- [ ] **Step 2: Remove empty regression directory**

```bash
git rm scripts/regression/__pycache__ 2>/dev/null || true  # if pycache exists
git rmdir scripts/regression 2>/dev/null || rmdir scripts/regression
```

---

### Task 4: Update `scripts/test-runner.sh`

**Files:**
- Modify: `scripts/test-runner.sh` (lines 113-121)

- [ ] **Step 1: Update path references in test-runner.sh**

Replace `scripts/regression/` with `scripts/ra/regression/` and `scripts/td/regression/`, and `scripts/run-td-cheat.sh` with `scripts/td/run-td-cheat.sh`:

Line 113: `run_script scripts/regression/T6-ra-native-smoke.sh`
 → `run_script scripts/ra/regression/T6-ra-native-smoke.sh`

Line 114: `run_script scripts/regression/T11-ra-native-m2-smoke.sh`
 → `run_script scripts/ra/regression/T11-ra-native-m2-smoke.sh`

Line 118: `run_script scripts/run-td-cheat.sh`
 → `run_script scripts/td/run-td-cheat.sh`

Line 120: `run_script scripts/regression/T5-td-native-menu.sh`
 → `run_script scripts/td/regression/T5-td-native-menu.sh`

Line 121: `run_script scripts/regression/T12-td-native-m2-smoke.sh`
 → `run_script scripts/td/regression/T12-td-native-m2-smoke.sh`

---

### Task 5: Update `scripts.md`

**Files:**
- Modify: `scripts.md`

- [ ] **Step 1: Update RA script paths**

Lines 56, 119-120 — prefix `ra/` to these paths:
- `scripts/wine-ra.sh` → `scripts/ra/wine-ra.sh`
- `scripts/ra-scenario-patch.py` → `scripts/ra/ra-scenario-patch.py`
- `scripts/ra-autostart-patch.py` → `scripts/ra/ra-autostart-patch.py`

- [ ] **Step 2: Update TD script paths**

Lines 57-61, 104, 124-132 — prefix `td/` to these paths:
- `scripts/wine-td.sh` → `scripts/td/wine-td.sh`
- `scripts/wine-gdi-m1.sh` → `scripts/td/wine-gdi-m1.sh`
- `scripts/wine-gdi-m2.sh` → `scripts/td/wine-gdi-m2.sh`
- `scripts/wine-nod-l1.sh` → `scripts/td/wine-nod-l1.sh`
- `scripts/wine-nod-m1.sh` → `scripts/td/wine-nod-m1.sh`
- `scripts/setup-run-td.sh` → `scripts/td/setup-run-td.sh`
- `scripts/td-focus-skip-patch.py` → `scripts/td/td-focus-skip-patch.py`
- `scripts/td-game-in-focus-patch.py` → `scripts/td/td-game-in-focus-patch.py`
- `scripts/td-vqa-skip-patch.py` → `scripts/td/td-vqa-skip-patch.py`
- `scripts/td-activateapp-patch.py` → `scripts/td/td-activateapp-patch.py`
- `scripts/td-ddmode-patch.py` → `scripts/td/td-ddmode-patch.py`
- `scripts/td-setcoop-hwnd-patch.py` → `scripts/td/td-setcoop-hwnd-patch.py`
- `scripts/td-ioport-patch.py` → `scripts/td/td-ioport-patch.py`
- `scripts/td-scenario-patch.py` → `scripts/td/td-scenario-patch.py`
- `scripts/td-side-preview-skip-patch.py` → `scripts/td/td-side-preview-skip-patch.py`

---

### Task 6: Update `AGENTS.md`

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update RA script references**

Replace `scripts/wine-ra.sh` with `scripts/ra/wine-ra.sh`

- [ ] **Step 2: Update TD script references**

Replace `scripts/wine-td.sh` with `scripts/td/wine-td.sh`

- [ ] **Step 3: Update driver references**

Verify `scripts/drivers/*.py` references — these stay unchanged (drivers are shared).

---

### Task 7: Update `AGENT-FLOW.md`

**Files:**
- Modify: `AGENT-FLOW.md`

- [ ] **Step 1: Update setup-run-td path**

Line 70: `scripts/setup-run-td.sh` → `scripts/td/setup-run-td.sh`

---

### Task 8: Update `ARCH.md`

**Files:**
- Modify: `ARCH.md`

- [ ] **Step 1: Update TD script paths**

Lines 142, 149, 170, 187, 188 — replace:
- `scripts/run-td-cheat.sh` → `scripts/td/run-td-cheat.sh`
- `scripts/setup-run-td.sh` → `scripts/td/setup-run-td.sh`

---

### Task 9: Update skill files

**Files:**
- Modify: `skills/wine-testing/SKILL.md`
- Modify: `skills/parity-comparison/SKILL.md`
- Modify: `skills/redalert-modding/SKILL.md`
- Modify: `skills/native-build/SKILL.md`
- Modify: `skills/ci-cd/SKILL.md`

- [ ] **Step 1: Update `skills/wine-testing/SKILL.md`**

Replace:
- `scripts/wine-ra.sh` → `scripts/ra/wine-ra.sh`
- `scripts/ra-scenario-patch.py` → `scripts/ra/ra-scenario-patch.py`
- `scripts/ra-autostart-patch.py` → `scripts/ra/ra-autostart-patch.py`
- `scripts/wine-td.sh` → `scripts/td/wine-td.sh`

- [ ] **Step 2: Update `skills/parity-comparison/SKILL.md`**

Replace:
- `scripts/wine-ra.sh` → `scripts/ra/wine-ra.sh`
- `scripts/wine-td.sh` → `scripts/td/wine-td.sh`

- [ ] **Step 3: Update `skills/redalert-modding/SKILL.md`**

Replace:
- `scripts/ra-scenario-patch.py` → `scripts/ra/ra-scenario-patch.py`

- [ ] **Step 4: Update `skills/native-build/SKILL.md`**

Replace:
- `scripts/setup-run-td.sh` → `scripts/td/setup-run-td.sh`

- [ ] **Step 5: Update `skills/ci-cd/SKILL.md`**

Replace:
- `scripts/run-td-cheat.sh` → `scripts/td/run-td-cheat.sh`

---

### Task 10: Update `e2e/regression/README.md`

**Files:**
- Modify: `e2e/regression/README.md`

- [ ] **Step 1: Update regression script paths and references**

Replace:
- `scripts/regression/T5-td-native-menu.sh` → `scripts/td/regression/T5-td-native-menu.sh`
- `scripts/regression/T6-ra-native-smoke.sh` → `scripts/ra/regression/T6-ra-native-smoke.sh`
- Reference to `scripts/regression/` → `scripts/{ra,td}/regression/` (line 169)

---

### Task 11: Update docs/superpowers/{specs,plans} that reference moved scripts

**Note:** Only update active/current specs and plans. Historical/completed plans are frozen snapshots.

- [ ] **Step 1: Check and update current specs referencing TD cheat script**

Files to check: `docs/superpowers/specs/2026-05-18-dev-cycle-simplification*-design.md`
Replacement: `scripts/run-td-cheat.sh` → `scripts/td/run-td-cheat.sh`

- [ ] **Step 2: Update the reorg design doc itself** (current doc that will be read by future agents)

File: `docs/superpowers/specs/2026-05-18-scripts-reorg-design.md`
Replace references to reflect moved paths (RA/TD script paths).

---

### Task 12: Verify everything

- [ ] **Step 1: Check git status**

```bash
git status
git diff --stat
```

Expected: all moved files listed as renamed, modified files show only path changes.

- [ ] **Step 2: Run lint**

```bash
nix run .#lint
```

Expected: pass (flake.nix unchanged, only path updates in docs).

- [ ] **Step 3: Run a quick sanity check for stale references**

```bash
# Check for any remaining references to old paths
grep -rn "scripts/regression/T" --include="*.md" . --exclude-dir=.git
grep -rn "scripts/run-td-cheat.sh" --include="*.sh" . --exclude-dir=.git  
```

Expected: zero matches in active files (only historical docs are fine).
