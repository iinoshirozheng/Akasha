"""Serial 90/10 read/write binding workload with flush and retained Arrow leases.

Clone closed baseline databases. Compute every evolving-state oracle before
running either engine. This is resident interleaving, not concurrent client load
or a claim that the two engines perform identical maintenance algorithms.
"""

from __future__ import annotations

import argparse
import gc
import json
import os
from pathlib import Path
import shutil
import stat
import statistics
import subprocess
import sys
from time import perf_counter_ns

from benchmarks.arrow_scanner import peak_rss, source_hash
from benchmarks.qdrant_compare import Akasha, Qdrant, execution_kind, latency_parity, latency_summary
from benchmarks.qdrant_workload import MODES, exact_ids, file_sha256, load_workload, validate_result


def inventory(path: Path) -> dict:
    # Maintenance can retire a segment between directory enumeration and stat.
    # An active inventory is a best-effort observation, not an atomic disk view.
    files, vanished, total = [], [], 0
    for item in sorted(path.rglob("*")):
        name = str(item.relative_to(path))
        try:
            info = item.stat()
        except FileNotFoundError:
            vanished.append(name)
            continue
        if stat.S_ISREG(info.st_mode):
            files.append(name)
            total += info.st_size
    return {"bytes": total, "files": files, "vanished_during_inventory": vanished}


def validate_mixed_report(workload, plan: dict, measured: dict) -> int:
    """Audit membership/filters/counts after the worker stops, outside timing."""
    queries = [query for block in plan["blocks"] for query in block["queries"]]
    for query, result in zip(queries, measured["queries"], strict=True):
        assert result["mode"] == query["mode"]
        assert result["oracle"] == query["oracle"]
        recall = validate_result(workload, result["ids"], query["oracle"], query["mode"], query["ordinal"])
        assert recall == result["recall"]
    return len(queries)


def prepare(corpus: Path, output: Path) -> None:
    source = json.loads((corpus / "report.json").read_text())
    spec = source["spec"]
    work = load_workload(corpus / "workload.npz")
    plan = {"spec": spec, "initial_workload_sha256": work.checksum(), "blocks": [],
            "efs": {engine: {cell["mode"]: cell[engine]["ef"] for cell in source["trials"][0]["matched"]}
                    for engine in ("akasha", "qdrant")}}
    for block in range(32):
        item = {"queries": []}
        for query in range(9):
            index = block * 9 + query
            mode_index = index % 4
            ordinal = (index // 4) % spec["queries"] + 3
            mode = MODES[mode_index]
            values = work.queries[mode_index, ordinal].tolist()
            truth = exact_ids(work, values, spec["metric"], spec["k"], mode, ordinal)
            item["queries"].append({"mode": mode, "ordinal": ordinal, "vector": values, "oracle": truth})
        # Restore eight previously replaced rows to their distinct initial vectors.
        start = block * 8
        item["ids"] = work.update_ids[start:start+8].tolist()
        item["vectors"] = work.vectors[start:start+8].tolist()
        work.updates[start:start+8] = work.vectors[start:start+8]
        plan["blocks"].append(item)
    query = plan["blocks"][-1]["queries"][-1]
    plan["final_query"] = {**query, "oracle": exact_ids(work, query["vector"], spec["metric"], spec["k"], query["mode"], query["ordinal"])}
    output.write_text(json.dumps(plan) + "\n")


def measure(engine: str, plan_path: Path, directory: Path, output: Path) -> None:
    import numpy as np

    plan = json.loads(plan_path.read_text())
    spec, efs = plan["spec"], plan["efs"][engine]
    factory = Akasha if engine == "akasha" else Qdrant
    start = perf_counter_ns()
    db = factory(directory, spec, reopen=True)
    report = {"engine": engine, "open_ns": perf_counter_ns()-start,
              "plan_sha256": file_sha256(plan_path), "queries": [], "writes": [], "flushes": [],
              "initial_info": db.info(), "initial_inventory": inventory(directory), "initial_peak_rss": peak_rss()}
    if engine == "akasha":
        from akashadb import _kernel
        from akashadb.arrow import scan_record_batches
        binary = Path(_kernel.__file__)
        scanner = scan_record_batches(db.collection, columns=("id", "vector"), batch_size=1)
        lease = next(scanner)
        retained_value = lease.to_pydict()
        scanner.close()
        del scanner
    else:
        from qdrant_edge import qdrant_edge
        binary = Path(qdrant_edge.__file__)
        lease = None
    report["native_binary_sha256"] = file_sha256(binary)
    try:
        for query in plan["blocks"][0]["queries"][:3]:
            db.search(db.request(query["vector"], query["mode"], query["ordinal"], efs[query["mode"]]))
        for index, block in enumerate(plan["blocks"]):
            for query in block["queries"]:
                start = perf_counter_ns()
                hits = db.search(db.request(query["vector"], query["mode"], query["ordinal"], efs[query["mode"]]))
                elapsed = perf_counter_ns()-start
                actual = [hit.id for hit in hits]
                stats = db.stats()
                recall = len(set(actual) & set(query["oracle"])) / len(query["oracle"])
                report["queries"].append({"block": index, "mode": query["mode"], "latency_ns": elapsed,
                                          "recall": recall, "ids": actual, "oracle": query["oracle"], "stats": stats,
                                          "execution": execution_kind(engine, query["mode"], stats, recall, spec)})
            ids = np.array(block["ids"], dtype=np.int64)
            values = np.array(block["vectors"], dtype=np.float32)
            start = perf_counter_ns()
            db.upsert(ids, values)
            report["writes"].append(perf_counter_ns()-start)
            start = perf_counter_ns()
            db.flush()
            report["flushes"].append(perf_counter_ns()-start)
        report["final_info"] = db.info()
        report["before_close_inventory"] = inventory(directory)
        report["final_peak_rss"] = peak_rss()
    except BaseException as error:
        report["failure"] = repr(error)
        output.write_text(json.dumps(report, indent=2) + "\n")
        raise
    finally:
        db.close()
    if lease is not None:
        assert lease.to_pydict() == retained_value
        report["lease_survived_close"] = True
        report["after_close_with_lease_inventory"] = inventory(directory)
        del lease
        gc.collect()
        report["after_lease_release_inventory"] = inventory(directory)
    start = perf_counter_ns()
    db = factory(directory, spec, reopen=True)
    report["reopen_after_writes_ns"] = perf_counter_ns()-start
    try:
        query = plan["final_query"]
        hits = db.search(db.request(query["vector"], query["mode"], query["ordinal"], efs[query["mode"]], exact=True))
        assert [hit.id for hit in hits] == query["oracle"]
        report["reopen_exact_oracle_match"] = True
    finally:
        db.close()
    report["modes"] = []
    for mode in MODES:
        cells = [cell for cell in report["queries"] if cell["mode"] == mode]
        report["modes"].append({"mode": mode, "recall": statistics.mean(cell["recall"] for cell in cells),
                                 "execution_valid": all(cell["execution"] != "invalid_fallback" for cell in cells),
                                 **latency_summary([cell["latency_ns"] for cell in cells])})
    report["write_latency"] = latency_summary(report["writes"])
    report["flush_latency"] = latency_summary(report["flushes"])
    report["write_and_flush_latency"] = latency_summary([
        write + flush for write, flush in zip(report["writes"], report["flushes"], strict=True)
    ])
    report["durability_scope"] = (
        "Akasha batch acceptance includes WAL fsync; Qdrant Edge update applies the WAL operation, "
        "with WAL/segments synchronized by its separate flush. Individual update calls are not "
        "durability-equivalent. The combined latency sums each block's own update and flush; "
        "the engines may perform different maintenance work."
    )
    output.write_text(json.dumps(report, indent=2) + "\n")


def matched_mixed_summary(akasha: dict, qdrant: dict) -> list[dict]:
    """Require quality and both speed gates for every fixed workload mode."""
    rows = []
    for mode in MODES:
        left = next((cell for cell in akasha["modes"] if cell["mode"] == mode), None)
        right = next((cell for cell in qdrant["modes"] if cell["mode"] == mode), None)
        valid = (left is not None and right is not None
                 and min(left["recall"], right["recall"]) >= .95
                 and left["execution_valid"] and right["execution_valid"])
        cell = {"mode": mode, "akasha": left, "qdrant": right,
                "quality_status": "PASSED" if valid else "FAILED", "status": "FAILED"}
        if valid:
            cell.update(latency_parity(left, right))
        else:
            cell["reason"] = "missing, invalid or below-target engine cell; no speed comparison"
        rows.append(cell)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--worker", choices=("akasha", "qdrant"))
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--corpora", nargs="+", type=Path)
    args = parser.parse_args()
    if args.worker:
        measure(args.worker, args.plan, args.database, args.output)
        return
    if args.output.exists() or not args.corpora:
        parser.error("require fresh output and baseline corpus directories")
    args.output.mkdir(parents=True)
    report = {"source_sha256": source_hash(), "benchmark_sha256": file_sha256(Path(__file__)),
              "scope": "resident serial bindings, nine reads then one eight-point upsert batch, then flush; 32 blocks; 90/10 read/write operation ratio excluding flush; three alternating engine-order trials",
              "concurrency": "one foreground caller, engine background workers as configured; no explicit optimizer invocation",
              "cache_scope": "fresh processes with OS cache present; no cache eviction or memory limit",
              "lease_scope": "Akasha retains a one-row Arrow batch/root through all writes and close; Qdrant has no corresponding Arrow API",
              "trials": []}
    for corpus in args.corpora:
        plan = args.output / f"{corpus.name}-plan.json"
        prepare(corpus, plan)
        work = load_workload(corpus / "workload.npz")
        plan_values = json.loads(plan.read_text())
        for trial in range(3):
            row = {"corpus": corpus.name, "trial": trial, "engines": {}}
            for engine in (("akasha", "qdrant") if trial % 2 == 0 else ("qdrant", "akasha")):
                directory = args.output / f"{corpus.name}-{trial}-{engine}"
                shutil.copytree(corpus / f"trial-0-{engine}/database", directory)
                output = args.output / f"{corpus.name}-{trial}-{engine}.json"
                subprocess.run([sys.executable, __file__, "--worker", engine, "--plan", str(plan),
                                "--database", str(directory), "--output", str(output)], check=True)
                row["engines"][engine] = json.loads(output.read_text())
                row["engines"][engine]["audited_query_count"] = validate_mixed_report(work, plan_values, row["engines"][engine])
            row["matched"] = matched_mixed_summary(row["engines"]["akasha"], row["engines"]["qdrant"])
            report["trials"].append(row)
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"corpus": corpus.name, "trial": trial, "matched": row["matched"]}), flush=True)
    if any(cell["status"] != "PASSED" for trial in report["trials"] for cell in trial["matched"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
