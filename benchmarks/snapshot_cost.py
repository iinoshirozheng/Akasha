"""Run phase11 snapshot cost cells in isolated processes, excluding compilation."""

import argparse
import json
from pathlib import Path
import platform
import statistics
import subprocess

# (sparse mode, changed points per capture, held snapshots). Ten 1,024-point
# captures reach the sealed-run limit and include one consolidation.
CELLS = [(mode, delta, leases)
         for mode in ["dense-sparse", "dense-only"]
         for delta, leases in [(0, 1), (0, 8), (16, 1), (16, 8), (1024, 1), (1024, 8), (1024, 10)]]

COPY_KEYS = ["dense_copy_bytes", "descriptor_copies", "payload_copy_bytes", "sparse_copy_bytes"]


def _parse(output):
    rows = []
    for line in output.splitlines():
        label, *tokens = line.split()
        rows.append({"kind": label, **{key: int(value) for key, value in
                                     (token.split("=") for token in tokens)}})
    return rows


def _summarize(runs):
    median = statistics.median
    captures = [[row for row in run if row["kind"] == "snapshot_capture"] for run in runs]
    writes = [[row for row in run if row["kind"] == "publisher_write"] for run in runs]
    memories = [run[-1] for run in runs]
    summary = {
        "first_base": {"capture_ns": median(run[0]["capture_ns"] for run in captures),
                       "sparse_clone_ns": median(run[0]["sparse_clone_ns"] for run in captures),
                       **{key: median(run[0][key] for run in captures) for key in COPY_KEYS}},
    }
    repeats = [row for run in captures for row in run[1:]]
    summary["capture"] = None if not repeats else {
        "median_ns": median(row["capture_ns"] for row in repeats),
        "max_ns": max(row["capture_ns"] for row in repeats),
        "median_sparse_clone_ns": median(row["sparse_clone_ns"] for row in repeats),
        "max_layers": max(row["layers"] for row in repeats),
        "per_capture": {key: median(row[key] for row in repeats) for key in COPY_KEYS},
    }
    # The first capture's writes precede the base, so the publisher ignores them.
    later = [[row for row in run if row["capture"] > 0] for run in writes]
    summary["writer"] = {
        "record_total_ns": median(sum(row["record_total_ns"] for row in run) for run in later),
        "max_record_ns": median(max((row["max_record_ns"] for row in run), default=0) for run in later),
        "rollovers": median(sum(row["rollovers"] for row in run) for run in later),
        "rollover_ns": median(sum(row["rollover_ns"] for row in run) for run in later),
        "consolidations": median(sum(row["consolidations"] for row in run) for run in later),
        "consolidation_ns": median(sum(row["consolidation_ns"] for row in run) for run in later),
        "descriptor_copies": median(sum(row["descriptor_copies"] for row in run) for run in later),
        "payload_copy_bytes": median(sum(row["payload_copy_bytes"] for row in run) for run in later),
    }
    summary["memory"] = {key: median(run[key] for run in memories)
                         for key in ["capture_total_ns", "baseline_rss", "held_rss", "closed_rss", "dropped_rss"]}
    summary["memory"]["held_rss_increase"] = median(r["held_rss"] - r["baseline_rss"] for r in memories)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", required=True, help="Engine/harness revision or worktree identifier")
    args = parser.parse_args()
    cells = []
    for mode, delta, leases in CELLS:
        runs = [_parse(subprocess.check_output(
            [str(args.binary.resolve()), "--snapshot-cost", str(delta), str(leases), mode], text=True))
            for _ in range(3)]
        cells.append({"sparse_mode": mode, "delta_points_per_capture": delta, "live_snapshots": leases,
                      "median": _summarize(runs), "runs": runs})
        print(json.dumps({"cell": [mode, delta, leases], **cells[-1]["median"]}), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        "source": args.source,
        "capture_path": "ReadGenerationCache.record/acquire (shared with PersistentCollection; excludes WAL, manifest I/O and writer lock)",
        "dense_copy_audit": "visible rows whose Float32 owner address differs from the writer table's accepted owner",
        "platform": platform.platform(), "points": 4096, "dimension": 128,
        "payload_bytes_per_point": 256, "sparse_elements_per_point": 2,
        "head_max_points": 1024, "head_max_bytes": 4 * 1024 * 1024, "max_sealed_runs": 8,
        "cells": cells}, indent=2) + "\n")


if __name__ == "__main__":
    main()
