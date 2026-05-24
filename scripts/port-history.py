#!/usr/bin/env python3
"""Show concise source history for porting-regression investigations."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import subprocess
import sys
from collections.abc import Iterable


LOG_RECORD_SEP = "\x1e"
LOG_FIELD_SEP = "\x1f"
PORTING_KEYWORD_PATTERNS = (
    ("LP64", r"lp64"),
    ("port", r"port(?:s|ed|ing)?"),
    ("stub", r"stub(?:s|bed|bing)?"),
    ("Linux", r"linux"),
    ("WASM", r"wasm"),
    ("timing", r"timing"),
    ("render", r"render(?:s|ed|ing|er)?"),
    ("portable", r"portable"),
)
HUNK_RE = re.compile(r"^@@ .* @@(?P<context>.*)$")
CONTROL_FLOW_RE = re.compile(
    r"^(if|for|while|switch|catch|else|do|return)\b", re.IGNORECASE
)


@dataclasses.dataclass(frozen=True)
class Commit:
    sha: str
    date: str
    subject: str
    body: str


def run_git(args: list[str], cwd: str | None = None) -> str:
    result = subprocess.run(
        ["git", *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout


def repository_root() -> pathlib.Path:
    return pathlib.Path(run_git(["rev-parse", "--show-toplevel"]).strip())


def repo_relative_path(path: str, root: pathlib.Path) -> str:
    candidate = pathlib.Path(path)
    if not candidate.is_absolute():
        root_candidate = root / candidate
        if root_candidate.exists():
            return root_candidate.resolve().relative_to(root.resolve()).as_posix()
    if not candidate.is_absolute():
        candidate = pathlib.Path.cwd() / candidate
    try:
        return candidate.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path


def parse_log(output: str) -> list[Commit]:
    commits: list[Commit] = []
    for raw_record in output.split(LOG_RECORD_SEP):
        record = raw_record.strip("\n")
        if not record.strip():
            continue
        parts = record.split(LOG_FIELD_SEP, 3)
        if len(parts) != 4:
            continue
        sha, date, subject, body = parts
        commits.append(
            Commit(
                sha=sha.strip(),
                date=date.strip(),
                subject=subject.strip(),
                body=body.strip(),
            )
        )
    return commits


def git_log(path: str, max_count: int, root: pathlib.Path) -> list[Commit]:
    fmt = "%H%x1f%ad%x1f%s%x1f%b%x1e"
    output = run_git(
        [
            "log",
            "--follow",
            f"--max-count={max_count}",
            "--date=short",
            f"--format={fmt}",
            "--",
            path,
        ],
        cwd=str(root),
    )
    return parse_log(output)


def changed_stat(commit: Commit, path: str, root: pathlib.Path) -> list[str]:
    output = run_git(
        [
            "show",
            "--stat",
            "--format=",
            "--stat-count=20",
            "--no-ext-diff",
            commit.sha,
            "--",
            path,
        ],
        cwd=str(root),
    )
    return [line.rstrip() for line in output.splitlines() if line.strip()]


def parse_function_hints(diff: str) -> list[str]:
    hints: list[str] = []
    seen: set[str] = set()
    for line in diff.splitlines():
        match = HUNK_RE.match(line)
        if not match:
            continue
        context = match.group("context").strip()
        if not looks_like_function_hint(context) or context in seen:
            continue
        seen.add(context)
        hints.append(context)
    return hints


def looks_like_function_hint(context: str) -> bool:
    if not context:
        return False
    if CONTROL_FLOW_RE.match(context):
        return False
    return "::" in context or ("(" in context and ")" in context and "{" in context)


def changed_function_hints(
    commit: Commit, path: str, root: pathlib.Path, limit: int
) -> list[str]:
    output = run_git(
        [
            "show",
            "--format=",
            "--unified=0",
            "--no-ext-diff",
            commit.sha,
            "--",
            path,
        ],
        cwd=str(root),
    )
    return parse_function_hints(output)[:limit]


def matched_porting_keywords(commit: Commit) -> list[str]:
    haystack = f"{commit.subject}\n{commit.body}".lower()
    matches: list[str] = []
    for label, pattern in PORTING_KEYWORD_PATTERNS:
        pattern = rf"(?<![a-z0-9]){pattern}(?![a-z0-9])"
        if re.search(pattern, haystack):
            matches.append(label)
    return matches


def indented(lines: Iterable[str], prefix: str = "  ") -> str:
    return "\n".join(f"{prefix}{line}" for line in lines)


def body_summary(body: str, limit: int) -> list[str]:
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    return lines[:limit]


def print_commit(
    commit: Commit,
    path: str,
    root: pathlib.Path,
    *,
    show_body: bool,
    show_stat: bool,
    show_functions: bool,
    max_functions: int,
) -> None:
    matches = matched_porting_keywords(commit)
    marker = " PORT?" if matches else ""
    keyword_text = f" [{', '.join(matches)}]" if matches else ""
    print(f"{commit.sha[:12]} {commit.date}{marker}{keyword_text}")
    print(f"  {commit.subject}")

    if show_body and commit.body:
        for line in body_summary(commit.body, 5):
            print(f"  body: {line}")

    if show_stat:
        stat_lines = changed_stat(commit, path, root)
        if stat_lines:
            print(indented(stat_lines))

    if show_functions:
        functions = changed_function_hints(commit, path, root, max_functions)
        if functions:
            print(f"  functions: {', '.join(functions)}")


def print_path_history(args: argparse.Namespace, path: str, root: pathlib.Path) -> int:
    print(f"== {path} ==")
    commits = git_log(path, args.max_count, root)
    if not commits:
        print("  no commits found")
        return 1

    for index, commit in enumerate(commits):
        if index:
            print()
        print_commit(
            commit,
            path,
            root,
            show_body=args.show_body,
            show_stat=not args.no_stat,
            show_functions=not args.no_function_hints,
            max_functions=args.max_functions,
        )
    return 0


def run_self_test() -> int:
    sample = (
        "abc123\x1f2026-05-21\x1fFix Linux render timing\x1f"
        "Body mentions LP64 and portable path.\x1e\n"
    )
    commits = parse_log(sample)
    assert len(commits) == 1
    assert commits[0].sha == "abc123"
    assert matched_porting_keywords(commits[0]) == [
        "LP64",
        "Linux",
        "timing",
        "render",
        "portable",
    ]

    diff = "\n".join(
        [
            "@@ -10,0 +11 @@ void MapClass::Draw() {",
            "+changed();",
            "@@ -20 +22 @@ if (Ready) {",
            "-old();",
            "@@ -30 +31 @@ ScenarioClass::Load() {",
        ]
    )
    assert parse_function_hints(diff) == [
        "void MapClass::Draw() {",
        "ScenarioClass::Load() {",
    ]

    assert body_summary("\n\n first line \n second line\n", 1) == ["first line"]
    variant = Commit(
        sha="def456",
        date="2026-05-21",
        subject="Fix porting regression in rendering stubs",
        body="ported paths",
    )
    assert matched_porting_keywords(variant) == ["port", "stub", "render"]
    root = pathlib.Path("/repo").resolve()
    assert (
        repo_relative_path(str(root / "REDALERT/MAP.CPP"), root) == "REDALERT/MAP.CPP"
    )
    print("self-test passed")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Show concise git history for suspect porting-regression files."
    )
    parser.add_argument("paths", nargs="*", help="source files to inspect")
    parser.add_argument(
        "--max-count",
        type=int,
        default=20,
        help="maximum commits per file (default: 20)",
    )
    parser.add_argument(
        "--show-body",
        action="store_true",
        help="include up to five non-empty body lines per commit",
    )
    parser.add_argument(
        "--no-stat",
        action="store_true",
        help="omit per-commit git stat output",
    )
    parser.add_argument(
        "--no-function-hints",
        action="store_true",
        help="omit touched function hints parsed from diff hunk headers",
    )
    parser.add_argument(
        "--max-functions",
        type=int,
        default=8,
        help="maximum function hints per commit (default: 8)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run parser self-test without invoking git history commands",
    )
    args = parser.parse_args(argv)
    if args.max_count < 1:
        parser.error("--max-count must be at least 1")
    if args.max_functions < 0:
        parser.error("--max-functions must be non-negative")
    if not args.self_test and not args.paths:
        parser.error("at least one path is required")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()

    root = repository_root()
    status = 0
    for index, path in enumerate(args.paths):
        if index:
            print()
        rel_path = repo_relative_path(path, root)
        try:
            status |= print_path_history(args, rel_path, root)
        except RuntimeError as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
