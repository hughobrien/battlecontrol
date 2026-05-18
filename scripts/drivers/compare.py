"""Comparison wrapper — compares captured screenshots via parity-compare.py."""

import subprocess, json, pathlib, shutil


def compare_pair(
    golden_path: str, capture_path: str, label: str, diff_dir: str, threshold_ssim=0.90
) -> dict:
    """Compare two images using parity-compare.py.

    Returns {pair, passed, ssim, p99, diff_path, stdout}.
    """
    diff_out = pathlib.Path(diff_dir) / f"diff-{label}.png"
    parity_script = pathlib.Path(__file__).resolve().parent.parent / "parity-compare.py"
    r = subprocess.run(
        [
            "python3",
            str(parity_script),
            golden_path,
            capture_path,
            "--label",
            label,
            "--threshold-ssim",
            str(threshold_ssim),
            "--diff-out",
            str(diff_out),
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    passed = r.returncode == 0
    data = {
        "pair": label,
        "passed": passed,
        "ssim": 0.0,
        "p99": 255,
        "diff_path": str(diff_out),
        "stdout": r.stdout,
    }
    try:
        j = json.loads(r.stdout)
        data["ssim"] = j.get("ssim", 0.0)
        data["p99"] = j.get("p99", 255)
    except (json.JSONDecodeError, ValueError):
        pass
    return data


def full_report(captures: dict, output_dir: str, threshold_ssim=0.90) -> dict:
    """Compare all captured screenshots against each other.

    captures: {target_name: path_to_png}
    Returns: {pairs: [...], summary: PASS|FAIL|PARTIAL}
    """
    diff_dir = pathlib.Path(output_dir) / "diff"
    diff_dir.mkdir(parents=True, exist_ok=True)
    targets = list(captures.keys())
    results = []
    for i in range(len(targets)):
        for j in range(i + 1, len(targets)):
            a, b = targets[i], targets[j]
            r = compare_pair(
                str(captures[a]),
                str(captures[b]),
                f"{a}-vs-{b}",
                str(diff_dir),
                threshold_ssim,
            )
            results.append(r)
    n_pass = sum(1 for r in results if r["passed"])
    n_total = len(results)
    if n_pass == n_total:
        summary = "PASS"
    elif n_pass == 0:
        summary = "FAIL"
    else:
        summary = "PARTIAL"
    report = {"pairs": results, "summary": summary, "threshold_ssim": threshold_ssim}
    with open(pathlib.Path(output_dir) / "report.json", "w") as f:
        json.dump(report, f, indent=2)
    return report
