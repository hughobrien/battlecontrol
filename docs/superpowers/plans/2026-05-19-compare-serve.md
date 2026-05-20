# Compare Output Dir & HTTP Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modify `capture-checkpoint.py` to write timestamped session directories under `/tmp/battlecontrol/` and auto-start an HTTP server for browser review.

**Architecture:** Three focused changes in one file: (1) timestamped session dir as output root, (2) flatten captures and diffs into that dir, (3) background HTTP server on port 1234. No changes to the driver classes or compare library.

**Tech Stack:** Python 3, standard library only (socket, subprocess, time, pathlib)

---

### Task 1: Compute and create timestamped session directory

**Files:**
- Modify: `scripts/capture-checkpoint.py:59,75`

Current code creates a fixed checkpoint dir at `output_root / f"{args.type}-{args.id}"`. Change this to a timestamped dir under `/tmp/battlecontrol/`.

- [ ] **Step 1: Change default output to `/tmp/battlecontrol`**

At line 59, change the default:
```python
    ap.add_argument("--output", default="/tmp/battlecontrol", help="output root directory")
```

- [ ] **Step 2: Replace checkpoint_dir initialization**

Replace the existing `checkpoint_dir` computation (currently `output_root / f"{args.type}-{args.id}"`) with a timestamped session dir:

```python
    timestamp = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
    session_base = f"{timestamp}-{args.type}-{args.id}"
    checkpoint_dir = output_root / session_base
```

Insert this right after the dry-run block (after `if args.dry_run: ... return`), before `checkpoint_dir.mkdir(...)`.

Remove the existing `checkpoint_dir` computation line: `checkpoint_dir = output_root / f"{args.type}-{args.id}"` (currently at line 75 with the comment `# Boot capture types ...` following it).

- [ ] **Step 3: Handle duplicate timestamps and fallback**

After `checkpoint_dir` is computed, add dedup and a try/around around creation:

```python
    if checkpoint_dir.exists():
        suffix = 1
        while (output_root / f"{session_base}-{suffix}").exists():
            suffix += 1
        checkpoint_dir = output_root / f"{session_base}-{suffix}"

    # Wrap dir creation in fallback to legacy path
    try:
        checkpoint_dir.mkdir(parents=True, exist_ok=False)
    except (OSError, PermissionError):
        checkpoint_dir = pathlib.Path(f"e2e/checkpoints/{args.type}-{args.id}")
        checkpoint_dir.mkdir(parents=True, exist_ok=True)

Also remove the old `checkpoint_dir.mkdir(parents=True, exist_ok=True)` line (currently at line 107), since creation is now handled above.
```

---

### Task 2: Flatten capture output

**Files:**
- Modify: `scripts/capture-checkpoint.py:111-146`

Currently each target captures to `<target_dir>/capture.png`. Change to capture to the session dir directly, then rename to `<target>.png`.

- [ ] **Step 1: Remove target subdir creation, capture directly to session dir**

Replace:
```python
    for target in targets:
        target_dir = checkpoint_dir / target
        target_dir.mkdir(parents=True, exist_ok=True)
        log_path = target_dir / "driver.log"
```

With:
```python
    for target in targets:
        target_dir = checkpoint_dir
        log_path = checkpoint_dir / f"{target}-driver.log"
```

Because the drivers write `capture.png` to the output_dir they receive, they'll create `checkpoint_dir / capture.png` for each target. After each capture succeeds, rename it to include the target name. The driver log also needs a target prefix to avoid overwrites.

- [ ] **Step 2: Rename capture.png to <target>.png after each capture**

After each capture succeeds (after `captures[target] = str(result)` and the print), add:
```python
            cap_flat = checkpoint_dir / f"{target}.png"
            if result.exists():
                result.rename(cap_flat)
                captures[target] = str(cap_flat)
```

Place this right after the `print(f"  OK {target}: {result} ({sz} bytes)")` line and the `except` block — actually, let me reconsider the control flow. Looking at the current code:

```python
            captures[target] = str(result)
            sz = result.stat().st_size if result.exists() else 0
            print(f"  OK {target}: {result} ({sz} bytes)")
```

Change to:
```python
            captures[target] = str(result)
            sz = result.stat().st_size if result.exists() else 0
            # Rename to flat <target>.png in session dir
            if result and result.exists():
                flat_path = checkpoint_dir / f"{target}.png"
                result.rename(flat_path)
                captures[target] = str(flat_path)
                sz = flat_path.stat().st_size
            print(f"  OK {target}: {captures[target]} ({sz} bytes)")
```

---

### Task 3: Flatten comparison output (promote diffs)

**Files:**
- Modify: `scripts/capture-checkpoint.py:149-163`

Currently `full_report()` creates a `diff/` subdir under the checkpoint_dir. After it runs, move diffs up and remove the diff dir.

- [ ] **Step 1: Remove diff/ subdir after full_report()**

After the `report = full_report(...)` line and the printing loop, add:

```python
    # Promote diffs from diff/ subdir to session dir, then remove diff/
    diff_dir = checkpoint_dir / "diff"
    if diff_dir.exists():
        for f in diff_dir.iterdir():
            f.rename(checkpoint_dir / f.name)
        diff_dir.rmdir()
```

---

### Task 4: HTTP server launch

**Files:**
- Modify: `scripts/capture-checkpoint.py:top (import socket)` and after comparisons

- [ ] **Step 1: Add `import socket` at the top**

Add `socket` to the existing imports (currently `import argparse, sys, pathlib, json, time`):
```python
import argparse
import sys
import pathlib
import json
import time
import socket
```

- [ ] **Step 2: Add server launch after comparisons**

After the comparison output loop and the diff promotion, add:

```python
    # Start HTTP server on port 1234 if not already running
    def _ensure_http_server():
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.connect(("localhost", 1234))
            sock.close()
            print(f"  (HTTP server already running on port 1234)")
            return
        except ConnectionRefusedError:
            pass
        finally:
            sock.close()
        import subprocess
        subprocess.Popen(
            ["python3", "-m", "http.server", "1234", "--directory", str(output_root)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"  HTTP server started at http://localhost:1234/")

    _ensure_http_server()
```

---

### Task 5: Commit

- [ ] **Step 1: Commit**

```bash
git add scripts/capture-checkpoint.py
git commit -m "feat: timestamped session dirs under /tmp/battlecontrol + HTTP server

- Default output root changed to /tmp/battlecontrol with <timestamp>-<type>-<id> session dirs
- Capture and diff files flattened into session dir (no nested subdirs)
- HTTP server auto-starts on port 1234 if not already running

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```
