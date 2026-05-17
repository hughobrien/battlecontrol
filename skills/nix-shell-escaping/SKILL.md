---
name: nix-shell-escaping
description: Comprehensive reference for nix-shell quoting and escaping. Use when the task involves running commands via nix-shell --run, --command, or writing nix-shell shebang scripts. Covers multi-layer shell quoting, variable expansion traps, and all tested failure modes.
version: 0.2.0
---

# Nix Shell Escaping

## The Core Problem

`nix-shell --run` passes its argument to a **nested shell** (bash). This creates a
two-layer quoting problem:

```
Your shell  ──►  nix-shell --run "..."  ──►  bash -c "..."
```

Everything inside `--run` must survive **two** shell parsing passes. The same
rules apply to `--command`.

---

## Layer 1: Outer Shell Escaping

### Rule 1: Single quotes (`'...'`) pass literally

```bash
# $MYVAR is NOT expanded by the outer shell.
# Inside nix-shell, bash sees the literal text "$MYVAR" and expands it.
MYVAR=world nix-shell -p bash --run 'echo "$MYVAR"'
# Output: world
```

### Rule 2: Double quotes (`"..."`) expand before nix-shell sees them

```bash
# $MYVAR IS expanded by the OUTER shell before nix-shell runs.
# The string reaching --run already has the value baked in.
MYVAR=world nix-shell -p bash --run "echo '$MYVAR'"
# $MYVAR may be empty/unset in the outer shell → Output: ""
```

**This is the most common LLM mistake.** The outer shell expands `$` in double
quotes immediately. Set env vars in the outer shell or use single quotes.

### Rule 3: `$'...'` (ANSI-C quoting) embeds escapes

```bash
# \n, \t, \\, \" all work inside $'...'
nix-shell -p python3 --run $'python3 -c "print(\'hello\\nworld\')"'
```

Useful for multi-line one-liners, but watch out: `\"` produces a literal `"`
which can break argument boundaries if unbalanced.

---

## Layer 2: The Inner nix-shell Shell

Inside nix-shell, the `--run` argument is handed to `bash -c`. Standard shell
rules apply. **There is no extra escaping layer beyond what the outer shell does.**

- Semicolons (`;`) chain commands
- Pipes (`|`) and redirects (`>`, `<`) work
- `$variable` expands normally
- `$@`, `$1`, etc. are positional args of `bash -c` (not nix-shell args)

```bash
nix-shell -p bash coreutils gnugrep --run \
  'echo -e "foo\nbar\nbaz" | grep -v bar | sort -r'
```

---

## Tested Patterns (All Verified)

### Pattern A: Simple package + single command

```bash
nix-shell -p hello --run 'hello'
```

### Pattern B: Multiple packages

```bash
nix-shell -p go gopls gotools --run 'go version && gopls version'
```

### Pattern C: Python one-liner, single inside double

Use double quotes outside, escaped double quotes inside:

```bash
nix-shell -p python3 --run "python3 -c 'print(\"hello\")'"
```

### Pattern D: Python one-liner, double inside single

Use single quotes outside, literal double quotes inside:

```bash
nix-shell -p python3 --run 'python3 -c "print(42)"'
```

### Pattern E: Python with both quote types

Use single quotes outside, double quotes for the Python string, and the
`'"'"'` trick if needed:

```bash
nix-shell -p python3 python312Packages.pyyaml --run 'python3 -c '"'"'
import yaml
data = {"key": [1, 2, 3], "nested": {"a": "b"}}
print(yaml.dump(data))
'"'"'' 2>&1
```

### Pattern F: Multi-line with `$'...'`

```bash
nix-shell -p python3 --run $'python3 -c "\nimport sys\nprint(sys.version)"'
```

### Pattern G: Setting env vars for inner shell

```bash
nix-shell -p bash coreutils --run 'X=hello; echo "X is $X"'
```

### Pattern H: Version-specific packages

Nix uses attr-name syntax, not dotted version syntax:

```bash
# RIGHT: attribute name 'python312'
nix-shell -p python312 --run 'python3 --version'

# WRONG: 'python3.12' is not a valid attr path for -p
# WRONG: 'nixpkgs#python3' uses new-style flake syntax (needs nix-command)
```

### Pattern I: `--pure` isolates environment

```bash
nix-shell -p bash coreutils --pure --run 'echo "$PATH"'
# PATH contains only nix store paths, no user additions
```

### Pattern J: `-E` with a full expression

```bash
nix-shell -E 'with import <nixpkgs> {}; mkShell { buildInputs = [ go gopls ]; }' \
  --run 'go version && gopls version'
```

---

## The Shebang Approach (Most Reliable for Complex Code)

Write a self-contained script with the dependency declaration as a comment:

```python
#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 python312Packages.pyyaml

import yaml
data = {"key": [1, 2, 3], "nested": {"a": "b"}}
print(yaml.dump(data))
```

Just `chmod +x` and run. The `-i` flag sets the interpreter. Each `#! nix-shell`
line adds an option. This works for any language (bash, python, perl, etc.).

---

## The Temp-File Approach (Most Reliable for One-Shot Commands)

Write code to a temp file, then run it under nix-shell:

```bash
cat > /tmp/_task.py << 'EOF'
import json
data = {"hello": "world"}
print(json.dumps(data, indent=2))
EOF
nix-shell -p python3 --run 'python3 /tmp/_task.py'
```

---

## The Nix-native Approach (Flake Apps)

When writing a Nix flake, `pkgs.writeShellScript` and `pkgs.writeShellApplication`
bypass all `--run` quoting problems entirely. They write the script to a Nix store
path as a standalone executable file — no nested shell parsing.

```nix
# writeShellScript — creates a single-file script
mkApp = name: script: rec {
  type = "app";
  program = toString (pkgs.writeShellScript name script);
};
```

```nix
# writeShellApplication — adds arg parsing, man page, etc.
pkgs.writeShellApplication {
  name = "my-tool";
  text = ''
    echo "Arguments: $@"
    for f in "$@"; do
      process "$f"
    done
  '';
}
```

**Caveat: `writeShellScript` uses `#!/bin/sh` not `#!/bin/bash`.**  Job control
syntax (`%1`, `%2`) and other bashisms like `[[ ... ]]` or `$(< file)` may not
work as expected.  `/bin/sh` is often bash in practice, but **job control is
disabled in non-interactive shells** (see Failure 7 below).  Use explicit PID
variables instead:

```nix
# WRONG — job control disabled in non-interactive mode
myapp = mkApp "myapp" ''
  server --port 8080 &
  kill %1 2>/dev/null || true
'';

# RIGHT — capture PIDs explicitly
myapp = mkApp "myapp" ''
  server --port 8080 &
  PID=$!
  later_cmd
  kill "$PID" 2>/dev/null || true
'';
```

For full bash, use `pkgs.writeScript` with a `#!/usr/bin/env bash` header, or
use `writeShellApplication` which lets you set the shell path.

## Anatomy of a nix-shell Command

```
nix-shell [options] [-p packages... | path] [--run cmd | --command cmd]
```

| Part | Meaning |
|------|---------|
| `-p pkgs...` | Attribute names inside nixpkgs collection |
| `path` | `shell.nix` (preferred) or `default.nix` |
| `--run cmd` | Non-interactive shell (exits after cmd) |
| `--command cmd` | Interactive shell (stays open; add `; return` to drop in) |
| `--pure` | Clear most env variables for reproducible environment |
| `-E expr` | Use Nix expression directly instead of a file |
| `--keep VAR` | Keep env var `VAR` when using `--pure` |
| `-i interpreter` | For shebang scripts: the language interpreter |

---

## Common Failure Modes (LLM-Generated)

### Failure 1: Nested single quotes break the shell

```bash
# WRONG — the shell sees 'python3 -c ' as a string, then print(42) as a command
nix-shell -p python3 --run 'python3 -c 'print(42)''

# RIGHT — use double quotes for the outer shell
nix-shell -p python3 --run "python3 -c 'print(42)'"
```

### Failure 2: Using flake syntax without experimental features

```bash
# WRONG — needs experimental Nix features
nix shell nixpkgs#hello -c hello
nix develop .#default -c go build

# RIGHT — old-style works everywhere
nix-shell -p hello --run 'hello'
nix-shell -p go --run 'go build ./...'
```

### Failure 3: Double-quote variable expansion

```bash
# WRONG — $MYVAR expands in the outer shell before nix-shell runs
MYVAR=hello nix-shell -p bash --run "echo '$MYVAR'"

# RIGHT — single quotes preserve $MYVAR for the inner shell
MYVAR=hello nix-shell -p bash --run 'echo "$MYVAR"'
```

### Failure 4: Wrong package version syntax

```bash
# WRONG — dotted version not valid as attr path
nix-shell -p 'python3.12' --run 'python3 --version'

# RIGHT — Nix attr name 'python312'
nix-shell -p 'python312' --run 'python3 --version'
```

### Failure 5: Running nix-shell outside a project without -p

```bash
# WRONG — no shell.nix or default.nix in /tmp
cd /tmp && nix-shell --run 'echo hi'

# RIGHT — use -p
cd /tmp && nix-shell -p bash --run 'echo hi'
```

### Failure 6: Forgetting that `--` sends args to nix expression, not inner command

```bash
# WRONG — foo/bar/baz interpreted as package names by nix-shell
nix-shell -p bash --run 'echo "$@"' -- foo bar baz

# Use explicit variables instead
nix-shell -p bash --run 'ARGS="foo bar baz"; echo "$ARGS"'
```

### Failure 7: Job control (`%1`, `%2`) in non-interactive shells

`pkgs.writeShellScript` creates scripts with `#!/bin/sh`.  Even when `/bin/sh`
is bash, job control is **disabled in non-interactive mode** without `set -m`.
Background-process references like `%1` produce `kill: %1: no such job`.

```bash
# WRONG — %1 is undefined in non-interactive shell
python3 server.py &
npx test
kill %1 2>/dev/null || true   # silently leaks the background process

# RIGHT — capture PID with $!
python3 server.py &
PID=$!
npx test
kill "$PID" 2>/dev/null || true
```

This applies to:
- Scripts created by `pkgs.writeShellScript`
- Scripts executed via `nix-shell --run` (always non-interactive)
- CI job scripts run by GitHub Actions

**Detection:** If background processes leak after your script exits, check for
`%N` references.  Replace with `$!` PID tracking.

---

## Quick Reference Card

| Goal | Pattern |
|------|---------|
| Run one command | `nix-shell -p PKG --run 'CMD'` |
| Run interactive shell | `nix-shell -p PKG --command 'SETUP; return'` |
| Python with double quotes | `nix-shell -p python3 --run "python3 -c 'print(\"hi\")'"` |
| Python with single quotes | `nix-shell -p python3 --run 'python3 -c "print(chr(39))"'` |
| Use env var (inner) | `nix-shell -p bash --run 'echo "$HOME"'` |
| Use env var (outer) | `nix-shell -p bash --run "echo '$HOME'"` |
| Multi-line | `$'cmd1\ncmd2'` or `--run 'cmd1; cmd2'` |
| Complex code | Write temp file, `nix-shell -p PKG --run 'interpreter /tmp/file'` |
| Script distribution | Shebang script with `#! nix-shell -i python3 -p python3 ...` |
| Isolated environment | Add `--pure` |
| Nix flake app | `pkgs.writeShellScript name script` (avoids `--run` entirely) |
| Nix flake app (bash) | `pkgs.writeShellApplication { name = ...; text = ''...''; }` |
| Track background PIDs | `PID=$!` then `kill "$PID"` (not `%1`) |

---

## Related skills

This skill is referenced by:
- **ci-cd** — CI/CD pipeline commands use nix-shell extensively
- **native-build** — `nix run .#lint` and `nix run .#smoke-*` commands
- **vqa-codec** — `nix run .#vqa-check` command

For the project's canonical nix-shell usage patterns, see `flake.nix` and the
`scripts/skill-*.sh` scripts (all use the temp-file approach for complex commands).
