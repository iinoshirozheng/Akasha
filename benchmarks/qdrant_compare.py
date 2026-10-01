"""Matched-recall Python-binding comparison of Akasha and native Qdrant Edge.

Run under pixi with PYTHONPATH=python:.:.build/qdrant-compare/deps. See the dataset
README for pinned downloads. Every trial uses separate sequential processes;
oracle calculation is outside those processes and outside all engine timings.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
from time import perf_counter_ns
import traceback

from benchmarks.arrow_scanner import peak_rss, source_hash
from benchmarks.post_hnsw import nearest_rank
from benchmarks.qdrant_workload import (
    MODES, exact_ids, file_sha256, filter_spec, load_workload, payload,
    real_workload, save_workload, synthetic_workload, validate_result,
)

ROOT = Path(__file__).resolve().parents[1]
QDRANT_VERSION = "0.8.0"
QDRANT_COMMIT = "21db2f3ff95d50de3a2b88a741312c056fd1762d"
PLANNER_POLICY = "dimension-ef-v1"


def execution_kind(engine: str, mode: str, stats: dict, recall: float, spec: dict) -> str:
    """Distinguish deliberate exact plans from a failed ANN execution.

    The old baseline accepted only selective exact fallback. New policy reports
    opt into cost-based exact plans explicitly, and those must match the oracle.
    Unknown/unavailable/exhausted graph fallbacks remain invalid comparisons.
    """
    if engine != "akasha":
        return "unobservable"
    reason = stats.get("fallback_reason", "")
    if not reason:
        return "ann"
    planned = reason in ("selectivity", "filtered_match_count", "small_collection") and mode == "selective"
    planned |= reason == "scan_cost" and spec.get("akasha_planner_policy") == PLANNER_POLICY
    if planned and recall == 1.0 and stats.get("storage_name") == "exact":
        return "planned_exact"
    return "invalid_fallback"


def latency_summary(samples: list[int]) -> dict:
    if not samples or min(samples) <= 0:
        raise ValueError("positive latency samples required")
    return {"samples": len(samples), "qps": len(samples) * 1e9 / sum(samples),
            **{f"p{p}_ns": nearest_rank(samples, p / 100) for p in (50, 95, 99)}}


def latency_parity(akasha: dict, qdrant: dict) -> dict:
    """Apply the strict speed gate after both inputs have passed quality."""
    qps_passed = akasha["qps"] >= qdrant["qps"]
    p95_passed = akasha["p95_ns"] <= qdrant["p95_ns"]
    result = {
        "qps_ratio_akasha_over_qdrant": akasha["qps"] / qdrant["qps"],
        "p95_ratio_akasha_over_qdrant": akasha["p95_ns"] / qdrant["p95_ns"],
        "qps_passed": qps_passed, "p95_passed": p95_passed,
        "status": "PASSED" if qps_passed and p95_passed else "FAILED",
    }
    if result["status"] == "FAILED":
        result["reason"] = "matched recall, but QPS or p95 misses Qdrant; no tolerance"
    return result


def matched_summary(akasha: dict, qdrant: dict, target: float,
                    modes=MODES) -> list[dict]:
    """Match quality by smallest ef, then require both throughput and tail parity."""
    rows = []
    for mode in modes:
        selected = {}
        for engine, report in (("akasha", akasha), ("qdrant", qdrant)):
            eligible = [m for m in report.get("measurements", [])
                        if report.get("status") == "ok" and m["mode"] == mode
                        and report.get("reopen", {}).get("status", "ok") == "ok"
                        and m["recall"] >= target and m["execution_valid"]]
            if eligible:
                cell = min(eligible, key=lambda item: item["ef"])
                selected[engine] = {"ef": cell["ef"], "recall": cell["recall"],
                                    **latency_summary(cell["latency_ns"]),
                                    "execution_counts": cell.get("execution_counts", {})}
        row = {"mode": mode, "target_recall": target, **selected,
               "quality_status": "PASSED" if len(selected) == 2 else "FAILED",
               "status": "PASSED" if len(selected) == 2 else "FAILED"}
        if len(selected) == 2:
            row.update(latency_parity(selected["akasha"], selected["qdrant"]))
        else:
            row["reason"] = "missing, invalid or below-target engine cell; no speed comparison"
        rows.append(row)
    return rows


class Akasha:
    def __init__(self, path: Path, spec: dict, *, reopen=False):
        import akashadb as api
        self.api = api
        self.spec = spec
        config = api.CollectionConfig.defaults(
            spec["dimension"], ann_metric=spec["metric"], scalar_kind=spec["scalar"],
            m=24, m0=48, ef_construction=192, max_level=16,
            default_ef_search=128, max_ef_search=max(512, max(spec["efs"])),
            delta_max_points=spec["points"], rebuild_inactive_percent=90,
            level_seed=spec["seed"],
        )
        self.collection = api.Collection(path, spec["dimension"], config=config)

    def upsert(self, ids, vectors):
        for start in range(0, len(ids), 256):
            batch = [self.api.BatchMutation.upsert(
                int(id), vector.tolist(),
                [self.api.PayloadField(key, "string" if isinstance(value, str) else "int", value)
                 for key, value in payload(int(id), self.spec["seed"]).items()],
            ) for id, vector in zip(ids[start:start + 256], vectors[start:start + 256], strict=True)]
            self.collection.apply_batch(batch)

    def delete(self, ids):
        self.collection.apply_batch([self.api.BatchMutation.delete(int(id)) for id in ids])

    def optimize(self):
        # Public Python flush promotes/builds and persists the HNSW base. There
        # is no benchmark-only kernel seam; the actual base/delta path is reported.
        self.collection.flush()

    def flush(self):
        self.collection.flush()

    def request(self, query, mode, ordinal, ef, *, exact=False):
        condition = filter_spec(mode, ordinal)
        expression = None if condition is None else {
            "kind": "condition", "name": condition[0], "operator": "eq",
            "type": "int", "value": condition[1]}
        return self.api.SearchRequest(
            self.spec["metric"], self.spec["k"], vector=query,
            mode="exact" if exact else "approx", ef_search=ef, filter=expression,
        )

    def search(self, request):
        return self.collection.search(request)

    def stats(self):
        return asdict(self.collection.last_search_stats())

    def info(self):
        return {"config": asdict(self.collection.collection_config())}

    def close(self):
        self.collection.close()


class Qdrant:
    def __init__(self, path: Path, spec: dict, *, reopen=False):
        import qdrant_edge as api
        if importlib.metadata.version("qdrant-edge-py") != QDRANT_VERSION:
            raise ValueError(f"comparison requires qdrant-edge-py=={QDRANT_VERSION}")
        self.api, self.spec, self.path = api, spec, path
        if reopen:
            self.collection = api.EdgeShard.load(str(path))
            return
        distance = {"dot": api.Distance.Dot, "cosine": api.Distance.Cosine,
                    "l2": api.Distance.Euclid}[spec["metric"]]
        config = api.EdgeConfig(
            vectors=api.EdgeVectorParams(size=spec["dimension"], distance=distance, on_disk=False),
            on_disk_payload=False, max_search_threads=1,
            hnsw_config=api.HnswIndexConfig(
                m=24, ef_construct=192,
                # Qdrant expresses this in KiB, Akasha uses eligible fraction
                # (<1/8). Fix an equivalent initial-corpus cutoff before builds.
                full_scan_threshold=max(1, spec["points"] * spec["dimension"] * 4 // (1024 * 8)),
                max_indexing_threads=1,
            ),
            optimizers=api.EdgeOptimizersConfig(
                default_segment_number=1, indexing_threshold=1, prevent_unoptimized=False,
            ),
        )
        path.mkdir(parents=True, exist_ok=False)
        self.collection = api.EdgeShard.create(str(path), config)
        for field in ("correlated", "independent", "rare"):
            self.collection.update(api.UpdateOperation.create_field_index(field, api.PayloadSchemaType.Integer))

    def upsert(self, ids, vectors):
        for start in range(0, len(ids), 256):
            points = [self.api.Point(int(id), vector.tolist(), payload(int(id), self.spec["seed"]))
                      for id, vector in zip(ids[start:start + 256], vectors[start:start + 256], strict=True)]
            self.collection.update(self.api.UpdateOperation.upsert_points(points))

    def delete(self, ids):
        self.collection.update(self.api.UpdateOperation.delete_points([int(id) for id in ids]))

    def optimize(self):
        self.collection.optimize()
        self.collection.flush()
        if self.collection.info().indexed_vectors_count < self.spec["points"]:
            raise ValueError("Qdrant optimization did not build the required HNSW index")

    def flush(self):
        self.collection.flush()

    def request(self, query, mode, ordinal, ef, *, exact=False):
        condition = filter_spec(mode, ordinal)
        expression = None if condition is None else self.api.Filter(must=[
            self.api.FieldCondition(key=condition[0], match=self.api.MatchValue(value=condition[1]))])
        return self.api.SearchRequest(
            query=self.api.Query.Nearest(query), limit=self.spec["k"], filter=expression,
            params=self.api.SearchParams(hnsw_ef=ef, exact=exact), with_payload=False, with_vector=False,
        )

    def search(self, request):
        return self.collection.search(request)

    def stats(self):
        # Edge 0.8 has no public per-query fallback/candidate counters.
        return {"fallback_observability": "unavailable in public Edge API"}

    def info(self):
        info = self.collection.info()
        return {**{key: getattr(info, key) for key in ("points_count", "indexed_vectors_count", "segments_count")},
                "config": json.loads((self.path / "edge_config.json").read_text())}

    def close(self):
        self.collection.close()


def _timed(function, *args):
    started = perf_counter_ns()
    value = function(*args)
    return perf_counter_ns() - started, value


def _timed_query(database, query, mode, ordinal, ef):
    # Both start with the same Python list and scalar filter/ef values. Qdrant's
    # Query constructor crosses into Rust; excluding it would undercount its
    # binding cost relative to Akasha's Python dataclass request.
    started = perf_counter_ns()
    request = database.request(query, mode, ordinal, ef)
    values = database.search(request)
    return perf_counter_ns() - started, values


def measure(engine: str, spec: dict, directory: Path, workload_path: Path,
            oracle_path: Path, *, reopen=False) -> dict:
    workload = load_workload(workload_path)
    oracles = json.loads(oracle_path.read_text())
    if oracles["checksum"] != workload.checksum():
        raise ValueError("oracle belongs to different input data")
    report = {"engine": engine, "spec": spec, "workload_sha256": workload.checksum(),
              "status": "running", "measurements": [], "phase": "reopen" if reopen else "build-query",
              "input_peak_rss_bytes": peak_rss()}
    if not reopen and directory.exists():
        raise ValueError("fresh trial requires an unused database path")
    factory = Akasha if engine == "akasha" else Qdrant
    started = perf_counter_ns()
    database = factory(directory, spec, reopen=reopen)
    report["open_ns"] = perf_counter_ns() - started
    if engine == "akasha":
        from akashadb import _kernel
        binary = Path(_kernel.__file__)
    else:
        from qdrant_edge import qdrant_edge
        binary = Path(qdrant_edge.__file__)
    report["native_binary_sha256"] = file_sha256(binary)
    try:
        if not reopen:
            report["ingest_ns"], _ = _timed(database.upsert, workload.ids, workload.vectors)
            report["build_checkpoint_ns"], _ = _timed(database.optimize)
            report["built_info"] = database.info()
            report["replace_ns"], _ = _timed(database.upsert, workload.update_ids, workload.updates)
            report["delete_ns"], _ = _timed(database.delete, workload.deletes)
            report["mutation_flush_ns"], _ = _timed(database.flush)
        report["ready_info"] = database.info()
        report["ready_peak_rss_bytes"] = peak_rss()
        # Fresh process/open first query; OS cache is explicitly NOT evicted.
        elapsed, values = _timed_query(database, workload.queries[0, 0].tolist(), "all", 0, max(spec["efs"]))
        ids = [int(value.id) for value in values]
        report["first_query"] = {"latency_ns": elapsed, "ids": ids,
                                 "recall": validate_result(workload, ids, oracles["ids"][0][0], "all", 0),
                                 "stats": database.stats()}
        if not reopen:
            for mode_index, mode in enumerate(MODES):
                # Both exact APIs must agree with the independent oracle before
                # accepting approximate timing. IDs, count and filtering checked.
                for ordinal, vector in enumerate(workload.queries[mode_index]):
                    request = database.request(vector.tolist(), mode, ordinal, 128, exact=True)
                    ids = [int(value.id) for value in database.search(request)]
                    recall = validate_result(workload, ids, oracles["ids"][mode_index][ordinal], mode, ordinal)
                    if recall != 1:
                        raise ValueError(f"exact oracle disagreement: {mode=} {ordinal=} {recall=}")
                for ef in spec["efs"]:
                    cell = {"mode": mode, "ef": ef, "latency_ns": [], "queries": [],
                            "execution_valid": True, "execution_counts": {}}
                    for ordinal, vector in enumerate(workload.queries[mode_index]):
                        elapsed, values = _timed_query(database, vector.tolist(), mode, ordinal, ef)
                        ids = [int(value.id) for value in values]
                        stats = database.stats()
                        recall = validate_result(workload, ids, oracles["ids"][mode_index][ordinal], mode, ordinal)
                        if ordinal < 3:
                            continue
                        execution = execution_kind(engine, mode, stats, recall, spec)
                        if execution == "invalid_fallback":
                            cell["execution_valid"] = False
                        cell["execution_counts"][execution] = cell["execution_counts"].get(execution, 0) + 1
                        cell["latency_ns"].append(elapsed)
                        cell["queries"].append({"ordinal": ordinal, "ids": ids, "recall": recall, "stats": stats})
                    cell["recall"] = statistics.mean(row["recall"] for row in cell["queries"])
                    cell["status"] = ("PASSED" if cell["execution_valid"]
                                      and cell["recall"] >= spec["target_recall"] else "FAILED")
                    cell.update(latency_summary(cell["latency_ns"]))
                    report["measurements"].append(cell)
        report["final_peak_rss_bytes"] = peak_rss()
        report["disk_bytes"] = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())
        report["status"] = "ok"
    finally:
        database.close()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--points", type=int, default=8192)
    parser.add_argument("--dimension", type=int, default=128)
    parser.add_argument("--queries", type=int, default=64)
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--metric", choices=("dot", "l2", "cosine"), default="dot")
    parser.add_argument("--scalar", choices=("f32", "f16", "bf16", "i8"), default="f32")
    parser.add_argument("--real-parquet", type=Path)
    parser.add_argument("--efs", default="32,64,128,256,512,1024")
    parser.add_argument("--target-recall", type=float, default=.95)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--engine", choices=("akasha", "qdrant", "both"), default="both")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--reopen", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        spec = json.loads((args.worker / "spec.json").read_text())
        try:
            report = measure(args.engine, spec, args.output.parent / "database",
                             args.worker / "workload.npz", args.worker / "oracle.json", reopen=args.reopen)
        except Exception:
            report = {"status": "FAILED", "engine": args.engine, "spec": spec, "error": traceback.format_exc()}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"engine": args.engine, "status": report["status"], "output": str(args.output)}), flush=True)
        if report["status"] != "ok":
            print(report["error"], file=sys.stderr)
            raise SystemExit(1)
        return
    try:
        efs = sorted(set(map(int, args.efs.split(","))))
    except ValueError:
        parser.error("efs must be comma-separated integers")
    if not efs or min(efs) < 10 or args.trials < 1 or not 0 < args.target_recall <= 1:
        parser.error("require ef >= 10, trials >= 1, target-recall in (0, 1]")
    if args.scalar != "f32" and args.engine != "akasha":
        parser.error("non-F32 graphs are separate Akasha diagnostics; paired baseline uses F32")
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("output directory must be empty; use a fresh path to repeat a failed cell")
    workload = (real_workload(args.real_parquet, args.points, args.queries, args.seed)
                if args.real_parquet else synthetic_workload(args.points, args.dimension, args.queries, args.seed))
    spec = {"points": args.points, "dimension": workload.vectors.shape[1], "queries": args.queries,
            "seed": args.seed, "metric": args.metric, "scalar": args.scalar, "k": 10, "efs": efs,
            "target_recall": args.target_recall, "search_threads": 1, "index_threads": 1,
            "qdrant_full_scan_threshold_kib": max(1, args.points * workload.vectors.shape[1] * 4 // (1024 * 8)),
            "query_concurrency": 1, "update_percent": 10, "warm_read_write_mix": "100% reads after replacements/deletes",
            "akasha_planner_policy": PLANNER_POLICY}
    save_workload(args.output / "workload.npz", workload)
    (args.output / "spec.json").write_text(json.dumps(spec, indent=2) + "\n")
    print("Calculating independent exact oracle", flush=True)
    oracle = {"checksum": workload.checksum(), "metric": args.metric, "k": 10,
              "ids": [[exact_ids(workload, vector, args.metric, 10, mode, ordinal)
                       for ordinal, vector in enumerate(workload.queries[index])]
                      for index, mode in enumerate(MODES)]}
    (args.output / "oracle.json").write_text(json.dumps(oracle) + "\n")
    report = {
        "started_utc": datetime.now(timezone.utc).isoformat(), "spec": spec,
        "source_sha256": source_hash(), "git_head": subprocess.check_output(
            ["git", "-c", "core.fsmonitor=false", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "benchmark_sha256": {name: file_sha256(ROOT / "benchmarks" / name)
                             for name in ("qdrant_compare.py", "qdrant_workload.py")},
        "lockfile_sha256": file_sha256(ROOT / "pixi.lock"),
        "mojo": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "qdrant_version": QDRANT_VERSION, "qdrant_commit": QDRANT_COMMIT,
        "recorded_macos_arm64_wheel_sha256": "d84d0702a31b6560c84f4d28b3272f94f1df354c04b80167e73acc08cc134642",
        "qdrant_release_run": "https://github.com/qdrant/qdrant/actions/runs/31007802524",
        "host": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
        "python": sys.version, "memory_limit": "no imposed process limit; process peak RSS reported",
        "workload": workload.metadata, "workload_sha256": workload.checksum(),
        "timing_scope": "Python list/filter/ef -> typed request construction -> public Python binding -> returned result objects; shared NumPy-to-list conversion, result validation and stats excluded",
        "cold_scope": "new process loads persisted database, first query; OS page cache NOT evicted",
        "qps_scope": "reciprocal mean single-request service time, not concurrent server throughput",
        "limitations": ["Edge public API does not expose query candidate/fallback counters",
                        "Qdrant graph build has no exposed seed; repeated fresh trials record variability",
                        "fixed F32 baseline; not final M6 concurrent maintenance/non-resident/type matrix"],
        "trials": [],
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    engines = ["akasha", "qdrant"] if args.engine == "both" else [args.engine]
    env = dict(os.environ, OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
    for trial in range(args.trials):
        outputs = {}
        commands = []
        for engine in (engines if trial % 2 == 0 else list(reversed(engines))):
            directory = args.output / f"trial-{trial}-{engine}"
            directory.mkdir()
            for phase in ("build", "reopen"):
                output = directory / f"{phase}.json"
                command = [sys.executable, str(Path(__file__).resolve()), "--worker", str(args.output.resolve()),
                           "--engine", engine, "--output", str(output.resolve())]
                if phase == "reopen":
                    command.append("--reopen")
                commands.append(command)
                result = subprocess.run(command, cwd=ROOT, env=env)
                if output.exists():
                    value = json.loads(output.read_text())
                else:
                    value = {"engine": engine, "status": "FAILED", "returncode": result.returncode,
                             "error": "worker exited without a result artifact"}
                if phase == "build":
                    outputs[engine] = value
                else:
                    outputs[engine]["reopen"] = value
                if result.returncode:
                    break
        trial_report = {"trial": trial, "commands": commands, "engines": outputs,
                        "matched": matched_summary(outputs.get("akasha", {}), outputs.get("qdrant", {}), args.target_recall)}
        report["trials"].append(trial_report)
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"trial": trial, "matched": trial_report["matched"]}), flush=True)
    if any(row["status"] != "PASSED" for trial in report["trials"] for row in trial["matched"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
