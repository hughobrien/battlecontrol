#!/usr/bin/env python3
"""Capture the same checkpoint across several early frames.

Wraps capture-checkpoint.py so parity investigations can see whether two
targets diverge immediately or progressively without manually running one
command per frame.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import time
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CAPTURE_CHECKPOINT = SCRIPT_DIR / "capture-checkpoint.py"
SESSION_LINE_RE = re.compile(r"^Session dir:\s*(?P<path>.+)$", re.MULTILINE)
BAD_STATES = {"score", "top-scores", "main-menu"}


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
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        return {"_error": f"malformed JSON: {exc}"}


def find_session_path(
    stdout: str, output_dir: pathlib.Path, child_start_time: float
) -> pathlib.Path | None:
    matches = SESSION_LINE_RE.findall(stdout)
    if matches:
        return pathlib.Path(matches[-1].strip())
    sessions = [
        path
        for path in output_dir.iterdir()
        if path.is_dir() and path.stat().st_mtime >= child_start_time
    ]
    if not sessions:
        return None
    sessions.sort(key=lambda path: (path.stat().st_mtime, path.name), reverse=True)
    return sessions[0]


def timeline_state(summary: dict[str, Any]) -> str | None:
    if not summary:
        return None
    last_state = summary.get("last_state")
    if isinstance(last_state, str):
        return last_state
    states = summary.get("states")
    if isinstance(states, list) and states:
        return str(states[-1])
    return None


def collect_target_states(
    targets: list[str], manifest: dict[str, Any], failures: dict[str, Any]
) -> dict[str, str]:
    target_states: dict[str, str] = {}
    screen_timelines = manifest.get("screen_timelines", {})
    if isinstance(screen_timelines, dict):
        for target in targets:
            state = timeline_state(screen_timelines.get(target, {}))
            if state:
                target_states[target] = state
    if isinstance(failures, dict):
        for target in targets:
            failure = failures.get(target, {})
            if not isinstance(failure, dict):
                continue
            state = timeline_state(failure.get("screen_timeline", {}))
            if state:
                target_states[target] = state
    return target_states


def promoted_diff_path(session: pathlib.Path | None, diff_path: Any) -> str | None:
    if not diff_path:
        return None
    if session is None:
        return str(diff_path)
    promoted = session / pathlib.Path(str(diff_path)).name
    return str(promoted if promoted.exists() else diff_path)


def comparison_entry(
    session: pathlib.Path | None, pair: dict[str, Any]
) -> dict[str, Any]:
    item: dict[str, Any] = {}
    for key in ("pair", "ssim", "passed", "p99"):
        if key in pair:
            item[key] = pair[key]
    diff = promoted_diff_path(session, pair.get("diff_path"))
    if diff:
        item["diff"] = diff
    return item


def collect_captures(
    targets: list[str], session: pathlib.Path | None, manifest: dict[str, Any]
) -> dict[str, str]:
    captures: dict[str, str] = {}
    manifest_captures = manifest.get("captures", {})
    if isinstance(manifest_captures, dict):
        captures.update(
            {
                target: manifest_captures[target]
                for target in targets
                if target in manifest_captures
            }
        )
    if session is not None:
        for target in targets:
            path = session / f"{target}.png"
            if target not in captures and path.exists():
                captures[target] = str(path)
    return captures


def aggregate_frame_result(
    capture_type: str,
    capture_id: str,
    requested: int,
    targets: list[str],
    session: pathlib.Path | None,
    returncode: int,
    stdout: str,
    stderr: str,
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "requested": requested,
        "status": "ok" if returncode == 0 else "failed",
    }
    if session is not None:
        entry["session"] = str(session)

    manifest = load_json(session / "manifest.json") if session is not None else {}
    report = load_json(session / "report.json") if session is not None else {}
    if manifest.get("_error"):
        entry["manifest_error"] = manifest["_error"]
    if report.get("_error"):
        entry["report_error"] = report["_error"]

    effective_frames = manifest.get("effective_frames", {})
    if isinstance(effective_frames, dict):
        for target in targets:
            actual = effective_frames.get(target)
            if actual is not None:
                entry[f"{target}_actual"] = actual

    captures = collect_captures(targets, session, manifest)
    if captures:
        entry["captures"] = captures

    failures = manifest.get("failures", {})
    if isinstance(failures, dict) and failures:
        entry["failures"] = failures

    target_states = collect_target_states(targets, manifest, failures)
    if target_states:
        entry["target_states"] = target_states
        for target in targets:
            if target in target_states:
                entry["state"] = target_states[target]
                break

    pairs = report.get("pairs", [])
    if isinstance(pairs, list) and pairs:
        comparisons = [
            comparison_entry(session, pair) for pair in pairs if isinstance(pair, dict)
        ]
        if comparisons:
            entry["comparisons"] = comparisons
            first_pair = comparisons[0]
            if "ssim" in first_pair:
                entry["ssim"] = first_pair["ssim"]
            if "passed" in first_pair:
                entry["comparison_passed"] = first_pair["passed"]
            if "pair" in first_pair:
                entry["comparison_pair"] = first_pair["pair"]
            if "diff" in first_pair:
                entry["diff"] = first_pair["diff"]
    if "summary" in report:
        entry["comparison_summary"] = report["summary"]

    if returncode != 0:
        reason = (
            stderr.strip() or stdout.strip() or f"capture-checkpoint rc={returncode}"
        )
        entry["failure_reason"] = reason[-4000:]
    if not manifest and returncode == 0:
        entry["status"] = "failed"
        entry["failure_reason"] = "capture completed but manifest.json was not found"
    if capture_type == "mission":
        entry["mission"] = capture_id
    return entry


def should_stop(entry: dict[str, Any]) -> bool:
    if entry.get("status") != "ok":
        return True
    target_states = entry.get("target_states")
    if isinstance(target_states, dict):
        return any(state in BAD_STATES for state in target_states.values())
    state = entry.get("state")
    return isinstance(state, str) and state in BAD_STATES


def image_tool() -> str | None:
    for candidate in ("montage", "magick"):
        path = shutil.which(candidate)
        if path:
            return path
    return None


def make_contact_sheet(
    tool: str,
    images: list[pathlib.Path],
    output: pathlib.Path,
    label_prefix: str,
) -> bool:
    if not images:
        return False
    output.parent.mkdir(parents=True, exist_ok=True)
    if pathlib.Path(tool).name == "magick":
        cmd = [
            tool,
            "montage",
            *[str(path) for path in images],
            "-label",
            f"{label_prefix} %f",
            "-tile",
            "x1",
            "-geometry",
            "320x200+4+24",
            str(output),
        ]
    else:
        cmd = [
            tool,
            *[str(path) for path in images],
            "-label",
            f"{label_prefix} %f",
            "-tile",
            "x1",
            "-geometry",
            "320x200+4+24",
            str(output),
        ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=60)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return output.exists()


def write_report(
    output_dir: pathlib.Path,
    capture_type: str,
    capture_id: str,
    frames: list[dict[str, Any]],
    targets: list[str],
    contact_sheets: dict[str, str],
) -> pathlib.Path:
    report: dict[str, Any] = {
        "type": capture_type,
        "id": capture_id,
        "targets": targets,
        "frames": frames,
        "contact_sheets": contact_sheets,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if capture_type == "mission":
        report["mission"] = capture_id
    path = output_dir / "strip-report.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    return path


def build_contact_sheets(
    output_dir: pathlib.Path,
    frames: list[dict[str, Any]],
    targets: list[str],
) -> dict[str, str]:
    tool = image_tool()
    sheets: dict[str, str] = {}
    if tool is None:
        return sheets
    for target in targets:
        images = []
        for entry in frames:
            capture_path = entry.get("captures", {}).get(target)
            if capture_path and pathlib.Path(capture_path).exists():
                images.append(pathlib.Path(capture_path))
        out = output_dir / f"{target}-strip.png"
        if make_contact_sheet(tool, images, out, target):
            sheets[target] = str(out)
    diff_images = []
    for entry in frames:
        comparisons = entry.get("comparisons", [])
        if isinstance(comparisons, list):
            for comparison in comparisons:
                if not isinstance(comparison, dict):
                    continue
                diff_path = comparison.get("diff")
                if diff_path and pathlib.Path(diff_path).exists():
                    diff_images.append(pathlib.Path(diff_path))
        diff_path = entry.get("diff")
        if diff_path and pathlib.Path(diff_path).exists():
            path = pathlib.Path(diff_path)
            if path not in diff_images:
                diff_images.append(path)
    diff_out = output_dir / "diff-strip.png"
    if make_contact_sheet(tool, diff_images, diff_out, "diff"):
        sheets["diff"] = str(diff_out)
    return sheets


def run_child(
    capture_type: str,
    capture_id: str,
    frame: int,
    targets: list[str],
    output_dir: pathlib.Path,
    threshold_ssim: float,
) -> tuple[subprocess.CompletedProcess[str], pathlib.Path | None]:
    cmd = [
        sys.executable,
        str(CAPTURE_CHECKPOINT),
        capture_type,
        capture_id,
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
    child_start_time = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True)
    session = find_session_path(result.stdout, output_dir, child_start_time)
    return result, session


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("type", choices=["mission"], help="capture type")
    ap.add_argument("id", help="mission id, for example allied-l2")
    ap.add_argument("--frames", required=True, type=parse_frames)
    ap.add_argument("--targets", default="wine,native", type=parse_targets)
    ap.add_argument(
        "--output",
        default=None,
        help="strip output directory (default: /tmp/battlecontrol/<timestamp>-strip-...)",
    )
    ap.add_argument(
        "--keep",
        type=int,
        default=0,
        help="reserved for future strip-level cleanup; child sessions are always kept",
    )
    ap.add_argument(
        "--threshold-ssim",
        type=float,
        default=0.90,
        help="SSIM pass threshold passed through to capture-checkpoint.py",
    )
    ap.add_argument(
        "--continue-on-bad-state",
        action="store_true",
        help="continue after a failed capture or score/menu state",
    )
    args = ap.parse_args()

    timestamp = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
    output_dir = (
        pathlib.Path(args.output)
        if args.output
        else pathlib.Path("/tmp/battlecontrol")
        / f"{timestamp}-strip-{args.type}-{args.id}"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    frames: list[dict[str, Any]] = []
    contact_sheets: dict[str, str] = {}
    report_path = write_report(
        output_dir, args.type, args.id, frames, args.targets, contact_sheets
    )
    exit_code = 0

    for frame in args.frames:
        print(f"=== frame {frame} ===")
        result, session = run_child(
            args.type,
            args.id,
            frame,
            args.targets,
            output_dir,
            args.threshold_ssim,
        )
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        entry = aggregate_frame_result(
            args.type,
            args.id,
            frame,
            args.targets,
            session,
            result.returncode,
            result.stdout,
            result.stderr,
        )
        frames.append(entry)
        contact_sheets = build_contact_sheets(output_dir, frames, args.targets)
        report_path = write_report(
            output_dir, args.type, args.id, frames, args.targets, contact_sheets
        )
        if should_stop(entry):
            exit_code = result.returncode or 1
            print(f"Stopping at frame {frame}; report written to {report_path}")
            if not args.continue_on_bad_state:
                break
            exit_code = 0

    print(f"\nStrip report: {report_path}")
    if contact_sheets:
        for name, path in contact_sheets.items():
            print(f"Contact sheet {name}: {path}")
    else:
        print("Contact sheets unavailable: ImageMagick montage/magick not found")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
