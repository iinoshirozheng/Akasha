"""Run phase11 snapshot cost cells in isolated processes, excluding compilation."""

import argparse
import json
from pathlib import Path
import platform
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", required=True, help="Engine/harness revision or worktree identifier")
    args = parser.parse_args()
    cells = []
    for delta in [0, 16]:
        for leases in [1, 8]:
            runs = []
            for _ in range(3):
                output = subprocess.check_output(
                    [str(args.binary.resolve()), "--snapshot-cost", str(delta), str(leases)], text=True)
                rows = []
                for line in output.splitlines():
                    label, *tokens = line.split()
                    rows.append({"kind": label, **{key: int(value) for key, value in
                                                 (token.split("=") for token in tokens)}})
                runs.append(rows)
            memories = [run[-1] for run in runs]
            summary = {key: statistics.median(run[key] for run in memories)
                       for key in ["capture_total_ns", "baseline_rss", "held_rss", "closed_rss", "dropped_rss"]}
            captures = [[row for row in run if row["kind"] == "snapshot_capture"] for run in runs]
            summary["first_capture_ns"] = statistics.median(run[0]["capture_ns"] for run in captures)
            repeats = [row["capture_ns"] for run in captures for row in run[1:]]
            summary["repeat_capture_ns"] = statistics.median(repeats) if repeats else None
            summary["authoritative_copy_bytes"] = statistics.median(
                sum(row["authoritative_copy_bytes"] for row in run) for run in captures)
            summary["base_builds"] = statistics.median(
                sum(row["base_builds"] for row in run) for run in captures)
            summary["held_rss_increase"] = statistics.median(r["held_rss"] - r["baseline_rss"] for r in memories)
            cells.append({"delta_points_per_capture": delta, "live_snapshots": leases,
                          "median": summary, "runs": runs})
            print(json.dumps(cells[-1]["median"]), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"source": args.source,
                                     "capture_path": "ReadGenerationCache.acquire (shared with PersistentCollection; excludes manifest I/O and writer lock)",
                                     "platform": platform.platform(), "points": 4096,
                                     "dimension": 128, "payload_bytes_per_point": 256,
                                     "sparse_elements_per_point": 2, "cells": cells}, indent=2) + "\n")


if __name__ == "__main__":
    main()
