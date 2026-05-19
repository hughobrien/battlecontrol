# Native RA Autostart — Headless Screenshot Capture

## Problem

The native Linux RA build (`nix build .#redalert`) cannot be used for headless screenshot capture. The `NativeCapture` driver (`scripts/drivers/native.py`) fails with "native RA never rendered non-black canvas" because:

1. The native RA binary finds game data (MIX files) by current working directory, not the `DATA_DIR` env var — but the driver launches it without setting `cwd`.
2. The `RA_AUTOSTART_SCENARIO` env var is set by the driver but the source code (`REDALERT/INIT.CPP`) only reads scenario overrides from a `RA_AUTOSTART_SCENARIO.FLAG` file, not the environment.

The Wine OG path already works reliably. Adding native RA capture enables wine-vs-native parity comparison.

## Changes

### 1. Source: `REDALERT/INIT.CPP` — wire `RA_AUTOSTART_SCENARIO` env var

Location: `INIT.CPP` lines 730–779 (`#ifndef _MSC_VER` autostart block).

Before the existing `RA_AUTOSTART_SCENARIO.FLAG` file check, add a `getenv("RA_AUTOSTART_SCENARIO")` check with the same logic. If the flag file also exists, the flag file wins (more specific override).

The block currently reads:

```cpp
/* TIM-812: ?scenario=SCU02EA URL param — override the autostart mission. */
{
    RawFileClass scenFile("RA_AUTOSTART_SCENARIO.FLAG");
    if (scenFile.Is_Available()) {
        char scenBuf[32] = {};
        scenFile.Open(READ);
        scenFile.Read(scenBuf, sizeof(scenBuf) - 1);
        scenFile.Close();
        for (int si = 0; scenBuf[si]; si++) {
            if (scenBuf[si] == '\n' || scenBuf[si] == '\r' || scenBuf[si] == ' ') {
                scenBuf[si] = '\0'; break;
            }
        }
        Scen.Set_Scenario_Name(scenBuf);
    }
}
```

The `getenv` addition goes just before the `RawFileClass` check, same `scenBuf` pattern. The flag file block remains unchanged — if the flag file exists it overwrites whatever the env var set.

### 2. Driver: `scripts/drivers/native.py` — set cwd + pass RA_AUTOSTART_SCENARIO

In `NativeCapture.capture_mission`:

- Add `cwd=self.data_dir` to the `subprocess.Popen` call so RA finds MIX files from the data directory.
- Drop the unused `DATA_DIR` env var (the binary doesn't read it).
- Keep `RA_AUTOSTART=1` and `RA_AUTOSTART_SCENARIO` in the env (the source change wires the latter).

## Testing

After both changes:

```bash
cd /home/hugh/battlecontrol
rm -rf e2e/checkpoints/mission-allied-l1
RA_BIN=/nix/store/...-redalert/bin/redalert \
  DATA_DIR=/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 \
  python3 scripts/capture-checkpoint.py mission allied-l1 --frame 50 --targets native
```

Expected result: `OK native: e2e/checkpoints/mission-allied-l1/native/capture.png` with a non-black image (≥5KB, ≥18% non-black pixels).

Full wine-vs-native parity comparison:

```bash
RA_BIN=... DATA_DIR=... python3 scripts/capture-checkpoint.py \
  mission allied-l1 --frame 50 --targets wine,native
```

## Files changed

| File | Change |
|------|--------|
| `REDALERT/INIT.CPP` | Add `getenv("RA_AUTOSTART_SCENARIO")` before flag file check |
| `scripts/drivers/native.py` | Add `cwd=self.data_dir` to Popen; drop unused `DATA_DIR` env var |
