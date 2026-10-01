"""Native IVF build/probe/recall diagnostic; run without competing builds/tests."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import platform
from time import perf_counter_ns

import numpy as np

from akashadb import Collection, IvfOptions, PayloadField, PointMutation, VectorField, _kernel
from benchmarks.arrow_scanner import peak_rss, source_hash
from benchmarks.qdrant_compare import latency_summary
from benchmarks.qdrant_workload import file_sha256


def measure(path: Path, dtype: str, metric: str, points: int, dimension: int) -> dict:
    rng = np.random.default_rng(718)
    # Small exact integers also have lossless native BF16/F16 representations.
    low = 1 if dtype == "u8" else -12
    data = rng.integers(low, 24, size=(points, dimension))
    queries = rng.integers(low, 24, size=(35, dimension))
    ids = np.arange(points, dtype=np.int64) - points // 2
    truth = {}
    for filtered in (False, True):
        mask = np.arange(points) % 4 == 0 if filtered else np.ones(points, dtype=bool)
        rows = data[mask].astype(np.float64)
        for ordinal, query in enumerate(queries):
            q = query.astype(np.float64)
            scores = ((rows @ q) if metric == "dot" else
                      np.sum((rows-q)**2, axis=1) if metric == "l2" else
                      (rows @ q) / (np.linalg.norm(rows, axis=1) * np.linalg.norm(q)))
            order = np.lexsort((ids[mask], scores if metric == "l2" else -scores))[:10]
            truth[filtered, ordinal] = (ids[mask][order].tolist(), scores[order].tolist())
    digest = hashlib.sha256(data.tobytes() + queries.tobytes()).hexdigest()
    record = {"dtype": dtype, "metric": metric, "points": points,
              "dimension": dimension, "k": 10, "nlist": 32, "iterations": 8,
              "seed": 718, "data_sha256": digest, "cells": []}
    with_collection = Collection(path, 2, vectors={"x": VectorField(dimension, dtype=dtype, metric=metric)})
    try:
        with_collection.apply_point_batch([
            PointMutation.upsert(int(id), vectors={"x": row.tolist()},
                                 fields=[PayloadField("group", "int", i % 4)])
            for i, (id, row) in enumerate(zip(ids, data, strict=True))])
        record["before_build_peak_rss_bytes"] = peak_rss()
        start = perf_counter_ns()
        with_collection.search_field("x", queries[0].tolist(), 10, mode="ivf", ivf=IvfOptions())
        record["first_build_and_query_ns"] = perf_counter_ns() - start
        record["after_build_peak_rss_bytes"] = peak_rss()
        for filtered in (False, True):
            predicate = {"kind": "condition", "name": "group", "operator": "eq",
                         "type": "int", "value": 0} if filtered else None
            for probes in (1, 2, 4, 8, 16, 32):
                options = IvfOptions(nprobe=probes)
                cell = {"filtered": filtered, "nprobe": probes, "timings_ns": [],
                        "recalls": [], "stats": []}
                for sample in range(3):
                    for ordinal, query in enumerate(queries):
                        values = query.tolist()
                        start = perf_counter_ns()
                        hits = with_collection.search_field("x", values, 10, mode="ivf", ivf=options, filter=predicate)
                        elapsed = perf_counter_ns() - start
                        expected, expected_scores = truth[filtered, ordinal]
                        actual = [hit.id for hit in hits]
                        recall = len(set(actual) & set(expected)) / len(expected)
                        if probes == 32:
                            assert actual == expected, (dtype, metric, filtered, ordinal)
                            np.testing.assert_allclose([hit.score for hit in hits], expected_scores, rtol=2e-14)
                        if ordinal >= 3:
                            cell["timings_ns"].append(elapsed)
                            cell["recalls"].append(recall)
                            cell["stats"].append(asdict(with_collection.last_search_stats()))
                cell["latency"] = latency_summary(cell["timings_ns"])
                cell["mean_recall"] = float(np.mean(cell["recalls"]))
                record["cells"].append(cell)
        record["final_peak_rss_bytes"] = peak_rss()
    finally:
        with_collection.close()
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--points", type=int, default=2048)
    parser.add_argument("--dimension", type=int, default=64)
    args = parser.parse_args()
    if args.output.exists() or args.points < 32 or args.dimension <= 0:
        parser.error("require a fresh output directory, points >= 32 and positive dimension")
    args.output.mkdir(parents=True)
    report = {"source_sha256": source_hash(), "binary_sha256": file_sha256(Path(_kernel.__file__)),
              "benchmark_sha256": file_sha256(Path(__file__)), "host": platform.platform(),
              "scope": "resident public Python IVF service; stats/oracle outside timing; three passes of 32 queries after three warmups",
              "memory_scope": "process peak RSS high-water marks, includes inputs and training; not retained artifact allocation or independent per-cell RSS",
              "cells": []}
    for dtype in ("f32", "f16", "bf16", "i8", "u8"):
        for metric in ("dot", "l2", "cosine"):
            result = measure(args.output / f"{dtype}-{metric}", dtype, metric, args.points, args.dimension)
            report["cells"].append(result)
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"dtype": dtype, "metric": metric,
                              "build_ns": result["first_build_and_query_ns"],
                              "unfiltered_recall": [cell["mean_recall"] for cell in result["cells"][:6]]}), flush=True)


if __name__ == "__main__":
    main()
