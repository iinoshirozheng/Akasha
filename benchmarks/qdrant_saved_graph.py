"""Replay a saved acceptance graph to isolate query implementation changes.

Run separate processes serially with the before/after native libraries. This
diagnostic preserves graph bytes, queries and ef; it is not fresh-build or
Qdrant performance acceptance. The normal qdrant_compare runner owns those gates.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
from time import perf_counter_ns

from benchmarks.qdrant_compare import Akasha, MODES, latency_summary, load_workload, validate_result


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=7)
    args = parser.parse_args()
    if args.repeats < 1 or args.output.exists():
        parser.error("positive repeats and unused output path required")

    # Select one native library before Collection's lazy import; the installed
    # package and database files are never replaced to switch implementations.
    import akashadb
    kernel = args.kernel.resolve()
    module_spec = importlib.util.spec_from_file_location("akashadb._kernel", kernel)
    if module_spec is None or module_spec.loader is None:
        raise ValueError("native kernel could not be loaded")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    sys.modules["akashadb._kernel"] = module
    akashadb._kernel = module

    root = args.corpus.resolve()
    spec = json.loads((root / "spec.json").read_text())
    baseline = json.loads((root / "trial-0-akasha/build.json").read_text())
    workload = load_workload(root / "workload.npz")
    oracles = json.loads((root / "oracle.json").read_text())
    if workload.checksum() != oracles["checksum"]:
        raise ValueError("workload does not match saved oracle")
    database = Akasha(root / "trial-0-akasha/database", spec, reopen=True)
    cells = []
    try:
        for mode_index, mode in enumerate(MODES):
            ef = min(c["ef"] for c in baseline["measurements"]
                     if c["mode"] == mode and c["status"] == "PASSED")
            queries = [v.tolist() for v in workload.queries[mode_index]]
            for ordinal, query in enumerate(queries):
                database.search(database.request(query, mode, ordinal, ef))
            latencies, recalls, stats = [], [], []
            digest = hashlib.sha256()
            for repeat in range(args.repeats):
                for ordinal, query in enumerate(queries):
                    started = perf_counter_ns()
                    hits = database.search(database.request(query, mode, ordinal, ef))
                    latencies.append(perf_counter_ns() - started)
                    ids = [int(hit.id) for hit in hits]
                    digest.update(repr([(hit.id, hit.score) for hit in hits]).encode())
                    if repeat == 0:
                        recalls.append(validate_result(workload, ids, oracles["ids"][mode_index][ordinal], mode, ordinal))
                        stats.append(database.stats())
            cells.append(dict(mode=mode, ef=ef, latency_ns=latencies,
                              result_sha256=digest.hexdigest(), recalls=recalls,
                              stats=stats, **latency_summary(latencies)))
    finally:
        database.close()
    report = dict(scope="saved-graph query diagnostic; not Qdrant acceptance",
                  corpus=str(root), kernel_sha256=hashlib.sha256(kernel.read_bytes()).hexdigest(),
                  workload_sha256=workload.checksum(), repeats=args.repeats, cells=cells)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print([(c["mode"], c["qps"]) for c in cells])


if __name__ == "__main__":
    main()
