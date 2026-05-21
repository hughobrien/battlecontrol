#!/usr/bin/env python3
"""Capture checkpoint screenshots from any mission or VQA across all targets.

Drives Wine OG, native Linux, and WASM capture drivers to produce
pixel-level parity comparisons.

Usage:
  capture-checkpoint mission allied-l2 --frame 200 --targets wine,native
  capture-checkpoint vqa ENGLISH --frame 120 --targets wine
  capture-checkpoint mission allied-l1 --targets all
  capture-checkpoint title --targets wine
  capture-checkpoint menu --targets wine
"""

import argparse
import sys
import pathlib
import json
import os
import re
import shutil
import subprocess
import time
import socket
import hashlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers import WineCapture, NativeCapture, WasmCapture
from drivers.wine import parse_wine_state_line
from drivers.compare import full_report
from drivers.common import (
    check_tmp_free_space,
    PreflightError,
    remove_known_safe_artifacts,
    require_capture_tools,
    screenshot_ok,
    tactical_nonblack_fraction,
)

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

SESSION_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(mission|vqa|title|menu)-"
)
DEFAULT_RA_RANDOM_SEED = "0x1eed5eed"


def resolve_scenario(id: str) -> str:
    if id.upper().startswith("SC"):
        return id
    if id in SCENARIO_MAP:
        return SCENARIO_MAP[id]
    raise ValueError(
        f"unknown mission: {id} (try allied-l1..allied-l5 or soviet-l1..soviet-l5)"
    )


def apply_default_mission_seed(capture_type: str) -> str | None:
    if capture_type != "mission":
        return None
    seed = os.environ.get("RA_RANDOM_SEED")
    if seed:
        return seed
    os.environ["RA_RANDOM_SEED"] = DEFAULT_RA_RANDOM_SEED
    return DEFAULT_RA_RANDOM_SEED


def nix_build_package(attr: str) -> str:
    nix = os.environ.get("NIX_BIN", "/nix/var/nix/profiles/default/bin/nix")
    r = subprocess.run(
        [nix, "build", f".#{attr}", "--impure", "--print-out-paths"],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"nix build .#{attr} failed (rc={r.returncode}): {r.stderr.strip()}"
        )
    return r.stdout.strip()


def mission_data_dir(scenario: str, target: str) -> str | None:
    if not scenario:
        return None
    is_soviet = scenario.upper().startswith("SCU")
    if is_soviet and target == "wine":
        override = os.environ.get("RA_SOVIET_ASSETS")
        if override:
            return override
        return nix_build_package("ra-data-soviet")
    if target == "wine":
        return os.environ.get("WINE_DATA_DIR")
    return os.environ.get("DATA_DIR") or os.environ.get("RA_ASSETS")


def prune_old_sessions(
    output_root: pathlib.Path, keep: int, current: pathlib.Path
) -> int:
    if keep <= 0:
        return 0
    sessions = [
        path
        for path in output_root.iterdir()
        if path.is_dir() and SESSION_RE.match(path.name)
    ]
    sessions.sort(key=lambda path: (path.stat().st_mtime, path.name), reverse=True)

    removed = 0
    for path in sessions[keep:]:
        if path == current:
            continue
        shutil.rmtree(path)
        removed += 1
    return removed


CAPTURE_ENV_KEYS = [
    "RA_CAPTURE_FPS",
    "WINE_FRAMEPROBE",
    "WINE_FRAMEPROBE_STRICT",
    "WINE_FRAME_ADDR",
    "RA_SYNC_NATIVE_TO_WINE_FRAME",
    "WINE_FRAMEPROBE_BACKEND",
    "WINE_BIN",
    "WINE_DATA_DIR",
    "RA_SOVIET_ASSETS",
    "DATA_DIR",
    "RA_ASSETS",
    "RA_RANDOM_SEED",
    "WINE_BOOT_DISMISS",
    "WINE_MENU_DRIVE",
]


def sha256_file(path: pathlib.Path) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def file_metadata(path: str | None) -> dict:
    if not path:
        return {"path": None, "exists": False}
    p = pathlib.Path(path)
    data = {"path": str(p), "exists": p.exists()}
    if p.exists() and p.is_file():
        stat = p.stat()
        data.update(
            {
                "size": stat.st_size,
                "mtime": int(stat.st_mtime),
                "sha256": sha256_file(p),
            }
        )
    return data


def default_native_ra_path() -> str:
    for candidate in ("build/ra/redalert", "build/ra"):
        if pathlib.Path(candidate).is_file():
            return candidate
    return "build/ra/redalert"


def git_value(args: list[str]) -> str | None:
    try:
        r = subprocess.run(
            ["git", *args],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def capture_environment_metadata(targets: list[str]) -> dict:
    return {
        "env": {key: os.environ.get(key) for key in CAPTURE_ENV_KEYS},
        "git_commit": git_value(["rev-parse", "HEAD"]),
        "git_dirty": bool(git_value(["status", "--porcelain"])),
        "tools": {
            "wine": file_metadata(os.environ.get("WINE_BIN") or shutil.which("wine")),
            "native_ra": file_metadata(
                os.environ.get("RA_BIN") or default_native_ra_path()
            ),
            "nix": file_metadata(os.environ.get("NIX_BIN") or shutil.which("nix")),
        },
        "targets": targets,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "type", choices=["mission", "vqa", "title", "menu"], help="capture type"
    )
    ap.add_argument("id", help="mission (allied-l1) or VQA stem (ENGLISH)")
    ap.add_argument(
        "--frame", type=int, default=0, help="frame number to capture (default: 0)"
    )
    ap.add_argument(
        "--targets",
        default="wine,native",
        help="comma-separated targets: wine,native,wasm,all",
    )
    ap.add_argument(
        "--output", default="/tmp/battlecontrol", help="output root directory"
    )
    ap.add_argument(
        "--threshold-ssim",
        type=float,
        default=0.90,
        help="SSIM pass threshold (default: 0.90)",
    )
    ap.add_argument(
        "--keep",
        type=int,
        default=None,
        help="capture sessions to keep under --output (default: RA_KEEP_CAPTURE_SESSIONS or 5)",
    )
    ap.add_argument(
        "--state-only",
        action="store_true",
        help="for mission --targets wine, dump Wine state and exit without capture/comparison",
    )
    args = ap.parse_args()

    try:
        return _run(args)
    except PreflightError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


def _run(args):
    targets = args.targets.split(",")
    if "all" in targets:
        targets = ["wine", "native", "wasm"]
    for target in targets:
        if target not in ("wine", "native", "wasm"):
            raise ValueError(f"unknown target: {target} (allowed: wine, native, wasm)")
    if args.state_only:
        if args.type != "mission":
            raise ValueError("--state-only is only supported for mission captures")
        if targets != ["wine"]:
            raise ValueError("--state-only requires --targets wine")
    if args.type == "mission" and ("wine" in targets or "native" in targets):
        os.environ.setdefault("RA_CAPTURE_FPS", "10")
    random_seed = apply_default_mission_seed(args.type)

    remove_known_safe_artifacts()
    check_tmp_free_space("/tmp")
    require_capture_tools(targets)

    output_root = pathlib.Path(args.output)
    manifest = {
        "type": args.type,
        "id": args.id,
        "frame": args.frame,
        "targets": targets,
        "state_only": bool(args.state_only),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "capture_environment": capture_environment_metadata(targets),
    }
    if random_seed is not None:
        manifest["random_seed"] = int(random_seed, 0)

    if args.type == "mission":
        scenario = resolve_scenario(args.id)
        manifest["scenario"] = f"{scenario}.INI"
        manifest["data"] = {}
    else:
        scenario = None
        manifest["vqa_stem"] = args.id

    timestamp = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
    session_base = f"{timestamp}-{args.type}-{args.id}"
    checkpoint_dir = output_root / session_base
    if checkpoint_dir.exists():
        suffix = 1
        while (output_root / f"{session_base}-{suffix}").exists():
            suffix += 1
        checkpoint_dir = output_root / f"{session_base}-{suffix}"

    checkpoint_dir.mkdir(parents=True, exist_ok=False)

    # Boot capture types (title/menu) — single target, no comparison
    if args.type in ("title", "menu"):
        for target in targets:
            if target != "wine":
                print(f"  SKIP {target}: title/menu only supports wine")
                continue
            driver = WineCapture()
            path = driver.capture_boot(args.type, checkpoint_dir)
            print(f"  OK wine: {path}")
        return

    with open(checkpoint_dir / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    def write_manifest():
        with open(checkpoint_dir / "manifest.json", "w") as f:
            json.dump(manifest, f, indent=2)

    def read_kv_file(path: pathlib.Path) -> dict:
        values = {}
        if not path.exists():
            return values
        for line in path.read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
        return values

    def read_state_file(path: pathlib.Path) -> dict:
        if not path.exists():
            return {}
        for line in path.read_text().splitlines():
            values = parse_wine_state_line(line)
            if values:
                return values
        return {}

    def summarize_timeline(path: pathlib.Path) -> dict:
        if not path.exists():
            return {
                "path": str(path),
                "status": "missing",
                "states": [],
                "last_state": "unknown",
                "ever_gameplay": None,
            }
        try:
            timeline = json.loads(path.read_text())
        except Exception as exc:
            return {
                "path": str(path),
                "status": "malformed",
                "states": [],
                "last_state": "unknown",
                "ever_gameplay": None,
                "error": str(exc),
            }
        entries = timeline.get("entries", [])
        states = [entry.get("state", "unknown") for entry in entries]
        return {
            "path": str(path),
            "status": "ok",
            "states": states,
            "last_state": states[-1] if states else "unknown",
            "ever_gameplay": "gameplay" in states,
        }

    def preserve_wine_retry_artifacts(retry: int) -> None:
        retry_dir = checkpoint_dir / f"wine-invalid-{retry}-timeline"
        timeline = checkpoint_dir / "wine-screen-timeline.json"
        screenshots = sorted(checkpoint_dir.glob("wine-screen-*.png"))
        if not timeline.exists() and not screenshots:
            return
        retry_dir.mkdir()
        if timeline.exists():
            timeline.rename(retry_dir / timeline.name)
        for path in screenshots:
            path.rename(retry_dir / path.name)

    def record_failure(target: str, exc: Exception):
        failure = {
            "error": str(exc),
            "log": str(checkpoint_dir / f"{target}-driver.log"),
        }
        frame_file = checkpoint_dir / f"{target}-frame.txt"
        if frame_file.exists():
            failure["frame"] = read_kv_file(frame_file)
        state_file = checkpoint_dir / f"{target}-state.txt"
        if state_file.exists():
            failure["state"] = read_state_file(state_file)
        screen_file = checkpoint_dir / f"{target}-screen.json"
        if screen_file.exists():
            failure["screen"] = json.loads(screen_file.read_text())
        candidates_file = checkpoint_dir / f"{target}-frame-candidates.json"
        if candidates_file.exists():
            failure["frame_candidates"] = json.loads(candidates_file.read_text())
        timeline = summarize_timeline(checkpoint_dir / f"{target}-screen-timeline.json")
        failure["screen_timeline"] = timeline
        manifest.setdefault("failures", {})[target] = failure
        write_manifest()
        print(f"  FAIL {target}: {exc}")
        if "screen" in failure:
            print(f"  Screen classified as: {failure['screen']['state']}")
        if "screen_timeline" in failure:
            timeline = failure["screen_timeline"]
            states = " -> ".join(timeline["states"]) if timeline["states"] else "<none>"
            print(
                "  Screen timeline: "
                f"{states} "
                f"(status={timeline['status']}, "
                f"ever_gameplay={timeline['ever_gameplay']}, "
                f"path={timeline['path']})"
            )
        print(f"  Session dir: {checkpoint_dir}")

    captures = {}
    effective_frames = {}
    seed_file = checkpoint_dir / "RA_RANDOM_SEED.txt"
    if args.state_only:
        log_path = checkpoint_dir / "wine-driver.log"
        with open(log_path, "w") as logfile:
            try:
                data_dir = mission_data_dir(scenario, "wine")
                if data_dir:
                    manifest["data"]["wine"] = data_dir
                    write_manifest()
                driver = WineCapture(data_dir=data_dir)
                state = driver.capture_mission_state(scenario, checkpoint_dir, logfile)
                manifest["wine_state"] = state
                timeline = summarize_timeline(
                    checkpoint_dir / "wine-screen-timeline.json"
                )
                if timeline["status"] != "missing":
                    manifest.setdefault("screen_timelines", {})["wine"] = timeline
                write_manifest()
                print(f"  OK wine state: {checkpoint_dir / 'wine-state.txt'}")
                print(f"  State: {state}")
                print(f"\nSession dir: {checkpoint_dir}")
                return 0
            except Exception as exc:
                record_failure("wine", exc)
                return 1
    for target in targets:
        target_dir = checkpoint_dir
        log_path = checkpoint_dir / f"{target}-driver.log"
        logfile = open(log_path, "w")
        try:
            if target == "wine":
                data_dir = mission_data_dir(scenario, "wine")
                if data_dir:
                    manifest["data"]["wine"] = data_dir
                    write_manifest()
                driver = WineCapture(data_dir=data_dir)
                if args.type == "mission":
                    result = driver.capture_mission(
                        scenario, args.frame, target_dir, logfile
                    )
                    min_tactical = float(
                        os.environ.get("RA_MIN_TACTICAL_NONBLACK", "0.20")
                    )
                    max_retries = int(os.environ.get("WINE_GAMEPLAY_RETRIES", "4"), 0)
                    retry = 0
                    while (
                        tactical_nonblack_fraction(str(result)) < min_tactical
                        or not screenshot_ok(str(result))
                    ) and retry < max_retries:
                        retry += 1
                        invalid_path = checkpoint_dir / f"wine-invalid-{retry}.png"
                        result.rename(invalid_path)
                        preserve_wine_retry_artifacts(retry)
                        print(
                            f"  NOTE Wine tactical viewport was blank; "
                            f"retrying gameplay capture ({retry}/{max_retries})"
                        )
                        result = driver.capture_mission(
                            scenario, args.frame, target_dir, logfile
                        )
                    tactical_fill = tactical_nonblack_fraction(str(result))
                    valid_screenshot = screenshot_ok(str(result))
                    if tactical_fill < min_tactical or not valid_screenshot:
                        raise RuntimeError(
                            "Wine capture did not enter gameplay "
                            f"(tactical nonblack={tactical_fill:.3f}, "
                            f"screenshot_ok={int(valid_screenshot)})"
                        )
                    effective_frames[target] = args.frame
                    wine_frame = checkpoint_dir / "wine-frame.txt"
                    if wine_frame.exists():
                        values = {}
                        for line in wine_frame.read_text().splitlines():
                            if "=" in line:
                                key, value = line.split("=", 1)
                                values[key] = value
                        if "actual" in values:
                            effective_frames[target] = int(values["actual"], 0)
                else:
                    result = driver.capture_vqa(
                        args.id, args.frame, target_dir, logfile
                    )
            elif target == "native":
                capture_frame = args.frame
                wine_frame = checkpoint_dir / "wine-frame.txt"
                if (
                    args.type == "mission"
                    and wine_frame.exists()
                    and os.environ.get("RA_SYNC_NATIVE_TO_WINE_FRAME", "0")
                    not in ("", "0")
                ):
                    values = {}
                    for line in wine_frame.read_text().splitlines():
                        if "=" in line:
                            key, value = line.split("=", 1)
                            values[key] = value
                    reason = values.get("reason", "")
                    actual = int(values.get("actual", args.frame), 0)
                    if reason == "target" and actual > 0:
                        capture_frame = actual
                        print(
                            f"  NOTE native frame synced to Wine actual={actual} "
                            f"(requested {args.frame})"
                        )
                    elif reason:
                        raise RuntimeError(
                            "Wine frameprobe did not reach requested target "
                            f"(requested={args.frame}, actual={actual}, reason={reason})"
                        )
                effective_frames[target] = capture_frame
                data_dir = mission_data_dir(scenario, "native")
                if data_dir:
                    manifest["data"]["native"] = data_dir
                    write_manifest()
                driver = NativeCapture(data_dir=data_dir)
                result = driver.capture_mission(
                    scenario, capture_frame, target_dir, logfile
                )
            else:  # wasm
                driver = WasmCapture()
                result = driver.capture_mission(
                    scenario, args.frame, target_dir, logfile
                )
                effective_frames[target] = args.frame
            captures[target] = str(result)
            if target == "wine" and "RA_RANDOM_SEED" in os.environ:
                seed_file.write_text(f"{os.environ['RA_RANDOM_SEED']}\n")
                manifest["random_seed"] = int(os.environ["RA_RANDOM_SEED"], 0)
            if target == "native" and seed_file.exists():
                manifest["random_seed"] = int(seed_file.read_text().strip(), 0)
            timeline = summarize_timeline(
                checkpoint_dir / f"{target}-screen-timeline.json"
            )
            if timeline["status"] != "missing":
                manifest.setdefault("screen_timelines", {})[target] = timeline
            sz = result.stat().st_size if result.exists() else 0
            if result and result.exists():
                flat_path = checkpoint_dir / f"{target}.png"
                result.rename(flat_path)
                captures[target] = str(flat_path)
                sz = flat_path.stat().st_size
            print(f"  OK {target}: {captures[target]} ({sz} bytes)")
        except Exception as exc:
            record_failure(target, exc)
            raise
        finally:
            logfile.close()

    def _remove_old_diffs():
        for old in checkpoint_dir.glob("diff-*.png"):
            old.unlink()
        diff_dir = checkpoint_dir / "diff"
        if diff_dir.exists():
            for f in diff_dir.iterdir():
                f.unlink()
            diff_dir.rmdir()

    if len(captures) >= 2:
        report = full_report(captures, str(checkpoint_dir), args.threshold_ssim)
        if (
            args.type == "mission"
            and "wine" in captures
            and "native" in captures
            and effective_frames.get("wine") == 1
            and effective_frames.get("native") == 1
            and report["summary"] != "PASS"
            and os.environ.get("RA_RETRY_NATIVE_FRAME2_ON_FAIL", "0") not in ("", "0")
        ):
            old_native = checkpoint_dir / "native.png"
            if old_native.exists():
                old_native.rename(checkpoint_dir / "native-frame1.png")
            _remove_old_diffs()
            log_path = checkpoint_dir / "native-frame2-driver.log"
            with open(log_path, "w") as logfile:
                print(
                    "  NOTE retrying native at frame 2 after frame-1 comparison failed"
                )
                driver = NativeCapture()
                result = driver.capture_mission(scenario, 2, checkpoint_dir, logfile)
            flat_path = checkpoint_dir / "native.png"
            result.rename(flat_path)
            captures["native"] = str(flat_path)
            effective_frames["native"] = 2
            report = full_report(captures, str(checkpoint_dir), args.threshold_ssim)
        print(f"\n=== Comparison: {report['summary']} ===")
        for r in report["pairs"]:
            status = "PASS" if r["passed"] else "FAIL"
            p99 = r.get("p99")
            p99_text = f"{p99:.1f}" if isinstance(p99, (int, float)) else str(p99)
            print(f"  {r['pair']}: SSIM={r['ssim']:.4f} p99={p99_text} [{status}]")
            worst = r.get("worst_regions") or []
            if worst:
                summary = ", ".join(
                    f"{region['name']} SSIM={region['ssim']:.4f} p99={region['p99']}"
                    for region in worst
                )
                print(f"    worst regions: {summary}")
        # Promote diffs from diff/ subdir to session dir
        diff_dir = checkpoint_dir / "diff"
        if diff_dir.exists():
            promoted = {}
            for f in diff_dir.iterdir():
                dest = checkpoint_dir / f.name
                promoted[str(f)] = str(dest)
                f.rename(dest)
            diff_dir.rmdir()
            if promoted:

                def promote_paths(value):
                    if isinstance(value, dict):
                        return {key: promote_paths(item) for key, item in value.items()}
                    if isinstance(value, list):
                        return [promote_paths(item) for item in value]
                    if isinstance(value, str):
                        return promoted.get(value, value)
                    return value

                report = promote_paths(report)
                with open(checkpoint_dir / "report.json", "w") as f:
                    json.dump(report, f, indent=2)
    elif len(captures) == 1:
        print("\n(one target — no comparison)")
    else:
        print("\nFAIL: no captures produced")
        sys.exit(1)

    manifest["captures"] = captures
    if effective_frames:
        manifest["effective_frames"] = effective_frames
    write_manifest()

    # Start HTTP server on port 1234, restarting it if an existing instance
    # is serving the wrong directory (so the index shows every session under
    # output_root, not just one).
    import subprocess

    def _server_dir_on_port(port):
        r = subprocess.run(
            ["pgrep", "-af", f"http.server {port}"],
            capture_output=True,
            text=True,
        )
        for line in r.stdout.splitlines():
            parts = line.split()
            if "--directory" in parts:
                return parts[parts.index("--directory") + 1]
        return None

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    running = False
    try:
        sock.connect(("localhost", 1234))
        running = True
    except ConnectionRefusedError:
        pass
    sock.close()

    want = str(output_root)
    if running:
        current = _server_dir_on_port(1234)
        if current == want:
            print(f"  HTTP server already serving {want} at http://localhost:1234/")
        else:
            print(
                f"  HTTP server on :1234 is serving {current!r}; "
                f"restarting to serve {want!r}"
            )
            subprocess.run(["pkill", "-f", "http.server 1234"], check=False)
            time.sleep(0.5)
            running = False

    if not running:
        subprocess.Popen(
            ["python3", "-m", "http.server", "1234", "--directory", want],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"  HTTP server started at http://localhost:1234/ (serving {want})")

    print(f"\nSession dir: {checkpoint_dir}")
    keep_sessions = (
        args.keep
        if args.keep is not None
        else int(os.environ.get("RA_KEEP_CAPTURE_SESSIONS", "5"), 0)
    )
    removed = prune_old_sessions(output_root, keep_sessions, checkpoint_dir)
    if removed:
        print(f"  Pruned {removed} old capture session(s); kept newest {keep_sessions}")


if __name__ == "__main__":
    sys.exit(main())
