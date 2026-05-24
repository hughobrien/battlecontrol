#!/usr/bin/env python3
"""Compare two numbered PNG frame sequences across possible frame offsets."""

import argparse
import json
import pathlib
import shutil

from PIL import Image, ImageChops, ImageStat


def sequence_dir(value: str) -> pathlib.Path:
    path = pathlib.Path(value)
    if path.is_file():
        report = json.loads(path.read_text())
        if "sequence_dir" not in report:
            raise ValueError(f"{path} has no sequence_dir")
        return pathlib.Path(report["sequence_dir"])
    return path


def frame_map(directory: pathlib.Path) -> dict[int, pathlib.Path]:
    frames = {}
    for path in directory.glob("frame_*.png"):
        stem = path.stem
        try:
            frame = int(stem.removeprefix("frame_"))
        except ValueError:
            continue
        frames[frame] = path
    if not frames:
        raise ValueError(f"no frame_*.png files found in {directory}")
    return frames


def load_images(frames: dict[int, pathlib.Path]) -> dict[int, Image.Image]:
    return {frame: Image.open(path).convert("RGB") for frame, path in frames.items()}


def compare_pair(a_rgb: Image.Image, b_rgb: Image.Image) -> dict[str, float | int]:
    if a_rgb.size != b_rgb.size:
        raise ValueError(f"size mismatch: a={a_rgb.size} b={b_rgb.size}")
    diff = ImageChops.difference(a_rgb, b_rgb)
    luminance = diff.convert("L")
    histogram = luminance.histogram()
    total = a_rgb.width * a_rgb.height
    diff_pixels = total - histogram[0]
    extrema = diff.getextrema()
    stat = ImageStat.Stat(diff)
    return {
        "diff_pixels": diff_pixels,
        "diff_fraction": diff_pixels / total if total else 0.0,
        "max_channel_delta": max(channel[1] for channel in extrema),
        "mean_abs_channel_delta": sum(stat.sum) / (total * 3) if total else 0.0,
    }


def score_offset(
    a_images: dict[int, Image.Image],
    b_images: dict[int, Image.Image],
    offset: int,
) -> dict[str, float | int]:
    scores = []
    for a_frame, a_image in sorted(a_images.items()):
        b_frame = a_frame + offset
        b_image = b_images.get(b_frame)
        if b_image is None:
            continue
        scores.append(compare_pair(a_image, b_image))
    if not scores:
        return {
            "frames_compared": 0,
            "avg_diff_pixels": None,
            "avg_diff_fraction": None,
            "avg_max_channel_delta": None,
            "avg_mean_abs_channel_delta": None,
        }
    count = len(scores)
    return {
        "frames_compared": count,
        "avg_diff_pixels": sum(row["diff_pixels"] for row in scores) / count,
        "avg_diff_fraction": sum(row["diff_fraction"] for row in scores) / count,
        "avg_max_channel_delta": sum(row["max_channel_delta"] for row in scores)
        / count,
        "avg_mean_abs_channel_delta": sum(
            row["mean_abs_channel_delta"] for row in scores
        )
        / count,
    }


def parse_sample_frames(value: str) -> list[int]:
    if not value:
        return []
    return [int(part) for part in value.split(",") if part.strip()]


def write_samples(
    a_frames: dict[int, pathlib.Path],
    b_frames: dict[int, pathlib.Path],
    offset: int,
    out_dir: pathlib.Path,
    sample_frames: list[int],
) -> None:
    for a_frame in sample_frames:
        b_frame = a_frame + offset
        a_path = a_frames.get(a_frame)
        b_path = b_frames.get(b_frame)
        if a_path is None or b_path is None:
            continue
        shutil.copyfile(a_path, out_dir / f"a_{a_frame:06d}.png")
        shutil.copyfile(b_path, out_dir / f"b_{b_frame:06d}.png")
        with Image.open(a_path) as a_image, Image.open(b_path) as b_image:
            diff = ImageChops.difference(a_image.convert("RGB"), b_image.convert("RGB"))
            amplified = diff.point(lambda value: min(255, value * 6))
            amplified.save(out_dir / f"diff-a{a_frame:06d}-b{b_frame:06d}.png")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--a", required=True, help="sequence dir or *-sequence-report.json"
    )
    parser.add_argument(
        "--b", required=True, help="sequence dir or *-sequence-report.json"
    )
    parser.add_argument("--offset-min", type=int, default=-10)
    parser.add_argument("--offset-max", type=int, default=10)
    parser.add_argument("--out", default="/tmp/battlecontrol/sequence-alignment")
    parser.add_argument("--sample-frames", default="")
    args = parser.parse_args()

    a_dir = sequence_dir(args.a)
    b_dir = sequence_dir(args.b)
    a_frames = frame_map(a_dir)
    b_frames = frame_map(b_dir)
    a_images = load_images(a_frames)
    b_images = load_images(b_frames)
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    offsets = {}
    for offset in range(args.offset_min, args.offset_max + 1):
        offsets[str(offset)] = score_offset(a_images, b_images, offset)
    comparable = [
        (int(offset), score)
        for offset, score in offsets.items()
        if score["frames_compared"]
    ]
    if not comparable:
        raise RuntimeError("no overlapping frames at any requested offset")
    best_offset, best_score = min(
        comparable,
        key=lambda item: (
            item[1]["avg_mean_abs_channel_delta"],
            item[1]["avg_diff_pixels"],
            -item[1]["frames_compared"],
        ),
    )

    sample_frames = parse_sample_frames(args.sample_frames)
    if sample_frames:
        write_samples(a_frames, b_frames, best_offset, out_dir, sample_frames)

    report = {
        "a": str(a_dir),
        "b": str(b_dir),
        "offset_min": args.offset_min,
        "offset_max": args.offset_max,
        "best_offset": best_offset,
        "best_score": best_score,
        "offsets": offsets,
        "sample_frames": sample_frames,
    }
    report_path = out_dir / "sequence-alignment-report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"best_offset={best_offset} frames={best_score['frames_compared']} "
        f"avg_luma_delta={best_score['avg_mean_abs_channel_delta']:.4f} "
        f"report={report_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
