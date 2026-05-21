#!/usr/bin/env python3
"""Run mission/frame capture matrices and group parity failures."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CAPTURE_CHECKPOINT = SCRIPT_DIR / "capture-checkpoint.py"
SESSION_LINE_RE = re.compile(r"^Session dir:\s*(?P<path>.+)$", re.MULTILINE)
MISSION_RE = re.compile(r"^(?P<side>allied|soviet)-l(?P<level>\d+)$")
MISSION_RANGE_RE = re.compile(
    r"^(?P<side>allied|soviet)-l(?P<start>\d+)\.\.l(?P<end>\d+)$"
)

FAILURE_GROUPS = [
    "pass",
    "wine-main-menu",
    "wine-top-scores",
    "wine-score",
    "wine-frame-timeout",
    "native-failed",
    "comparison-failed",
    "capture-failed",
]
WINE_STATE_GROUPS = {
    "main-menu": "wine-main-menu",
    "top-scores": "wine-top-scores",
    "score": "wine-score",
}


def parse_missions(value: str) -> list[str]:
    missions: list[str] = []
    for raw in value.split(","):
        token = raw.strip()
        if not token:
            continue
        range_match = MISSION_RANGE_RE.match(token)
        if range_match:
            side = range_match.group("side")
            start = int(range_match.group("start"), 10)
            end = int(range_match.group("end"), 10)
            step = 1 if start <= end else -1
            missions.extend(
                f"{side}-l{level}" for level in range(start, end + step, step)
            )
            continue
        if MISSION_RE.match(token):
            missions.append(token)
            continue
        raise argparse.ArgumentTypeError(
            f"invalid mission {token!r}; use allied-l1 or allied-l1..l5"
        )
    if not missions:
        raise argparse.ArgumentTypeError("at least one mission is required")
    return missions


def parse_frames(value: str) -> list[int]:
    frames: list[int] = []
    for raw in value.split(","):
        token = raw.strip()
        if not token:
            continue
        try:
            frame = int(token, 10)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"invalid frame {token!r}") from exc
        if frame < 0:
            raise argparse.ArgumentTypeError("frames must be non-negative")
        frames.append(frame)
    if not frames:
        raise argparse.ArgumentTypeError("at least one frame is required")
    return frames


def parse_targets(value: str) -> list[str]:
    targets = [target.strip() for target in value.split(",") if target.strip()]
    if targets == ["all"]:
        return ["wine", "native", "wasm"]
    allowed = {"wine", "native", "wasm"}
    unknown = [target for target in targets if target not in allowed]
    if unknown:
        raise argparse.ArgumentTypeError(
            f"unknown target(s): {','.join(unknown)} (allowed: wine,native,wasm,all)"
        )
    if not targets:
        raise argparse.ArgumentTypeError("at least one target is required")
    return targets


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        return {"_error": f"malformed JSON: {exc}"}
    return (
        data if isinstance(data, dict) else {"_error": "top-level JSON is not object"}
    )


def session_matches(
    path: pathlib.Path, mission: str, frame: int, targets: list[str]
) -> bool:
    manifest = load_json(path / "manifest.json")
    return (
        manifest.get("type") == "mission"
        and manifest.get("id") == mission
        and manifest.get("frame") == frame
        and manifest.get("targets") == targets
    )


def find_session_path(
    stdout: str,
    output_dir: pathlib.Path,
    child_start_time: float,
    mission: str,
    frame: int,
    targets: list[str],
) -> pathlib.Path | None:
    matches = SESSION_LINE_RE.findall(stdout)
    if matches:
        explicit = pathlib.Path(matches[-1].strip())
        if explicit.exists() and session_matches(explicit, mission, frame, targets):
            return explicit
        return None
    if not output_dir.exists():
        return None
    session_name_re = re.compile(
        rf"^\d{{4}}-\d{{2}}-\d{{2}}T\d{{2}}-\d{{2}}-\d{{2}}-mission-{re.escape(mission)}(?:-\d+)?$"
    )
    sessions = [
        path
        for path in output_dir.iterdir()
        if path.is_dir()
        and path.stat().st_mtime >= child_start_time
        and session_name_re.match(path.name)
        and session_matches(path, mission, frame, targets)
    ]
    if not sessions:
        return None
    sessions.sort(key=lambda path: (path.stat().st_mtime, path.name), reverse=True)
    return sessions[0]


def timeline_last_state(summary: Any) -> str | None:
    if not isinstance(summary, dict):
        return None
    last_state = summary.get("last_state")
    if isinstance(last_state, str):
        return last_state
    states = summary.get("states")
    if isinstance(states, list) and states:
        return str(states[-1])
    return None


def collect_wine_state(manifest: dict[str, Any]) -> str | None:
    timelines = manifest.get("screen_timelines")
    if isinstance(timelines, dict):
        state = timeline_last_state(timelines.get("wine"))
        if state:
            return state
    failures = manifest.get("failures")
    if isinstance(failures, dict):
        wine_failure = failures.get("wine")
        if isinstance(wine_failure, dict):
            state = timeline_last_state(wine_failure.get("screen_timeline"))
            if state:
                return state
            screen = wine_failure.get("screen")
            if isinstance(screen, dict) and isinstance(screen.get("state"), str):
                return str(screen["state"])
    return None


def failure_text(record: dict[str, Any]) -> str:
    parts = [str(record.get("stdout", "")), str(record.get("stderr", ""))]
    failure = record.get("failure")
    if isinstance(failure, dict):
        parts.append(json.dumps(failure, sort_keys=True))
    return "\n".join(parts).lower()


def is_wine_frame_timeout(text: str, record: dict[str, Any]) -> bool:
    if "wine" not in record.get("targets", []):
        return False
    return "frameprobe" in text or "target frame" in text


def classify_result(record: dict[str, Any]) -> str:
    manifest = record.get("manifest")
    report = record.get("report")
    manifest = manifest if isinstance(manifest, dict) else {}
    report = report if isinstance(report, dict) else {}

    wine_state = collect_wine_state(manifest)
    if wine_state in WINE_STATE_GROUPS:
        return WINE_STATE_GROUPS[wine_state]

    failures = manifest.get("failures")
    if isinstance(failures, dict):
        if "native" in failures:
            return "native-failed"
        if "wine" in failures:
            text = failure_text({"failure": failures["wine"], **record})
            if is_wine_frame_timeout(text, record):
                return "wine-frame-timeout"

    if record.get("returncode", 0) != 0:
        text = failure_text(record)
        if "native" in record.get("targets", []) and "native" in text:
            return "native-failed"
        if is_wine_frame_timeout(text, record):
            return "wine-frame-timeout"
        return "capture-failed"

    if report.get("_error"):
        return "comparison-failed"
    summary = report.get("summary")
    if summary == "PASS":
        return "pass"
    if not report and len(record.get("targets", [])) <= 1:
        return "pass"
    return "comparison-failed"


def stdout_stderr_snippet(text: str, limit: int = 4000) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[-limit:]


def build_record(
    mission: str,
    frame: int,
    targets: list[str],
    session: pathlib.Path | None,
    result: subprocess.CompletedProcess[str],
) -> dict[str, Any]:
    manifest = load_json(session / "manifest.json") if session is not None else {}
    report = load_json(session / "report.json") if session is not None else {}
    record: dict[str, Any] = {
        "mission": mission,
        "frame": frame,
        "targets": targets,
        "returncode": result.returncode,
        "session": str(session) if session is not None else None,
        "stdout": stdout_stderr_snippet(result.stdout),
        "stderr": stdout_stderr_snippet(result.stderr),
        "manifest": manifest,
        "report": report,
    }

    captures = manifest.get("captures")
    if isinstance(captures, dict):
        record["captures"] = captures
    effective_frames = manifest.get("effective_frames")
    if isinstance(effective_frames, dict):
        record["effective_frames"] = effective_frames
    failures = manifest.get("failures")
    if isinstance(failures, dict):
        record["failures"] = failures
    if report.get("pairs"):
        record["comparisons"] = report["pairs"]
    worst_region = extract_worst_region(record)
    if worst_region:
        record["worst_region"] = worst_region

    classification = classify_result(record)
    record["classification"] = classification
    return record


def extract_worst_region(record: dict[str, Any]) -> dict[str, Any] | None:
    report = record.get("report")
    if not isinstance(report, dict):
        return None
    best: dict[str, Any] | None = None
    for pair in report.get("pairs", []):
        if not isinstance(pair, dict):
            continue
        pair_label = pair.get("pair")
        for region in pair.get("worst_regions", []) or []:
            if not isinstance(region, dict):
                continue
            candidate = {
                "pair": pair_label,
                "name": region.get("name"),
                "ssim": region.get("ssim", 0.0),
                "p99": region.get("p99", 0),
            }
            if best is None:
                best = candidate
                continue
            candidate_key = (candidate["ssim"] or 0.0, -(candidate["p99"] or 0))
            best_key = (best["ssim"] or 0.0, -(best["p99"] or 0))
            if candidate_key < best_key:
                best = candidate
    return best


def group_results(records: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped = {group: [] for group in FAILURE_GROUPS}
    for record in records:
        group = str(record.get("classification", "capture-failed"))
        grouped.setdefault(group, []).append(record)
    return grouped


def command_for(
    mission: str,
    frame: int,
    targets: list[str],
    output_dir: pathlib.Path,
    threshold_ssim: float,
) -> list[str]:
    return [
        sys.executable,
        str(CAPTURE_CHECKPOINT),
        "mission",
        mission,
        "--frame",
        str(frame),
        "--targets",
        ",".join(targets),
        "--output",
        str(output_dir),
        "--keep",
        "0",
        "--threshold-ssim",
        str(threshold_ssim),
    ]


def run_capture(
    mission: str,
    frame: int,
    targets: list[str],
    output_dir: pathlib.Path,
    threshold_ssim: float,
    timeout: int | None,
) -> dict[str, Any]:
    cmd = command_for(mission, frame, targets, output_dir, threshold_ssim)
    child_start_time = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        result = subprocess.CompletedProcess(cmd, 124, stdout, stderr)
        stderr = (result.stderr + f"\nTimed out after {timeout}s").strip()
        result = subprocess.CompletedProcess(cmd, 124, result.stdout, stderr)
    session = find_session_path(
        result.stdout, output_dir, child_start_time, mission, frame, targets
    )
    record = build_record(mission, frame, targets, session, result)
    record["command"] = cmd
    return record


def write_reports(output_dir: pathlib.Path, report: dict[str, Any]) -> None:
    grouped = group_results(report["results"])
    json_report = dict(report)
    json_report["groups"] = {group: rows for group, rows in grouped.items() if rows}
    (output_dir / "matrix-report.json").write_text(
        json.dumps(json_report, indent=2) + "\n"
    )

    lines = [
        "# Capture Matrix Report",
        "",
        f"- Output: `{output_dir}`",
        f"- Missions: {', '.join(report['missions'])}",
        f"- Frames: {', '.join(str(frame) for frame in report['frames'])}",
        f"- Targets: {', '.join(report['targets'])}",
        "",
        "## Summary",
        "",
    ]
    for group in FAILURE_GROUPS:
        lines.append(f"- {group}: {len(grouped.get(group, []))}")
    lines.extend(["", "## Results", ""])
    for group in FAILURE_GROUPS:
        rows = grouped.get(group, [])
        if not rows:
            continue
        lines.extend([f"### {group}", ""])
        lines.append("| Mission | Frame | Worst Region | Session | Details |")
        lines.append("|---|---:|---|---|---|")
        for row in rows:
            session = row.get("session") or ""
            worst_region = worst_region_details(row)
            details = result_details(row)
            lines.append(
                f"| {row['mission']} | {row['frame']} | {worst_region} | `{session}` | {details} |"
            )
        lines.append("")
    (output_dir / "matrix-report.md").write_text("\n".join(lines) + "\n")


def result_details(row: dict[str, Any]) -> str:
    if row.get("classification") == "pass":
        report = row.get("report")
        if isinstance(report, dict):
            summary = report.get("summary")
            if summary:
                return f"comparison {summary}"
        return "capture succeeded"
    failures = row.get("failures")
    if isinstance(failures, dict) and failures:
        keys = ",".join(sorted(failures))
        return f"failures: `{keys}`"
    stderr = str(row.get("stderr") or "").splitlines()
    stdout = str(row.get("stdout") or "").splitlines()
    text = stderr[-1] if stderr else (stdout[-1] if stdout else "")
    return text.replace("|", "\\|")[:160]


def worst_region_details(row: dict[str, Any]) -> str:
    region = row.get("worst_region")
    if not isinstance(region, dict):
        return ""
    name = str(region.get("name") or "")
    pair = str(region.get("pair") or "")
    ssim = region.get("ssim")
    p99 = region.get("p99")
    ssim_text = f"{ssim:.4f}" if isinstance(ssim, (int, float)) else str(ssim)
    return f"`{name}` {ssim_text} p99={p99} `{pair}`"


def make_output_dir(base: str | None) -> pathlib.Path:
    if base:
        path = pathlib.Path(base)
    else:
        timestamp = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
        path = pathlib.Path("/tmp/battlecontrol") / f"{timestamp}-matrix"
    path.mkdir(parents=True, exist_ok=True)
    return path


def run_self_test() -> int:
    missions = parse_missions("allied-l1..l3,soviet-l2")
    assert missions == ["allied-l1", "allied-l2", "allied-l3", "soviet-l2"]
    assert parse_missions("soviet-l3..l1") == ["soviet-l3", "soviet-l2", "soviet-l1"]
    assert parse_frames("1,10,60") == [1, 10, 60]
    assert parse_targets("wine,native") == ["wine", "native"]

    records = [
        {"classification": "pass", "mission": "allied-l1", "frame": 1},
        {"classification": "wine-main-menu", "mission": "allied-l2", "frame": 1},
        {"classification": "comparison-failed", "mission": "allied-l3", "frame": 1},
        {"classification": "wine-main-menu", "mission": "soviet-l1", "frame": 1},
    ]
    grouped = group_results(records)
    assert [r["classification"] for r in grouped["wine-main-menu"]] == [
        "wine-main-menu",
        "wine-main-menu",
    ]
    assert list(grouped) == FAILURE_GROUPS

    timeout_record = {
        "returncode": 1,
        "targets": ["wine"],
        "stderr": "frameprobe timeout before target frame",
        "manifest": {},
        "report": {},
    }
    assert classify_result(timeout_record) == "wine-frame-timeout"
    generic_timeout_record = {
        "returncode": 1,
        "targets": ["native"],
        "stderr": "Timed out after 30s",
        "manifest": {},
        "report": {},
    }
    assert classify_result(generic_timeout_record) == "capture-failed"
    missing_report_record = {
        "returncode": 0,
        "targets": ["wine", "native"],
        "manifest": {"captures": {"wine": "wine.png", "native": "native.png"}},
        "report": {},
    }
    assert classify_result(missing_report_record) == "comparison-failed"
    single_target_record = {
        "returncode": 0,
        "targets": ["wine"],
        "manifest": {"captures": {"wine": "wine.png"}},
        "report": {},
    }
    assert classify_result(single_target_record) == "pass"
    state_record = {
        "returncode": 1,
        "targets": ["wine"],
        "manifest": {
            "failures": {
                "wine": {
                    "screen_timeline": {
                        "last_state": "top-scores",
                        "states": ["main-menu", "top-scores"],
                    }
                }
            }
        },
        "report": {},
    }
    assert classify_result(state_record) == "wine-top-scores"
    region_record = {
        "report": {
            "pairs": [
                {
                    "pair": "wine-vs-native",
                    "worst_regions": [
                        {"name": "timer_credit_tab", "ssim": 0.5, "p99": 90}
                    ],
                }
            ]
        }
    }
    assert extract_worst_region(region_record) == {
        "pair": "wine-vs-native",
        "name": "timer_credit_tab",
        "ssim": 0.5,
        "p99": 90,
    }

    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp)
        write_reports(
            out,
            {
                "missions": missions,
                "frames": [1],
                "targets": ["wine", "native"],
                "results": [
                    *records,
                    {
                        "mission": "allied-l4",
                        "frame": 1,
                        "classification": "comparison-failed",
                        "worst_region": extract_worst_region(region_record),
                        **region_record,
                    },
                ],
                "timestamp": "self-test",
            },
        )
        assert (out / "matrix-report.json").exists()
        text = (out / "matrix-report.md").read_text()
        assert "wine-main-menu" in text
        assert "comparison-failed" in text
        assert "Worst Region" in text
        assert "timer_credit_tab" in text
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--missions", type=parse_missions, help="missions or ranges")
    ap.add_argument("--frames", type=parse_frames, help="comma-separated frames")
    ap.add_argument("--targets", default="wine,native", type=parse_targets)
    ap.add_argument("--output", default=None, help="matrix output directory")
    ap.add_argument(
        "--threshold-ssim",
        type=float,
        default=0.90,
        help="SSIM pass threshold passed through to capture-checkpoint.py",
    )
    ap.add_argument(
        "--timeout",
        type=int,
        default=None,
        help="per-capture timeout in seconds",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="expand the matrix and write reports without launching captures",
    )
    ap.add_argument(
        "--allow-failures",
        action="store_true",
        help="exit 0 even when captures or comparisons fail",
    )
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return run_self_test()
    if args.missions is None:
        ap.error("--missions is required unless --self-test is used")
    if args.frames is None:
        ap.error("--frames is required unless --self-test is used")

    output_dir = make_output_dir(args.output)
    report: dict[str, Any] = {
        "missions": args.missions,
        "frames": args.frames,
        "targets": args.targets,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "results": [],
    }
    write_reports(output_dir, report)

    for mission in args.missions:
        for frame in args.frames:
            print(f"=== {mission} frame {frame} ===")
            if args.dry_run:
                record: dict[str, Any] = {
                    "mission": mission,
                    "frame": frame,
                    "targets": args.targets,
                    "classification": "pass",
                    "dry_run": True,
                    "command": command_for(
                        mission,
                        frame,
                        args.targets,
                        output_dir,
                        args.threshold_ssim,
                    ),
                }
            else:
                record = run_capture(
                    mission,
                    frame,
                    args.targets,
                    output_dir,
                    args.threshold_ssim,
                    args.timeout,
                )
                if record.get("stdout"):
                    print(str(record["stdout"]).rstrip())
                if record.get("stderr"):
                    print(str(record["stderr"]).rstrip(), file=sys.stderr)
            report["results"].append(record)
            write_reports(output_dir, report)
            print(f"  {record['classification']}")

    grouped = group_results(report["results"])
    print(f"\nMatrix report: {output_dir / 'matrix-report.md'}")
    for group in FAILURE_GROUPS:
        count = len(grouped.get(group, []))
        if count:
            print(f"  {group}: {count}")
    failed = sum(
        count
        for group, rows in grouped.items()
        if group != "pass"
        for count in [len(rows)]
    )
    return 0 if args.allow_failures or failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
