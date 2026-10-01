"""Candidate/final recall and service cost of bounded binary/MaxSim reranking."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import gzip
import hashlib
import json
from pathlib import Path
from time import perf_counter_ns

import numpy as np

from akashadb import Collection, CollectionConfig, FieldQuery, PayloadField, PointMutation, VectorField, _kernel
from benchmarks.arrow_scanner import peak_rss, source_hash
from benchmarks.qdrant_compare import latency_summary
from benchmarks.qdrant_workload import file_sha256


def measure(directory: Path, kind: str, metric: str, points: int) -> dict:
    rng = np.random.default_rng(931)
    dimension = 64 if kind == "binary" else 31
    ids = np.arange(points) - points // 2
    if kind == "binary":
        rows = rng.integers(0, 2, size=(points, dimension), dtype=np.uint8)
        queries = rng.integers(0, 2, size=(19, dimension), dtype=np.uint8)
        values = [np.packbits(row, bitorder="little").tobytes() for row in rows]
        query_values = [np.packbits(row, bitorder="little").tobytes() for row in queries]
        coarse = rows.astype(np.float32) * 2 - 1
        coarse_queries = queries.astype(np.float32) * 2 - 1
    else:
        rows = rng.normal(size=(points, 4, dimension)).astype(np.float32)
        queries = rng.normal(size=(19, 3, dimension)).astype(np.float32)
        values, query_values = rows.tolist(), queries.tolist()
        coarse, coarse_queries = rows.mean(axis=1), queries.mean(axis=1)
    scores = []
    for query in queries:
        if kind == "binary":
            xor = np.count_nonzero(rows != query, axis=1)
            union = np.count_nonzero(rows | query, axis=1)
            inter = np.count_nonzero(rows & query, axis=1)
            score = xor.astype(float) if metric == "hamming" else 1 - inter / union
        else:
            q, v = query.astype(np.float64), rows.astype(np.float64)
            if metric == "l2":
                score = np.min(np.sum((q[None, :, None, :] - v[:, None, :, :])**2, axis=3), axis=2).sum(axis=1)
            else:
                if metric == "cosine":
                    q /= np.linalg.norm(q, axis=1)[:, None]
                    v /= np.linalg.norm(v, axis=2)[:, :, None]
                score = np.max(np.einsum("qd,ntd->nqt", q, v), axis=2).sum(axis=1)
        scores.append(score)
    ascending = kind == "binary" or metric == "l2"
    spec = {"coarse": VectorField(dimension, metric="dot", hnsw=CollectionConfig.defaults(
                dimension, ann_metric="dot", m=16, m0=32, ef_construction=96, max_ef_search=max(512, points))),
            "final": VectorField(dimension, dtype="binary" if kind == "binary" else "f32", kind=kind, metric=metric)}
    db = Collection(directory, 2, vectors=spec)
    report = {"kind": kind, "metric": metric, "points": points, "dimension": dimension,
              "seed": 931, "data_sha256": hashlib.sha256(rows.tobytes() + queries.tobytes()).hexdigest(), "cells": []}
    try:
        db.apply_point_batch([PointMutation.upsert(int(id), vectors={"coarse": coarse[i].tolist(), "final": values[i]},
                             fields=[PayloadField("keep", "bool", i % 4 == 0)]) for i, id in enumerate(ids)])
        report["before_build_peak_rss_bytes"] = peak_rss()
        start = perf_counter_ns()
        db.search_fields([FieldQuery("coarse", coarse_queries[0].tolist(), mode="approx", ef_search=128)],
                         10, fetch_k=10, rerank=FieldQuery("final", query_values[0]))
        report["first_graph_build_and_query_ns"] = perf_counter_ns() - start
        report["after_build_peak_rss_bytes"] = peak_rss()
        for filtered in (False, True):
            eligible = np.arange(points) % 4 == 0 if filtered else np.ones(points, dtype=bool)
            predicate = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True} if filtered else None
            oracles = [ids[eligible][np.lexsort((ids[eligible], score[eligible] if ascending else -score[eligible]))[:10]].tolist() for score in scores]
            for budget in (10, 32, 128, 512, points):
                cell = {"filtered": filtered, "fetch_k": budget, "latencies_ns": [], "exact_ns": [],
                        "candidate_recalls": [], "final_recalls": [], "stats": []}
                for sample in range(3):
                    for ordinal in range(len(queries)):
                        branches = [FieldQuery("coarse", coarse_queries[ordinal].tolist(), mode="approx", ef_search=max(128, budget))]
                        rerank = FieldQuery("final", query_values[ordinal])
                        # The same candidate request outside timing exposes candidate recall.
                        candidates = db.search_fields(branches, budget, fetch_k=budget, filter=predicate)
                        candidate_ids = {hit.id for hit in candidates}
                        if (sample + ordinal) % 2:
                            start = perf_counter_ns()
                            exact = db.search_field("final", query_values[ordinal], 10, filter=predicate)
                            exact_ns = perf_counter_ns() - start
                        start = perf_counter_ns()
                        actual = db.search_fields(branches, 10, fetch_k=budget, filter=predicate, rerank=rerank)
                        elapsed = perf_counter_ns() - start
                        stats = asdict(db.last_search_stats())
                        if not (sample + ordinal) % 2:
                            start = perf_counter_ns()
                            exact = db.search_field("final", query_values[ordinal], 10, filter=predicate)
                            exact_ns = perf_counter_ns() - start
                        assert [hit.id for hit in exact] == oracles[ordinal]
                        expected_subset = sorted(candidate_ids, key=lambda id: (scores[ordinal][id + points//2] if ascending else -scores[ordinal][id + points//2], id))[:10]
                        assert [hit.id for hit in actual] == expected_subset
                        np.testing.assert_allclose([hit.score for hit in actual], [scores[ordinal][id + points//2] for id in expected_subset], rtol=2e-13)
                        if ordinal >= 3:
                            cell["latencies_ns"].append(elapsed)
                            cell["exact_ns"].append(exact_ns)
                            cell["candidate_recalls"].append(len(candidate_ids & set(oracles[ordinal])) / 10)
                            cell["final_recalls"].append(len(set(expected_subset) & set(oracles[ordinal])) / 10)
                            cell["stats"].append(stats)
                cell["latency"] = latency_summary(cell["latencies_ns"])
                cell["exact_latency"] = latency_summary(cell["exact_ns"])
                cell["candidate_recall"] = float(np.mean(cell["candidate_recalls"]))
                cell["final_recall"] = float(np.mean(cell["final_recalls"]))
                cell["meets_recall_095"] = cell["final_recall"] >= .95
                if cell["meets_recall_095"]:
                    cell["qps_over_exact"] = cell["latency"]["qps"] / cell["exact_latency"]["qps"]
                report["cells"].append(cell)
        report["final_peak_rss_bytes"] = peak_rss()
    finally:
        db.close()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--points", type=int, default=2048)
    args = parser.parse_args()
    if args.output.exists() or args.points < 512:
        parser.error("require a fresh output directory and points >= 512")
    args.output.mkdir(parents=True)
    report = {"binary_sha256": file_sha256(Path(_kernel.__file__)), "source_sha256": source_hash(),
              "benchmark_sha256": file_sha256(Path(__file__)),
              "scope": "resident public Python service, three alternating-order passes, 16 queries after three warmups; candidates/oracles/stats excluded; candidate query warms ANN before timings",
              "memory_scope": "sequential-process peak RSS high-water marks, not independent retained artifact memory",
              "cells": []}
    for kind, metric in [("binary", "hamming"), ("binary", "jaccard"),
                         ("multivector", "dot"), ("multivector", "l2"), ("multivector", "cosine")]:
        result = measure(args.output / f"{kind}-{metric}", kind, metric, args.points)
        report["cells"].append(result)
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"kind": kind, "metric": metric, "build_ns": result["first_graph_build_and_query_ns"],
                          "recalls": [cell["final_recall"] for cell in result["cells"]]}), flush=True)


if __name__ == "__main__":
    main()
