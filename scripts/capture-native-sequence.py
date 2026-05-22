#!/usr/bin/env python3
"""Capture a deterministic sequence of native RA gameplay frames."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
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


def write_report(
    output_dir: pathlib.Path,
    sequence_dir: pathlib.Path,
    start: int,
    count: int,
    scenario: str,
) -> pathlib.Path:
    frames = []
    for frame_id in range(start, start + count):
        path = sequence_dir / f"frame_{frame_id:06d}.png"
        frames.append(
            {
                "frame_id": frame_id,
                "path": str(path),
                "exists": path.exists(),
                "size": path.stat().st_size if path.exists() else 0,
                "sha256": sha256_file(path) if path.exists() else None,
                "sha256_rgba": sha256_rgba(path) if path.exists() else None,
            }
        )

    report = {
        "type": "native-sequence",
        "scenario": scenario,
        "start": start,
        "count": count,
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
