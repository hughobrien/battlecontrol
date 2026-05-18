# Archived Capture Scripts

These per-campaign shell scripts have been subsumed by the unified Python
orchestrator [`scripts/capture-checkpoint.py`](../capture-checkpoint.py) and
its driver modules in [`scripts/drivers/`](../drivers/).

| Archived Script | Subsumed By |
|----------------|-------------|
| `gen-gameplay-goldens.sh` | `capture-checkpoint.py` + `drivers/compare.py` |
| `native-capture.sh` | `capture-checkpoint.py mission <id> --targets native` |
| `wine-allied-l1.sh` | `capture-checkpoint.py mission allied-l1 --targets wine` |
| `wine-allied-m2.sh` | `capture-checkpoint.py mission allied-m2 --targets wine` |
| `wine-gameplay.sh` | `capture-checkpoint.py mission allied-l1 --targets wine --mode gameplay` |
| `wine-soviet-l1.sh` | `capture-checkpoint.py mission soviet-l1 --targets wine` |
| `wine-soviet-m2.sh` | `capture-checkpoint.py mission soviet-m2 --targets wine` |
| `wine-vqa-capture.sh` | `capture-checkpoint.py vqa <stem> --targets wine` |

These scripts are kept for reference only. Do not use them for new capture work.
