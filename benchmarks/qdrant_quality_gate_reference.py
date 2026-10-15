"""Run pinned native Qdrant on the unchanged Mojo quality-gate corpus.

Diagnostic only: this does not waive Akasha's fixed recall or performance gates.
Run under pixi with the pinned qdrant-edge-py 0.8.0 directory on PYTHONPATH.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

import numpy as np
import qdrant_edge as q
from benchmarks.qdrant_workload import SplitMix64

ROOT = Path(__file__).resolve().parents[1]
REVISION = "21db2f3ff95d50de3a2b88a741312c056fd1762d"


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=3)
    args = parser.parse_args()
    if args.trials < 1:
        parser.error("trials must be positive")
    version = importlib.metadata.version("qdrant-edge-py")
    if version != "0.8.0":
        raise RuntimeError("pinned qdrant-edge-py 0.8.0 required")
    args.output.mkdir(parents=True, exist_ok=False)
    rng = SplitMix64(0xD1B54A32D192ED03)
    vectors = rng.vectors(8192, 64)
    queries = rng.vectors(24, 64)
    # Independent F64 truth on exactly the same stored F32 vectors. Native
    # exact Qdrant IDs must also agree before ANN recall is reported.
    expected = [np.argsort(np.sum((vectors.astype(np.float64) - query)**2, axis=1), kind="stable")[:10].tolist()
                for query in queries]
    report = dict(source_revision=REVISION, package_version=version,
        mojo_gate_sha256=hashlib.sha256((ROOT / "tests/mojo/test_hnsw_quality_gate.mojo").read_bytes()).hexdigest(),
        corpus_sha256=hashlib.sha256(vectors.tobytes()+queries.tobytes()).hexdigest(),
        metric="l2", points=8192, dimension=64, queries=24, k=10,
        m=24, ef_construct=192, ef_search=64, minimum_recall=0.95,
        note="Native Qdrant graph levels are not externally seeded; this is a diagnostic, not performance acceptance.",
        trials=[])
    for trial in range(args.trials):
        path = args.output / f"trial-{trial}"
        path.mkdir()
        shard = q.EdgeShard.create(str(path), q.EdgeConfig(
            vectors=q.EdgeVectorParams(64, q.Distance.Euclid), max_search_threads=1,
            hnsw_config=q.HnswIndexConfig(m=24, ef_construct=192, full_scan_threshold=0, max_indexing_threads=1),
            optimizers=q.EdgeOptimizersConfig(default_segment_number=1, indexing_threshold=1, prevent_unoptimized=False),
        ))
        try:
            for start in range(0, len(vectors), 256):
                shard.update(q.UpdateOperation.upsert_points([q.Point(i, vectors[i].tolist())
                    for i in range(start, min(start+256, len(vectors)))]))
            shard.optimize(); shard.flush()
            indexed = shard.info().indexed_vectors_count
            if indexed != len(vectors):
                raise RuntimeError(f"incomplete native HNSW index: {indexed}")
            per_query = []
            for query, truth in zip(queries, expected, strict=True):
                def search(exact):
                    return [hit.id for hit in shard.search(q.SearchRequest(
                        query=q.Query.Nearest(query.tolist()), limit=10,
                        params=q.SearchParams(hnsw_ef=64, exact=exact),
                        with_payload=False, with_vector=False))]
                if search(True) != truth:
                    raise RuntimeError("native exact result differs from independent oracle")
                per_query.append(len(set(search(False)) & set(truth)) / 10)
            recall = sum(per_query) / len(per_query)
            result = dict(trial=trial, indexed=indexed, recall=recall,
                meets_unchanged_gate=recall >= 0.95, per_query=per_query)
            report["trials"].append(result)
            (args.output / "summary.json").write_text(json.dumps(report, indent=2)+"\n")
            print(json.dumps(result), flush=True)
        finally:
            shard.close()


if __name__ == "__main__":
    main()
