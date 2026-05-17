#!/usr/bin/env bash
# nix-shell-escaping demo: run to see all tested patterns in action
set -euo pipefail

echo "=========================================="
echo "  nix-shell Escaping Demo"
echo "=========================================="
echo ""

echo "=== Pattern 1: Simple command ==="
nix-shell -p hello --run 'hello'
echo ""

echo "=== Pattern 2: Multiple packages ==="
nix-shell -p go gopls --run 'go version && gopls version'
echo ""

echo "=== Pattern 3: Python with single-quote inside ==="
nix-shell -p python3 --run "python3 -c 'print(42)'"
echo ""

echo "=== Pattern 4: Variable from outer shell (DOUBLE Q) ==="
nix-shell -p bash --run "echo 'HOME=$HOME'"
echo ""

echo "=== Pattern 5: Variable from inner shell (SINGLE Q) ==="
# shellcheck disable=SC2016  # intentional: $MYVAR expands inside nix-shell, not outer shell
MYVAR=world nix-shell -p bash --run 'echo "MYVAR=$MYVAR"'
echo ""

echo "=== Pattern 6: Command chaining ==="
nix-shell -p bash coreutils --run 'echo "multi-step:"; cd /tmp; pwd | xargs echo "  cwd:"'
echo ""

echo "=== Pattern 7: Pipes inside run ==="
nix-shell -p bash coreutils --run 'echo -e "foo\nbar\nbaz" | sort'
echo ""

echo "=== Pattern 8: --pure isolation ==="
nix-shell -p bash coreutils --pure --run 'echo "Pure PATH is only nix store paths" | head -c 40'
echo ""
echo ""

echo "=== Pattern 9: Full nix expression with -E ==="
nix-shell -E 'with import <nixpkgs> {}; mkShell { buildInputs = [ hello ]; }' --run 'hello'
echo ""

echo "=========================================="
echo "  All patterns passed!"
echo "=========================================="
