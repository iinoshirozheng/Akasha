"""Paired legacy batch ingestion and mixed-workload measurements.

Each worker owns a fresh database or a copy of a closed baseline. Versions run
serially in alternating order. Reuse the evolving independent exact oracle and
lease/maintenance/reopen validation from qdrant_mixed, without remeasuring Qdrant.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
from time import perf_counter_ns

from benchmarks.arrow_scanner import peak_rss, source_hash
from benchmarks.qdrant_compare import Akasha, latency_summary
from benchmarks.qdrant_mixed import measure, prepare, validate_mixed_report
from benchmarks.qdrant_workload import file_sha256, load_workload


def ingest(corpus: Path, directory: Path, output: Path) -> None:
    from akashadb import _kernel

    prior = json.loads((corpus / "report.json").read_text())
    work = load_workload(corpus / "workload.npz")
    db = Akasha(directory, prior["spec"])
    report = {"binary_sha256": file_sha256(Path(_kernel.__file__)), "timings_ns": [],
              "points": len(work.ids), "batch_rows": 256, "workload_sha256": work.checksum()}
    try:
        for start in range(0, len(work.ids), 256):
            begin = perf_counter_ns()
            db.upsert(work.ids[start:start + 256], work.vectors[start:start + 256])
            report["timings_ns"].append(perf_counter_ns() - begin)
        report["total_ns"] = sum(report["timings_ns"])
        report["latency"] = latency_summary(report["timings_ns"])
        report["peak_rss"] = peak_rss()
        # Inspect each batch boundary outside timing.
        for start in range(0, len(work.ids), 256):
            for index in (start, min(start + 255, len(work.ids) - 1)):
                row = db.collection.get(int(work.ids[index]))
                assert row is not None
                assert row.vector == work.vectors[index].tolist()
        report["batch_boundary_rows_validated"] = True
    finally:
        db.close()
    output.write_text(json.dumps(report, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-python", type=Path)
    parser.add_argument("--corpora", nargs="+", type=Path)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--phases", nargs="+", choices=("ingest", "mixed"), default=("ingest", "mixed"))
    parser.add_argument("--worker", choices=("ingest", "mixed"))
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--database", type=Path)
    args = parser.parse_args()
    if args.worker:
        if args.worker == "ingest":
            ingest(args.corpus, args.database, args.output)
        else:
            measure("akasha", args.plan, args.database, args.output)
        return
    if args.output.exists() or not args.baseline_python or not args.corpora or args.trials < 1:
        parser.error("require fresh output, baseline package, corpora, positive trials")
    args.output.mkdir(parents=True)
    report = {"benchmark_sha256": file_sha256(Path(__file__)), "source_sha256": source_hash(),
              "scope": "resident serial public Python bindings; alternate saved before and current after packages; ingest uses fresh 256-point batches; mixed uses 32 blocks (nine reads, eight replacements, flush) with Arrow lease and reopen oracle",
              "phases": list(dict.fromkeys(args.phases)),
              "cache_scope": "OS cache present; no eviction or memory limit",
              "trials": [], "summary": []}
    for corpus in args.corpora:
        work = load_workload(corpus / "workload.npz")
        plan = args.output / f"{corpus.name}-plan.json"
        prepare(corpus, plan)
        plan_values = json.loads(plan.read_text())
        for trial in range(args.trials):
            row = {"corpus": corpus.name, "trial": trial, "versions": {}}
            report["trials"].append(row)
            for version in (("before", "after") if trial % 2 == 0 else ("after", "before")):
                package = args.baseline_python.resolve() if version == "before" else Path("python").resolve()
                env = dict(os.environ, PYTHONPATH=f"{package}:{Path.cwd()}",
                           OPENBLAS_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
                row["versions"][version] = {}
                for phase in report["phases"]:
                    prefix = f"{corpus.name}-{trial}-{version}-{phase}"
                    directory = args.output / prefix
                    if phase == "mixed":
                        shutil.copytree(corpus / "trial-0-akasha/database", directory)
                    output = args.output / (prefix + ".json")
                    subprocess.run([sys.executable, __file__, "--worker", phase, "--corpus", str(corpus),
                                    "--database", str(directory), "--plan", str(plan), "--output", str(output)],
                                   env=env, check=True)
                    measured = json.loads(output.read_text())
                    if phase == "mixed":
                        measured["audited_query_count"] = validate_mixed_report(work, plan_values, measured)
                    row["versions"][version][phase] = measured
                    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                    print(f"{prefix}: PASS", flush=True)
        pairs = [p for p in report["trials"] if p["corpus"] == corpus.name]
        for phase, key in (("ingest", "total_ns"), ("mixed", "write_latency"), ("mixed", "flush_latency"),
                           ("mixed", "write_and_flush_latency"), ("mixed", "open_ns"), ("mixed", "reopen_after_writes_ns")):
            if phase not in report["phases"]:
                continue
            ratios = []
            for pair in pairs:
                before, after = [pair["versions"][v][phase][key] for v in ("before", "after")]
                if isinstance(before, dict):
                    before, after = before["p95_ns"], after["p95_ns"]
                ratios.append(after / before)
            report["summary"].append({"corpus": corpus.name, "phase": phase, "measure": key,
                                      "after_before_ratios": ratios, "median": statistics.median(ratios)})
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
