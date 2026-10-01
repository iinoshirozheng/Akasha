"""Paired exact/ANN service costs on an existing fixed comparison workload.

This diagnostic does not mutate the corpus, change planner policy or establish
Qdrant parity. Run after other builds/tests finish; preserve every recall failure.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
from time import perf_counter_ns

from benchmarks.arrow_scanner import source_hash
from benchmarks.qdrant_compare import Akasha, latency_summary
from benchmarks.qdrant_workload import MODES, exact_ids, file_sha256, load_workload, validate_result


def measure(database_path: Path, workload_path: Path, spec: dict, samples: int) -> dict:
    from akashadb import _kernel

    workload = load_workload(workload_path)
    queries = [[row.tolist() for row in mode] for mode in workload.queries]
    # Compute every oracle before opening/timing either query route.
    oracles = [[exact_ids(workload, query, spec["metric"], spec["k"], mode, ordinal)
                for ordinal, query in enumerate(queries[mode_index])]
               for mode_index, mode in enumerate(MODES)]
    report = {"spec": spec, "source_sha256": source_hash(),
              "benchmark_sha256": file_sha256(Path(__file__)),
              "binary_sha256": file_sha256(Path(_kernel.__file__)),
              "workload_sha256": workload.checksum(), "cells": [],
              "scope": "resident paired public Python exact/ANN request construction and search; alternating order; oracle/stats excluded"}
    database = Akasha(database_path, spec, reopen=True)
    try:
        for mode_index, mode in enumerate(MODES):
            for ef in spec["efs"]:
                cell = {"mode": mode, "ef": ef, "exact_ns": [], "ann_ns": [],
                        "ann_recalls": [], "ann_stats": []}
                for sample in range(samples):
                    for ordinal, query in enumerate(queries[mode_index]):
                        for exact in ((True, False) if (sample + ordinal) % 2 == 0 else (False, True)):
                            start = perf_counter_ns()
                            result = database.search(database.request(query, mode, ordinal, ef, exact=exact))
                            elapsed = perf_counter_ns() - start
                            stats = None if exact else database.stats()
                            ids = [hit.id for hit in result]
                            recall = validate_result(workload, ids, oracles[mode_index][ordinal], mode, ordinal)
                            if exact and recall != 1:
                                raise ValueError(f"exact oracle disagreement: {mode=} {ordinal=} {recall=}")
                            if ordinal < 3:
                                continue
                            cell["exact_ns" if exact else "ann_ns"].append(elapsed)
                            if not exact:
                                cell["ann_recalls"].append(recall)
                                cell["ann_stats"].append(stats)
                cell["exact"] = latency_summary(cell["exact_ns"])
                cell["ann"] = latency_summary(cell["ann_ns"])
                cell["recall"] = statistics.mean(cell["ann_recalls"])
                cell["status"] = "PASSED" if cell["recall"] >= spec["target_recall"] else "FAILED"
                if cell["status"] == "PASSED":
                    cell["exact_over_ann_qps"] = cell["exact"]["qps"] / cell["ann"]["qps"]
                report["cells"].append(cell)
                print(json.dumps({key: cell[key] for key in ("mode", "ef", "recall", "status", "exact", "ann")}), flush=True)
    finally:
        database.close()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--workload", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if args.samples <= 0 or args.output.exists():
        parser.error("require positive samples and a fresh output file")
    spec = json.loads(args.spec.read_text())
    report = measure(args.database, args.workload, spec, args.samples)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
