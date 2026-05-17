#!/usr/bin/env python3
"""LP64 static hazard audit for the CnC Linux port.

Scans C/C++ source for patterns that cause silent bugs when porting Win32 C++
to LP64 Linux (sizeof(long)==8, sizeof(void*)==8).  Distilled from real bugs
fixed in TIM-173, TIM-206, TIM-241-243, TIM-423, TIM-453.

Usage:
    python3 scripts/lint-lp64.py [--dirs DIR...] [--skip-dir DIR...]
    cmake --build build --target lint-lp64

Exit codes: 0 = clean, 1 = errors found, 2 = warnings only.
"""

import re
import sys
import argparse
from pathlib import Path
from dataclasses import dataclass
from typing import Callable, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Finding
# ---------------------------------------------------------------------------


@dataclass
class Finding:
    path: Path
    line_no: int
    severity: str  # 'error' | 'warning'
    rule: str
    detail: str
    text: str  # stripped source line


# ---------------------------------------------------------------------------
# Rule helpers
# ---------------------------------------------------------------------------


def _make_rule(
    rule: str,
    severity: str,
    pattern: str,
    detail_fn: Callable[[re.Match], Optional[str]],
    flags: int = re.IGNORECASE,
) -> Tuple[str, str, re.Pattern, Callable]:
    return (rule, severity, re.compile(pattern, flags), detail_fn)


def _literal_detail(msg: str) -> Callable:
    return lambda m: msg


# ---------------------------------------------------------------------------
# Rule table
# ---------------------------------------------------------------------------
# Each rule: (rule_id, severity, compiled_re, detail_fn(match)->str|None)
# detail_fn returning None suppresses the finding (used for false-positive
# suppression based on capture groups).

RULES: List[Tuple] = [
    # ---- ERRORs --------------------------------------------------------
    # E1: typedef (unsigned) long NAME  →  uint32_t / int32_t
    # The canonical LP64 trap: Win32 assumed sizeof(long)==4; on LP64 it is 8.
    # Seen in: COORDINATE (TIM-241), timer fields (TIM-242), MCEFLAGS, etc.
    _make_rule(
        "E1:typedef-long",
        "error",
        r"\btypedef\s+(?:unsigned\s+)?long\s+(\w+)\s*;",
        lambda m: (
            f"typedef 'long' alias '{m.group(1)}': "
            f"long is 8 bytes on LP64; use int32_t / uint32_t"
        ),
        flags=0,
    ),
    # E2: _lrotl / _lrotr  →  explicit uint32_t rotate
    # _lrotl operates on unsigned long (8 bytes LP64); produces wrong CRC/hash.
    # Fixed in CRC.CPP (TIM-173) and TD CRC (TIM-453).
    _make_rule(
        "E2:_lrotl",
        "error",
        r"\b_lrotl\b|\b_lrotr\b",
        _literal_detail(
            "_lrotl/_lrotr rotate unsigned long (8 bytes on LP64); "
            "use explicit uint32_t rotate: (uint32_t)((c<<n)|(c>>(32-n)))"
        ),
        flags=0,
    ),
    # E3: (int) cast on obvious pointer expression
    # Truncates a 64-bit pointer to 32 bits silently.
    # Matches: (int)somePtr  (int)(void*)x  (int)&x
    # Does NOT match: (int)somePtr->member  (int)somePtr.member
    # (those cast the member value, not the pointer itself).
    _make_rule(
        "E3:ptr-to-int-cast",
        "error",
        r"\(\s*int\s*\)\s*(?:\(\s*void\s*\*\s*\)|&\s*\w+|\w*[Pp]tr\b(?!\s*(?:->|\s*\.)))",
        _literal_detail(
            "(int) cast on pointer: truncates 64-bit pointer to 32 bits on LP64; "
            "use intptr_t / uintptr_t"
        ),
        flags=0,
    ),
    # E4: __attribute__((packed)) struct with a 'long' field inside it
    # Packed struct layout depends on sizeof(long); fields after the long
    # shift by 4 bytes on LP64 vs Win32.  Seen in CompHeaderType (TIM-202).
    # This is a file-level check applied via context tracking (see scan()).
    # ---- WARNINGs -------------------------------------------------------
    # W1: struct/class field declared as (unsigned) long
    # Each such field grows by 4 bytes on LP64, misaligning later fields.
    # Fixed: TotalValue (TIM-243), COORDINATE (TIM-241), timer fields (TIM-242).
    _make_rule(
        "W1:long-field",
        "warning",
        r"^\s+(?:unsigned\s+)?long\s+(\w+)\s*(?:\[\w*\])?\s*;",
        lambda m: (
            f"struct/class field '{m.group(1)}' has type '(unsigned) long': "
            f"8 bytes on LP64 vs 4 on Win32; consider int32_t / uint32_t"
        ),
        flags=0,
    ),
    # W2: sizeof(long) used as a size constant
    # Almost always assumes sizeof(long)==4; breaks buffer/array sizing on LP64.
    _make_rule(
        "W2:sizeof-long",
        "warning",
        r"\bsizeof\s*\(\s*(?:unsigned\s+)?long\s*\)",
        _literal_detail(
            "sizeof(long) is 8 on LP64 (was 4 on Win32); "
            "use sizeof(int32_t) or sizeof(uint32_t) for fixed-width intent"
        ),
        flags=0,
    ),
    # W3: unsigned long array used for binary file offsets
    # Seen in Build_Frame offset[] (TIM-206) and MixFile bsearch table (TIM-453).
    # Pattern: array declaration with (unsigned) long element type.
    _make_rule(
        "W3:long-offset-array",
        "warning",
        r"\b(?:unsigned\s+)?long\s+\w+\s*\[",
        _literal_detail(
            "Array of (unsigned) long: if used for binary file offsets or "
            "Win32-sized record indices, elements grow from 4 to 8 bytes on LP64; "
            "use uint32_t[] for fixed-width offsets"
        ),
        flags=0,
    ),
    # W4: LONG / ULONG used in struct fields (windows.h typedef long LONG)
    # LONG is typedef'd to `long` in our windows.h stub, so it is 8 bytes on
    # LP64.  Flags uses inside game-code structs that were intended as 32-bit.
    _make_rule(
        "W4:LONG-field",
        "warning",
        r"^\s+(?:U)?LONG\s+(\w+)\s*(?:\[\w*\])?\s*;",
        lambda m: (
            f"struct field '{m.group(1)}' typed as LONG/ULONG: "
            f"expands to 'long' (8 bytes LP64) via windows.h typedef; "
            f"use int32_t / uint32_t for portability"
        ),
        flags=0,
    ),
    # W5: HRESULT used in packed/serialised structs
    # HRESULT is typedef long HRESULT in our stub — 8 bytes on LP64.
    # OK for return values; problematic inside packed structs or binary I/O.
    _make_rule(
        "W5:HRESULT-field",
        "warning",
        r"^\s+HRESULT\s+(\w+)\s*;",
        lambda m: (
            f"struct field '{m.group(1)}' typed as HRESULT: "
            f"expands to long (8 bytes LP64); "
            f"use int32_t for stored/serialised HRESULT values"
        ),
        flags=0,
    ),
    # W6: pointer stored via (long) or (unsigned long) cast
    # Equivalent to E3 but using long instead of int.
    _make_rule(
        "W6:ptr-to-long-cast",
        "warning",
        r"\(\s*(?:unsigned\s+)?long\s*\)\s*(?:\(void\s*\*\)|\w*[Pp]tr\w*)",
        _literal_detail(
            "(long) cast on pointer: on Win32 sizeof(long)==sizeof(void*)==4; "
            "on LP64 both are 8, so the value fits but the intent is fragile; "
            "use uintptr_t for pointer-to-integer storage"
        ),
        flags=0,
    ),
]


# ---------------------------------------------------------------------------
# Packed-struct context tracker (E4)
# ---------------------------------------------------------------------------


class PackedStructTracker:
    """Tracks when we are inside a #pragma pack or __attribute__((packed))
    struct and flags 'long' fields inside them as errors."""

    _PACK_PUSH = re.compile(r"#\s*pragma\s+pack\s*\(\s*push\b", re.IGNORECASE)
    _PACK_POP = re.compile(r"#\s*pragma\s+pack\s*\(\s*pop\b", re.IGNORECASE)
    _PACK_N = re.compile(r"#\s*pragma\s+pack\s*\(\s*\d+", re.IGNORECASE)
    _ATTR_PACKED = re.compile(r"__attribute__\s*\(\s*\(\s*packed\s*\)", re.IGNORECASE)
    _STRUCT_OPEN = re.compile(r"\bstruct\b|\bclass\b")
    _BRACE_OPEN = re.compile(r"\{")
    _BRACE_CLOSE = re.compile(r"\}")
    _LONG_FIELD = re.compile(r"^\s+(?:unsigned\s+)?long\s+\w+", re.MULTILINE)

    def __init__(self):
        self.pack_depth: int = 0  # nesting level of #pragma pack(push)
        self.brace_depth: int = 0  # overall { } depth while packing
        self.pack_brace_start: int = 0  # brace_depth when packing began

    def feed(self, line: str, line_no: int, path: Path, findings: list):
        if self._PACK_PUSH.search(line) or self._PACK_N.search(line):
            if self.pack_depth == 0:
                self.pack_brace_start = self.brace_depth
            self.pack_depth += 1
        if self._PACK_POP.search(line):
            self.pack_depth = max(0, self.pack_depth - 1)

        self.brace_depth += line.count("{") - line.count("}")

        if self.pack_depth > 0 and self._LONG_FIELD.match(line):
            m = re.search(r"(?:unsigned\s+)?long\s+(\w+)", line)
            name = m.group(1) if m else "?"
            findings.append(
                Finding(
                    path=path,
                    line_no=line_no,
                    severity="error",
                    rule="E4:packed-long-field",
                    detail=(
                        f"Field '{name}' typed as (unsigned) long inside a packed struct: "
                        f"sizeof(long) is 8 on LP64; use int32_t/uint32_t to guarantee "
                        f"4-byte slot and preserve binary layout"
                    ),
                    text=line.rstrip(),
                )
            )


# ---------------------------------------------------------------------------
# File scanner
# ---------------------------------------------------------------------------

C_EXTENSIONS = {".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx"}


def scan_file(path: Path, rules: list) -> List[Finding]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    findings: List[Finding] = []
    tracker = PackedStructTracker()

    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line

        # Skip pure comment lines (C++ //, block comment open /*,
        # and block comment continuation lines starting with *)
        stripped = line.lstrip()
        if (
            stripped.startswith("//")
            or stripped.startswith("*")
            or stripped.startswith("/*")
        ):
            continue

        # Feed packed-struct tracker first (E4)
        tracker.feed(line, line_no, path, findings)

        # Apply regex rules
        for rule_id, severity, pattern, detail_fn in rules:
            m = pattern.search(line)
            if m:
                detail = detail_fn(m)
                if detail is None:
                    continue
                findings.append(
                    Finding(
                        path=path,
                        line_no=line_no,
                        severity=severity,
                        rule=rule_id,
                        detail=detail,
                        text=line.rstrip(),
                    )
                )

    return findings


def scan_dirs(
    dirs: List[Path],
    skip_dirs: List[Path],
    rules: list,
) -> List[Finding]:
    all_findings: List[Finding] = []
    visited: set = set()

    for base in dirs:
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() not in C_EXTENSIONS:
                continue
            # Skip excluded directories
            if any(str(path).startswith(str(s)) for s in skip_dirs):
                continue
            real = path.resolve()
            if real in visited:
                continue
            visited.add(real)
            all_findings.extend(scan_file(path, rules))

    return all_findings


# ---------------------------------------------------------------------------
# Report formatter
# ---------------------------------------------------------------------------

RESET = "\033[0m"
RED = "\033[31m"
YELLOW = "\033[33m"
BOLD = "\033[1m"
DIM = "\033[2m"


def _colour(text: str, code: str, use_colour: bool) -> str:
    return f"{code}{text}{RESET}" if use_colour else text


def print_report(findings: List[Finding], use_colour: bool, repo_root: Path):
    errors = [f for f in findings if f.severity == "error"]
    warnings = [f for f in findings if f.severity == "warning"]

    if not findings:
        print("LP64 audit: CLEAN — no hazards found.")
        return

    def _rel(p: Path) -> str:
        try:
            return str(p.relative_to(repo_root))
        except ValueError:
            return str(p)

    for group, colour, label in [
        (errors, RED, "ERROR"),
        (warnings, YELLOW, "WARNING"),
    ]:
        for f in group:
            loc = _colour(f"{_rel(f.path)}:{f.line_no}", BOLD, use_colour)
            sev = _colour(f"[{label}]", colour, use_colour)
            rule = _colour(f"({f.rule})", DIM, use_colour)
            print(f"{loc}: {sev} {rule}")
            print(f"  {f.detail}")
            print(f"  {_colour(f.text.strip(), DIM, use_colour)}")
            print()

    total = len(findings)
    e_str = _colour(f"{len(errors)} error(s)", RED, use_colour)
    w_str = _colour(f"{len(warnings)} warning(s)", YELLOW, use_colour)
    print(f"LP64 audit: {total} finding(s) — {e_str}, {w_str}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Static LP64 hazard audit for the CnC Linux port.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dirs",
        nargs="+",
        metavar="DIR",
        default=["REDALERT", "TIBERIANDAWN"],
        help="Source directories to scan (default: REDALERT TIBERIANDAWN)",
    )
    parser.add_argument(
        "--skip-dir",
        nargs="+",
        metavar="DIR",
        default=["linux/win32-stubs", "REDALERT/MEMCHECK.H"],
        help="Paths to exclude (default: linux/win32-stubs REDALERT/MEMCHECK.H)",
    )
    parser.add_argument(
        "--no-colour",
        action="store_true",
        help="Disable ANSI colour output",
    )
    parser.add_argument(
        "--errors-only",
        action="store_true",
        help="Print only error-severity findings",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Always exit 0, even when errors are found (used by CMake target for informational runs)",
    )
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    dirs = [repo_root / d for d in args.dirs]
    skip_dirs = [repo_root / d for d in args.skip_dir]

    missing = [d for d in dirs if not d.exists()]
    if missing:
        print(f"lint-lp64: directories not found: {', '.join(str(m) for m in missing)}")
        sys.exit(1)

    use_colour = not args.no_colour and sys.stdout.isatty()

    findings = scan_dirs(dirs, skip_dirs, RULES)

    if args.errors_only:
        findings = [f for f in findings if f.severity == "error"]

    print_report(findings, use_colour, repo_root)

    if args.no_fail:
        sys.exit(0)

    errors = sum(1 for f in findings if f.severity == "error")
    if errors:
        sys.exit(1)
    if findings:
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
