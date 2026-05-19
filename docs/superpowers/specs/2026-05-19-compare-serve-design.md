# Compare Script Output Directory & HTTP Server — Design

## Problem

Parity comparison screenshots land in `e2e/checkpoints/` with a fixed directory per checkpoint name. Rerunning a comparison overwrites the previous run, making it hard to review results. There's no built-in way to browse screenshots in a browser.

## Approach

Modify `capture-checkpoint.py` to write to timestamped session directories under `/tmp/battlecontrol/` and optionally start an HTTP server for browser review.

## Output Structure

```
/tmp/battlecontrol/                            # base dir (--output default)
├── 2026-05-19T15-30-50-mission-allied-l1/     # session dir: <timestamp>-<type>-<id>
│   ├── wine.png                               # capture, renamed from capture.png
│   ├── native.png
│   ├── diff-wine-vs-native.png                # diff image, flat in session dir
│   ├── manifest.json
│   └── report.json
├── 2026-05-19T16-00-00-mission-soviet-l2/
│   └── ...
```

- One directory per session, files flat inside (no nested subdirs)
- Captures renamed from `capture.png` → `<target>.png`
- Diffs promoted from `diff/<name>.png` → `<name>.png`

## Changes

### `capture-checkpoint.py`

Three changes:

1. **Output base directory.** Default changes from `e2e/checkpoints` to `/tmp/battlecontrol`. The `--output` flag overrides this base path. The session directory is `<base>/<timestamp>-<type>-<id>/`.

2. **Flatten output.** After captures complete, rename `<target>/capture.png` → `<target>.png` at the session dir level. After comparisons, move diffs from `diff/<name>.png` → `<name>.png`. Then remove the now-empty `<target>/` and `diff/` subdirs.

3. **HTTP server.** After all captures + comparisons finish, probe port 1234 with `socket.connect(('localhost', 1234))`. If nothing is listening, spawn `python3 -m http.server 1234 --directory /tmp/battlecontrol` as a background subprocess. Print `http://localhost:1234/` so the user can click through to the directory listing.

### No changes to

- `drivers/compare.py` — keeps its pure-function contract
- `parity-compare.py` — low-level tool unchanged
- `capture-checkpoint.py --dry-run` — still works as before

## Error Handling

- If session dir creation fails in the output directory, fall back to `e2e/checkpoints/<type>-<id>` as a last resort
- If HTTP server fails to start (port taken, python unavailable), print a warning but don't fail the capture
- If the session directory already exists (same timestamp), append `-1`, `-2` etc
