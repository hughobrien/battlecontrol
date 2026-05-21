"""Comparison wrapper — compares captured screenshots via parity-compare.py."""

import json
import pathlib
import shutil
import subprocess
import tempfile


REGION_DIFF_LIMIT = 3

REGION_BOXES = {
    # RA gameplay captures are 640x400.  The boxes are clamped to the actual
    # image size so smaller validation images and TD 640x400 captures degrade
    # cleanly.
    "top_message_bar": (0, 0, 480, 16),
    "timer_credit_tab": (480, 0, 640, 14),
    "tactical_viewport": (0, 16, 480, 400),
    "sidebar_buttons": (480, 154, 640, 400),
    "radar_panel": (480, 14, 640, 154),
}
REGION_NAMES = ["full_frame", *REGION_BOXES.keys()]


def _metric_number(value, fallback):
    return fallback if value is None else value


def _region_error(label: str, name: str, error: str) -> dict:
    return {
        "label": f"{label}:{name}",
        "passed": False,
        "ssim": 0.0,
        "p99": 255,
        "error": error,
    }


def _parity_script() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent / "parity-compare.py"


def _run_parity_compare(
    golden_path: str,
    capture_path: str,
    label: str,
    threshold_ssim: float,
    diff_out: pathlib.Path | None = None,
) -> tuple[int, str]:
    cmd = [
        "python3",
        str(_parity_script()),
        golden_path,
        capture_path,
        "--label",
        label,
        "--threshold-ssim",
        str(threshold_ssim),
        "--json",
    ]
    if diff_out is not None:
        cmd.extend(["--diff-out", str(diff_out)])
    r = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return r.returncode, r.stdout


def _metric_from_stdout(label: str, stdout: str, diff_out: pathlib.Path | None) -> dict:
    data = {
        "label": label,
        "passed": False,
        "ssim": 0.0,
        "p99": 255,
        "stdout": stdout,
    }
    if diff_out is not None:
        data["diff_path"] = str(diff_out)
    try:
        j = json.loads(stdout)
        data["passed"] = j.get("status") == "PASS"
        data["ssim"] = _metric_number(j.get("ssim"), 0.0)
        data["p99"] = _metric_number(j.get("p99_diff", j.get("p99")), 255)
        if "error" in j:
            data["error"] = j["error"]
    except (json.JSONDecodeError, ValueError):
        pass
    return data


def compare_pair(
    golden_path: str, capture_path: str, label: str, diff_dir: str, threshold_ssim=0.90
) -> dict:
    """Compare two images using parity-compare.py.

    Returns {pair, passed, ssim, p99, diff_path, stdout}.
    """
    diff_out = pathlib.Path(diff_dir) / f"diff-{label}.png"
    returncode, stdout = _run_parity_compare(
        golden_path, capture_path, label, threshold_ssim, diff_out
    )
    passed = returncode == 0
    data = {
        "pair": label,
        "passed": passed,
        "ssim": 0.0,
        "p99": 255,
        "diff_path": str(diff_out),
        "stdout": stdout,
    }
    try:
        j = json.loads(stdout)
        data["ssim"] = _metric_number(j.get("ssim"), 0.0)
        data["p99"] = _metric_number(j.get("p99_diff", j.get("p99")), 255)
    except (json.JSONDecodeError, ValueError):
        pass
    return data


def _image_size(path: str) -> tuple[int, int] | None:
    try:
        from PIL import Image

        with Image.open(path) as im:
            return im.size
    except Exception:
        return None


def _clamp_box(
    box: tuple[int, int, int, int], width: int, height: int
) -> tuple[int, int, int, int] | None:
    left, top, right, bottom = box
    left = max(0, min(left, width))
    top = max(0, min(top, height))
    right = max(left, min(right, width))
    bottom = max(top, min(bottom, height))
    if right <= left or bottom <= top:
        return None
    return left, top, right, bottom


def _crop_with_pillow(
    src: str, box: tuple[int, int, int, int], dst: pathlib.Path
) -> bool:
    try:
        from PIL import Image

        with Image.open(src).convert("RGB") as im:
            im.crop(box).save(dst)
        return True
    except Exception:
        return False


def _crop_with_imagemagick(
    src: str, box: tuple[int, int, int, int], dst: pathlib.Path
) -> bool:
    magick = shutil.which("magick")
    convert = shutil.which("convert")
    cmd = [magick] if magick else [convert] if convert else None
    if cmd is None:
        return False

    left, top, right, bottom = box
    geometry = f"{right - left}x{bottom - top}+{left}+{top}"
    try:
        r = subprocess.run(
            [*cmd, src, "-crop", geometry, "+repage", str(dst)],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception:
        return False
    return r.returncode == 0 and dst.exists()


def _crop_image(src: str, box: tuple[int, int, int, int], dst: pathlib.Path) -> bool:
    return _crop_with_pillow(src, box, dst) or _crop_with_imagemagick(src, box, dst)


def _region_specs(golden_path: str, capture_path: str) -> dict:
    size_a = _image_size(golden_path)
    size_b = _image_size(capture_path)
    if size_a is None or size_b is None:
        return {}

    width = min(size_a[0], size_b[0])
    height = min(size_a[1], size_b[1])
    specs = {
        "full_frame": (0, 0, width, height),
        **REGION_BOXES,
    }
    clamped = {}
    for name, box in specs.items():
        region_box = _clamp_box(box, width, height)
        if region_box is not None:
            clamped[name] = region_box
    return clamped


def _compare_region(
    golden_path: str,
    capture_path: str,
    pair_label: str,
    region_name: str,
    box: tuple[int, int, int, int],
    tmp_dir: pathlib.Path,
    threshold_ssim: float,
    diff_out: pathlib.Path | None = None,
) -> dict:
    crop_a = tmp_dir / f"{pair_label}-{region_name}-a.png"
    crop_b = tmp_dir / f"{pair_label}-{region_name}-b.png"
    if not _crop_image(golden_path, box, crop_a) or not _crop_image(
        capture_path, box, crop_b
    ):
        return {
            "label": f"{pair_label}:{region_name}",
            "passed": False,
            "ssim": 0.0,
            "p99": 255,
            "box": list(box),
            "error": "unable to crop region (Pillow/ImageMagick unavailable or failed)",
        }

    returncode, stdout = _run_parity_compare(
        str(crop_a),
        str(crop_b),
        f"{pair_label}:{region_name}",
        threshold_ssim,
        diff_out,
    )
    metric = _metric_from_stdout(f"{pair_label}:{region_name}", stdout, diff_out)
    metric["passed"] = returncode == 0
    metric["box"] = list(box)
    metric["size"] = f"{box[2] - box[0]}x{box[3] - box[1]}"
    return metric


def _worst_regions(regions: dict, limit: int = REGION_DIFF_LIMIT) -> list[dict]:
    candidates = [
        {"name": name, **metric}
        for name, metric in regions.items()
        if name != "full_frame"
    ]
    interesting = [
        region
        for region in candidates
        if not region.get("passed", False) or region.get("p99", 0) > 0
    ]
    if interesting:
        candidates = interesting
    candidates.sort(
        key=lambda r: (
            _metric_number(r.get("ssim"), 0.0),
            -_metric_number(r.get("p99"), 0),
        )
    )
    return candidates[:limit]


def compare_regions(
    golden_path: str,
    capture_path: str,
    pair_label: str,
    diff_dir: str,
    threshold_ssim=0.90,
    save_diffs=False,
    diff_limit: int = REGION_DIFF_LIMIT,
) -> dict:
    """Compare stable gameplay regions for one capture pair."""
    specs = _region_specs(golden_path, capture_path)
    if not specs:
        error = "unable to read image sizes; region comparison requires Pillow"
        regions = {
            name: _region_error(pair_label, name, error) for name in REGION_NAMES
        }
        return {
            "regions": regions,
            "worst_regions": _worst_regions(regions, diff_limit),
            "error": error,
        }

    with tempfile.TemporaryDirectory(prefix="battlecontrol-regions-") as td:
        tmp_dir = pathlib.Path(td)
        regions = {}
        for name, box in specs.items():
            regions[name] = _compare_region(
                golden_path,
                capture_path,
                pair_label,
                name,
                box,
                tmp_dir,
                threshold_ssim,
            )

        worst = _worst_regions(regions, diff_limit)
        if save_diffs:
            for entry in worst:
                name = entry["name"]
                diff_out = (
                    pathlib.Path(diff_dir) / f"diff-region-{name}-{pair_label}.png"
                )
                regions[name] = _compare_region(
                    golden_path,
                    capture_path,
                    pair_label,
                    name,
                    specs[name],
                    tmp_dir,
                    threshold_ssim,
                    diff_out,
                )
            worst = _worst_regions(regions, diff_limit)

    return {"regions": regions, "worst_regions": worst}


def full_report(captures: dict, output_dir: str, threshold_ssim=0.90) -> dict:
    """Compare all captured screenshots against each other.

    captures: {target_name: path_to_png}
    Returns: {pairs: [...], regions: {...}, summary: PASS|FAIL|PARTIAL}
    """
    diff_dir = pathlib.Path(output_dir) / "diff"
    diff_dir.mkdir(parents=True, exist_ok=True)
    targets = list(captures.keys())
    results = []
    region_results = {}
    for i in range(len(targets)):
        for j in range(i + 1, len(targets)):
            a, b = targets[i], targets[j]
            pair_label = f"{a}-vs-{b}"
            r = compare_pair(
                str(captures[a]),
                str(captures[b]),
                pair_label,
                str(diff_dir),
                threshold_ssim,
            )
            region_report = compare_regions(
                str(captures[a]),
                str(captures[b]),
                pair_label,
                str(diff_dir),
                threshold_ssim,
                save_diffs=not r["passed"],
            )
            region_results[pair_label] = region_report["regions"]
            r["worst_regions"] = region_report["worst_regions"]
            results.append(r)
    n_pass = sum(1 for r in results if r["passed"])
    n_total = len(results)
    if n_pass == n_total:
        summary = "PASS"
    elif n_pass == 0:
        summary = "FAIL"
    else:
        summary = "PARTIAL"
    report = {
        "pairs": results,
        "regions": region_results,
        "summary": summary,
        "threshold_ssim": threshold_ssim,
    }
    with open(pathlib.Path(output_dir) / "report.json", "w") as f:
        json.dump(report, f, indent=2)
    return report
