#!/usr/bin/env python3
"""Capture a deterministic sequence of RA95 Wine render frames via cnc-ddraw."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers.wine import WineCapture


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
BC_CAPTURE_RE = re.compile(
    r"bc-capture: render_frame=(?P<render>\d+) ra_frame=(?P<ra>-?\d+) "
    r"(?:key=(?P<key>-?\d+) )?file=(?P<file>.*?) result=(?P<result>\w+)"
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
    return (
        os.environ.get("WINE_DATA_DIR")
        or os.environ.get("DATA_DIR")
        or os.environ.get("RA_ASSETS")
    )


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
        match = BC_CAPTURE_RE.search(line)
        if not match:
            continue
        render_frame = int(match.group("render"))
        key = int(match.group("key") or render_frame)
        rows[key] = {
            "render_frame": render_frame,
            "ra_frame": int(match.group("ra")),
            "key": key,
            "wine_file": match.group("file"),
            "result": match.group("result"),
        }
    return rows


def write_report(
    output_dir: pathlib.Path,
    sequence_dir: pathlib.Path,
    start: int,
    count: int,
    scenario: str,
    clock: str,
) -> pathlib.Path:
    log_rows = parse_capture_log(output_dir / "wine-driver.log")
    frames = []
    if clock == "ra":
        frame_ids = [
            int(path.stem.removeprefix("frame_"))
            for path in sorted(sequence_dir.glob("frame_*.png"))
        ][:count]
    else:
        frame_ids = list(range(start, start + count))
    for frame_id in frame_ids:
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
        "type": "wine-sequence",
        "scenario": scenario,
        "start": start,
        "count": count,
        "clock": clock,
        "sequence_dir": str(sequence_dir),
        "complete": len(frames) == count
        and all(row["exists"] and row["size"] > 0 for row in frames),
        "frames": frames,
    }
    report_path = output_dir / "wine-sequence-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return report_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mission", help="mission id, e.g. allied-l1 or SCG01EA")
    parser.add_argument("--start", type=int, default=1)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--clock", choices=["ra", "render"], default="ra")
    parser.add_argument("--output", default="/tmp/battlecontrol")
    parser.add_argument("--fps", default="60")
    parser.add_argument("--seed", default=DEFAULT_RA_RANDOM_SEED)
    parser.add_argument("--timeout", default="120")
    args = parser.parse_args()

    scenario = resolve_scenario(args.mission)
    data_dir = mission_data_dir(scenario)
    if not data_dir:
        raise RuntimeError("WINE_DATA_DIR/DATA_DIR/RA_ASSETS is required")

    os.environ.setdefault("RA_RANDOM_SEED", args.seed)
    os.environ["RA_CAPTURE_FPS"] = args.fps
    os.environ["WINE_CNCDDRAW_CAPTURE_TIMEOUT"] = args.timeout

    timestamp = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H-%M-%S")
    output_dir = pathlib.Path(args.output) / f"{timestamp}-wine-sequence-{args.mission}"
    output_dir.mkdir(parents=True, exist_ok=True)

    driver = WineCapture(data_dir=data_dir)
    log_path = output_dir / "wine-driver.log"
    with log_path.open("w") as logfile:
        sequence_dir = driver.capture_mission_sequence(
            scenario, args.start, args.count, output_dir, args.clock, logfile
        )

    report_path = write_report(
        output_dir, sequence_dir, args.start, args.count, scenario, args.clock
    )
    print(f"Sequence dir: {sequence_dir}")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
