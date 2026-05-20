# Native RA Autostart for Headless Screenshot Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable headless screenshot capture (via `capture-checkpoint.py`) from the native Linux RA build by wiring the `RA_AUTOSTART_SCENARIO` env var and fixing the driver's working directory.

**Architecture:** Two independent changes: (1) a 3-line C++ addition in `REDALERT/INIT.CPP` to read the scenario name from `getenv("RA_AUTOSTART_SCENARIO")`, and (2) a driver fix in `scripts/drivers/native.py` to launch RA with `cwd` set to the data directory.

**Tech Stack:** C++ (Red Alert source), Python (capture driver), Nix (build)

---

### Task 1: Wire `RA_AUTOSTART_SCENARIO` env var in INIT.CPP

**Files:**
- Modify: `REDALERT/INIT.CPP:759-779`

- [ ] **Step 1: Add getenv check before the flag file block**

Insert a `getenv("RA_AUTOSTART_SCENARIO")` check right before the existing `RA_AUTOSTART_SCENARIO.FLAG` block (before line 762). If the env var is set and non-empty, call `Scen.Set_Scenario_Name()` with its value. The existing flag file block stays unchanged — if the flag file exists it will overwrite whatever the env var set (flag file wins as the more-specific override).

Edit `REDALERT/INIT.CPP` to add before line 762:

```cpp
			/* TIM-857: RA_AUTOSTART_SCENARIO env var — override autostart mission. */
			{
				const char* envScen = getenv("RA_AUTOSTART_SCENARIO");
				if (envScen && envScen[0]) {
					fprintf(stderr, "[RA] RA_AUTOSTART_SCENARIO=%s → overriding scenario\n", envScen); fflush(stderr);
					Scen.Set_Scenario_Name(envScen);
				}
			}
```

- [ ] **Step 2: Verify the source compiles**

```bash
nix build '.#redalert' --impure 2>&1 | tail -10
```

Expected: build succeeds (store path printed, no errors).

- [ ] **Step 3: Commit**

```bash
git add REDALERT/INIT.CPP
git commit -m "feat: wire RA_AUTOSTART_SCENARIO env var in native RA build

Add getenv(\"RA_AUTOSTART_SCENARIO\") check in INIT.CPP alongside the
existing RA_AUTOSTART_SCENARIO.FLAG file check. Flag file still wins
if both are set (more specific override).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Fix native driver to set cwd to data directory

**Files:**
- Modify: `scripts/drivers/native.py:45-54`

- [ ] **Step 1: Update capture_mission to use cwd and drop DATA_DIR**

In `scripts/drivers/native.py`, change the `capture_mission` method to pass `cwd=self.data_dir` to `subprocess.Popen` and drop the unused `DATA_DIR` env var.

Current code (lines 45-54):

```python
            env = {
                **os.environ,
                "DISPLAY": disp,
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
            }
            if self.data_dir:
                env["DATA_DIR"] = self.data_dir
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)], env=env, stdout=logfile, stderr=logfile
            )
```

Replace with:

```python
            env = {
                **os.environ,
                "DISPLAY": disp,
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
            }
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)], env=env, cwd=str(self.data_dir),
                stdout=logfile, stderr=logfile
            )
```

- [ ] **Step 2: Run native capture to verify it works**

```bash
cd /home/hugh/battlecontrol
rm -rf e2e/checkpoints/mission-allied-l1 /home/hugh/.cache/battlecontrol/wine-capture-*
rm -f /tmp/.X{70,85,90,92,93,94,95,96,97,98,99}-lock /tmp/.X11-unix/X{70,85,90,92,93,94,95,96,97,98,99} 2>/dev/null

RA_BIN=$(nix build '.#redalert' --impure --print-out-paths 2>/dev/null)/bin/redalert \
  DATA_DIR=/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 \
  python3 scripts/capture-checkpoint.py mission allied-l1 --frame 50 --targets native 2>&1
```

Expected output: `OK native: e2e/checkpoints/mission-allied-l1/native/capture.png` with a file size ≥5KB.

```bash
python3 -c "
from PIL import Image
import numpy as np
img = Image.open('e2e/checkpoints/mission-allied-l1/native/capture.png').convert('RGB')
arr = np.array(img)
print(f'Size: {img.size}, non-black: {np.any(arr > 15, axis=2).mean() * 100:.1f}%')
print(f'Colors: {len(np.unique(arr.reshape(-1,3), axis=0))}')
"
```

Expected: non-black ≥5%, colors ≥100 (real game content, not a blank screen).

- [ ] **Step 3: Run full wine-vs-native parity comparison**

```bash
cd /home/hugh/battlecontrol
rm -rf e2e/checkpoints/mission-allied-l1 /home/hugh/.cache/battlecontrol/wine-capture-*

RA_BIN=$(nix build '.#redalert' --impure --print-out-paths 2>/dev/null)/bin/redalert \
  DATA_DIR=/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 \
  python3 scripts/capture-checkpoint.py mission allied-l1 --frame 50 --targets wine,native 2>&1
```

Expected: both `OK wine` and `OK native`, followed by SSIM comparison results (PASS/FAIL).

- [ ] **Step 4: Commit**

```bash
git add scripts/drivers/native.py
git commit -m "fix: set native RA cwd to data directory for headless capture

RA binary finds MIX files relative to CWD, not via DATA_DIR env var.
Add cwd=self.data_dir to Popen call and drop the unused DATA_DIR env var.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```
