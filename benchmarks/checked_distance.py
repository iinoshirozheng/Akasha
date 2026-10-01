"""Alternate pinned before/after extensions on unchanged resident databases."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
from time import perf_counter_ns

from benchmarks.qdrant_compare import Akasha, latency_summary
from benchmarks.qdrant_workload import MODES, file_sha256, load_workload


def worker(report_dir: Path, output: Path) -> None:
    from akashadb import _kernel

    prior = json.loads((report_dir / "report.json").read_text())
    workload = load_workload(report_dir / "workload.npz")
    fixed = {cell["mode"]: cell["akasha"]["ef"] for cell in prior["trials"][0]["matched"]}
    report = {"binary_sha256": file_sha256(Path(_kernel.__file__)),
              "workload_sha256": workload.checksum(), "selected_efs": fixed, "cells": []}
    db = Akasha(report_dir / "trial-0-akasha/database", prior["spec"], reopen=True)
    try:
        for mode_index, mode in enumerate(MODES):
            for exact in (True, False):
                cell = {"mode": mode, "exact": exact, "timings_ns": [], "stats": [], "results": []}
                for ordinal, row in enumerate(workload.queries[mode_index]):
                    query = row.tolist()
                    start = perf_counter_ns()
                    result = db.search(db.request(query, mode, ordinal, fixed[mode], exact=exact))
                    elapsed = perf_counter_ns() - start
                    if ordinal >= 3:
                        cell["timings_ns"].append(elapsed)
                        cell["results"].append([(hit.id, hit.score) for hit in result])
                        cell["stats"].append(db.stats())
                cell["latency"] = latency_summary(cell["timings_ns"])
                cell["results_sha256"] = hashlib.sha256(json.dumps(cell["results"]).encode()).hexdigest()
                report["cells"].append(cell)
    finally:
        db.close()
    output.write_text(json.dumps(report, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-python", type=Path)
    parser.add_argument("--report-dirs", nargs="+", type=Path)
    args = parser.parse_args()
    if args.worker:
        worker(args.worker, args.output)
        return
    if args.output.exists() or not args.baseline_python or not args.report_dirs:
        parser.error("require fresh output, baseline package directory and prior reports")
    args.output.mkdir(parents=True)
    report = {"benchmark_sha256": file_sha256(Path(__file__)),
              "scope": "same fixed database, resident serial public Python requests; three alternating before/after processes; no Qdrant remeasurement",
              "baseline": "extension saved immediately before the checked SIMD change, including IVF and planner; both builds explicitly target apple-m4/metal:4",
              "trials": [], "summary": []}
    for corpus in args.report_dirs:
        for trial in range(3):
            pair = {"corpus": corpus.name, "trial": trial, "engines": {}}
            for version in (("before", "after") if trial % 2 == 0 else ("after", "before")):
                package = args.baseline_python.resolve() if version == "before" else Path("python").resolve()
                env = dict(os.environ, PYTHONPATH=f"{package}:{Path.cwd()}",
                           OPENBLAS_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
                output = args.output / f"{corpus.name}-{trial}-{version}.json"
                subprocess.run([sys.executable, __file__, "--worker", str(corpus), "--output", str(output)], env=env, check=True)
                pair["engines"][version] = json.loads(output.read_text())
            for before, after in zip(pair["engines"]["before"]["cells"], pair["engines"]["after"]["cells"], strict=True):
                assert before["results_sha256"] == after["results_sha256"], (corpus, trial, before["mode"])
            report["trials"].append(pair)
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{corpus.name}: pair {trial + 1} identical scores/IDs", flush=True)
        for ordinal in range(8):
            ratios = [p["engines"]["after"]["cells"][ordinal]["latency"]["qps"] /
                      p["engines"]["before"]["cells"][ordinal]["latency"]["qps"]
                      for p in report["trials"] if p["corpus"] == corpus.name]
            cell = pair["engines"]["after"]["cells"][ordinal]
            report["summary"].append({"corpus": corpus.name, "mode": cell["mode"], "exact": cell["exact"],
                                      "qps_ratios": ratios, "median": statistics.median(ratios)})
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
