#!/usr/bin/env python3
"""Capture a deterministic sequence of native RA gameplay frames."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers.native import NativeCapture


SCENARIO_MAP = {
    "allied-l1": "SCG01EA",
    "allied-l2": "SCG02EA",
    "allied-l3": "SCG03EA",
    "allied-l4": "SCG04EA",
    "allied-l5": "SCG05EA",
    "soviet-l1": "SCU01EA",
    "soviet-l2": "SCU02EA",
    "soviet-l3": "SCU03EA",
    "soviet-l4": "SCU04EA",
    "soviet-l5": "SCU05EA",
}
DEFAULT_RA_RANDOM_SEED = "0x1eed5eed"
NATIVE_SEQUENCE_ENV_KEYS = (
    "RA_CAPTURE_SEQUENCE_DIR",
    "RA_CAPTURE_SEQUENCE_START",
    "RA_CAPTURE_SEQUENCE_COUNT",
    "RA_CAPTURE_SEQUENCE_READY_FILE",
)
RA_CAPTURE_PRESENT_RE = re.compile(
    r"\[RA_CAPTURE_PRESENT\] mode=(?P<mode>\w+) game_frame=(?P<game>-?\d+) "
    r"present_before=(?P<present_before>-?\d+) present_frame=(?P<present>-?\d+) "
    r"path=(?P<path>.*)"
)
RA_CAPTURE_STATE_RE = re.compile(
    r"\[RA_CAPTURE_STATE\] mode=(?P<mode>\w+) game_frame=(?P<game>-?\d+) "
    r"tick=(?P<tick>\d+) game_speed=(?P<game_speed>\d+) "
    r"frame_timer=(?P<frame_timer>\d+) path=(?P<path>.*)"
)


def resolve_scenario(value: str) -> str:
    if value.upper().startswith("SC"):
        return value.upper().removesuffix(".INI")
    if value in SCENARIO_MAP:
        return SCENARIO_MAP[value]
    raise ValueError(f"unknown mission: {value}")


def mission_data_dir(scenario: str) -> str | None:
    if scenario.upper().startswith("SCU"):
        return os.environ.get("RA_SOVIET_ASSETS")
    return os.environ.get("DATA_DIR") or os.environ.get("RA_ASSETS")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_rgba(path: pathlib.Path) -> str:
    from PIL import Image

    with Image.open(path) as image:
        rgba = image.convert("RGBA")
        return hashlib.sha256(rgba.tobytes()).hexdigest()


def parse_capture_log(log_path: pathlib.Path) -> dict[int, dict]:
    rows = {}
    if not log_path.exists():
        return rows
    for line in log_path.read_text(errors="replace").splitlines():
        state_match = RA_CAPTURE_STATE_RE.search(line)
        if state_match:
            game_frame = int(state_match.group("game"))
            rows.setdefault(game_frame, {}).update(
                {
                    "game_frame": game_frame,
                    "tick_count": int(state_match.group("tick")),
                    "game_speed": int(state_match.group("game_speed")),
                    "frame_timer": int(state_match.group("frame_timer")),
                    "capture_state_mode": state_match.group("mode"),
                    "native_state_file": state_match.group("path"),
                }
            )
            continue
        match = RA_CAPTURE_PRESENT_RE.search(line)
        if not match:
            continue
        game_frame = int(match.group("game"))
        rows.setdefault(game_frame, {}).update(
            {
                "game_frame": game_frame,
                "present_before": int(match.group("present_before")),
                "present_frame": int(match.group("present")),
                "capture_mode": match.group("mode"),
                "native_file": match.group("path"),
            }
        )
    return rows


def write_report(
    output_dir: pathlib.Path,
    sequence_dir: pathlib.Path,
    start: int,
    count: int,
    scenario: str,
) -> pathlib.Path:
    log_rows = parse_capture_log(output_dir / "native-sequence-driver.log")
    frames = []
    for frame_id in range(start, start + count):
        path = sequence_dir / f"frame_{frame_id:06d}.png"
        row = {
            "frame_id": frame_id,
            "path": str(path),
            "exists": path.exists(),
            "size": path.stat().st_size if path.exists() else 0,
            "sha256": sha256_file(path) if path.exists() else None,
            "sha256_rgba": sha256_rgba(path) if path.exists() else None,
        }
        row.update(log_rows.get(frame_id, {}))
        frames.append(row)

    report = {
        "type": "native-sequence",
        "scenario": scenario,
        "start": start,
        "count": count,
        "clock": "game",
        "fps": os.environ.get("RA_CAPTURE_FPS"),
        "capture_env_keys": list(NATIVE_SEQUENCE_ENV_KEYS),
        "sequence_dir": str(sequence_dir),
        "complete": all(row["exists"] and row["size"] > 0 for row in frames),
        "frames": frames,
    }
    report_path = output_dir / "native-sequence-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return report_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mission", help="mission id, e.g. allied-l1 or SCG01EA")
    parser.add_argument("--start", type=int, default=50)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--output", default="/tmp/battlecontrol")
    parser.add_argument("--fps", default="60")
    parser.add_argument("--seed", default=DEFAULT_RA_RANDOM_SEED)
    args = parser.parse_args()

    scenario = resolve_scenario(args.mission)
    data_dir = mission_data_dir(scenario)
    if not data_dir:
        raise RuntimeError("DATA_DIR/RA_ASSETS is required")

    os.environ.setdefault("RA_RANDOM_SEED", args.seed)
    os.environ["RA_CAPTURE_FPS"] = args.fps

    timestamp = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H-%M-%S")
    output_dir = (
        pathlib.Path(args.output) / f"{timestamp}-native-sequence-{args.mission}"
    )
    sequence_dir = output_dir / "native-sequence"
    sequence_dir.mkdir(parents=True, exist_ok=True)

    driver = NativeCapture(data_dir=data_dir)
    log_path = output_dir / "native-sequence-driver.log"
    with log_path.open("w") as logfile:
        sequence_dir = driver.capture_mission_sequence(
            scenario, args.start, args.count, output_dir, logfile
        )

    report_path = write_report(
        output_dir, sequence_dir, args.start, args.count, scenario
    )
    print(f"Sequence dir: {sequence_dir}")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
