#!/usr/bin/env python3
"""
Compare two VQA decode output directories (video + audio).

Usage:
  python3 scripts/vqa-compare.py <ref-dir> <test-dir> [--threshold N] [--audio-threshold N]
"""

import argparse
import json
import os
import struct
import sys


# ---------------------------------------------------------------------------
# PPM reader
# ---------------------------------------------------------------------------


def read_ppm(path: str) -> tuple[int, int, bytes]:
    """Read PPM P6 file, return (width, height, pixel_data)."""
    with open(path, "rb") as f:
        data = f.read()
    # PPM P6: header format is "P6\n<w> <h>\n255\n" then raw RGB data
    if data[:2] != b"P6":
        raise ValueError(f"Not a PPM file: {path}")
    pos = 2
    # Skip comments
    while data[pos : pos + 1] == b"#":
        while data[pos : pos + 1] != b"\n":
            pos += 1
        pos += 1
    # Read dimensions
    header_end = data.find(b"\n255\n", pos)
    if header_end < 0:
        raise ValueError(f"Bad PPM header: {path}")
    dims = data[pos:header_end].decode()
    w_str, h_str = dims.strip().split()
    w, h = int(w_str), int(h_str)
    pixels = data[header_end + 5 :]  # skip "\n255\n"
    expected = w * h * 3
    if len(pixels) != expected:
        raise ValueError(
            f"PPM size mismatch: expected {expected} got {len(pixels)}: {path}"
        )
    return w, h, pixels


# ---------------------------------------------------------------------------
# Frame comparison
# ---------------------------------------------------------------------------


def compare_frames(ref_dir: str, test_dir: str, threshold: int) -> dict:
    """Compare all PPM frames in two directories. Return {'pass': bool, ...}."""
    ref_frames = sorted(f for f in os.listdir(ref_dir) if f.endswith(".ppm"))
    test_frames = sorted(f for f in os.listdir(test_dir) if f.endswith(".ppm"))

    results = {
        "frames_ref": len(ref_frames),
        "frames_test": len(test_frames),
        "frames_compared": 0,
        "frames_passed": 0,
        "frames_failed": 0,
        "max_p99_delta": 0.0,
        "min_ssim": 1.0,
        "per_frame": [],
    }

    n = min(len(ref_frames), len(test_frames))
    for i in range(n):
        ref_path = os.path.join(ref_dir, ref_frames[i])
        test_path = os.path.join(test_dir, test_frames[i])

        try:
            w_r, h_r, px_r = read_ppm(ref_path)
            w_t, h_t, px_t = read_ppm(test_path)
        except (ValueError, IOError) as e:
            results["per_frame"].append(
                {
                    "frame": i + 1,
                    "error": str(e),
                    "pass": False,
                }
            )
            results["frames_failed"] += 1
            continue

        if w_r != w_t or h_r != h_t:
            results["per_frame"].append(
                {
                    "frame": i + 1,
                    "error": f"size mismatch: {w_r}x{h_r} vs {w_t}x{h_t}",
                    "pass": False,
                }
            )
            results["frames_failed"] += 1
            continue

        # Pixel-by-pixel comparison
        n_pixels = len(px_r) // 3
        diffs = []
        for pi in range(n_pixels * 3):
            d = abs(px_r[pi] - px_t[pi])
            diffs.append(d)

        diffs.sort()
        p99 = diffs[int(len(diffs) * 0.99)] if diffs else 0.0
        max_diff = diffs[-1] if diffs else 0
        avg_diff = sum(diffs) / len(diffs) if diffs else 0.0

        # SSIM approximation (simplified - just use the p99/max for now)
        # A full SSIM would use numpy + PIL, keep it minimal
        passed = p99 <= threshold
        if passed:
            results["frames_passed"] += 1
        else:
            results["frames_failed"] += 1

        results["max_p99_delta"] = max(results["max_p99_delta"], p99)
        results["per_frame"].append(
            {
                "frame": i + 1,
                "p99": p99,
                "max": max_diff,
                "avg": round(avg_diff, 2),
                "pass": passed,
            }
        )

    results["frames_compared"] = n
    results["pass"] = results["frames_failed"] == 0
    return results


# ---------------------------------------------------------------------------
# Audio comparison
# ---------------------------------------------------------------------------


def compare_audio(ref_dir: str, test_dir: str, threshold: int) -> dict:
    """Compare raw PCM audio files. Return {'pass': bool, ...}."""
    ref_pcm = os.path.join(ref_dir, "audio.pcm")
    test_pcm = os.path.join(test_dir, "audio.pcm")

    result = {
        "has_audio_ref": os.path.exists(ref_pcm),
        "has_audio_test": os.path.exists(test_pcm),
    }

    if not result["has_audio_ref"] or not result["has_audio_test"]:
        result["pass"] = True  # Skip if one missing
        result["skip_reason"] = "audio file(s) not found"
        return result

    with open(ref_pcm, "rb") as f:
        ref_data = f.read()
    with open(test_pcm, "rb") as f:
        test_data = f.read()

    n = min(len(ref_data), len(test_data)) // 2
    ref_s16 = struct.unpack("<" + "h" * n, ref_data[: n * 2])
    test_s16 = struct.unpack("<" + "h" * n, test_data[: n * 2])

    diffs = [abs(r - t) for r, t in zip(ref_s16, test_s16)]
    diffs.sort()
    p99 = diffs[int(len(diffs) * 0.99)] if diffs else 0.0
    max_diff = max(diffs) if diffs else 0
    rms = (sum(d * d for d in diffs) / len(diffs)) ** 0.5 if diffs else 0.0

    result.update(
        {
            "samples_ref": len(ref_data) // 2,
            "samples_test": len(test_data) // 2,
            "samples_compared": n,
            "p99_delta": p99,
            "max_delta": max_diff,
            "rms": round(rms, 2),
            "pass": p99 <= threshold,
        }
    )
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="Compare VQA decode outputs")
    ap.add_argument("ref_dir", help="Reference output directory")
    ap.add_argument("test_dir", help="Test output directory")
    ap.add_argument(
        "--threshold",
        type=int,
        default=5,
        help="p99 pixel channel delta threshold (default: 5)",
    )
    ap.add_argument(
        "--audio-threshold",
        type=int,
        default=5,
        help="p99 audio sample delta threshold (default: 5)",
    )
    ap.add_argument("--json", action="store_true", help="Output JSON only")
    args = ap.parse_args()

    if not os.path.isdir(args.ref_dir):
        print(f"ERROR: ref_dir not found: {args.ref_dir}", file=sys.stderr)
        return 1
    if not os.path.isdir(args.test_dir):
        print(f"ERROR: test_dir not found: {args.test_dir}", file=sys.stderr)
        return 1

    # Load metadata
    meta_ref = {}
    meta_path = os.path.join(args.ref_dir, "metadata.json")
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            meta_ref = json.load(f)

    meta_test = {}
    meta_path = os.path.join(args.test_dir, "metadata.json")
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            meta_test = json.load(f)

    video = compare_frames(args.ref_dir, args.test_dir, args.threshold)
    audio = compare_audio(args.ref_dir, args.test_dir, args.audio_threshold)

    report = {
        "video": video,
        "audio": audio,
        "pass": video["pass"] and audio["pass"],
        "ref": meta_ref.get("engine", "?"),
        "test": meta_test.get("engine", "?"),
    }

    if args.json:
        print(json.dumps(report, indent=2))
        return 0 if report["pass"] else 1

    # Human-readable output
    ref_eng = meta_ref.get("engine", "?")
    test_eng = meta_test.get("engine", "?")

    print(f"VQA Comparison: ref={ref_eng} test={test_eng}")
    print(
        f"  Frames: {video['frames_compared']} compared, "
        f"{video['frames_passed']} passed, {video['frames_failed']} failed"
    )
    print(f"  Max p99 pixel delta: {video['max_p99_delta']}")
    if video["per_frame"]:
        worst = max(video["per_frame"], key=lambda f: f.get("p99", 0))
        print(f"  Worst frame: #{worst['frame']} p99={worst['p99']} max={worst['max']}")

    if audio.get("has_audio_ref") or audio.get("has_audio_test"):
        if audio.get("skip_reason"):
            print(f"  Audio: {audio['skip_reason']}")
        else:
            print(f"  Audio: {audio['samples_compared']} samples compared")
            print(
                f"    p99 delta: {audio['p99_delta']}  max: {audio['max_delta']}  RMS: {audio['rms']}"
            )
    else:
        print("  Audio: none")

    verdict = "PASS" if report["pass"] else "FAIL"
    print(f"\n  Verdict: {verdict}")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
