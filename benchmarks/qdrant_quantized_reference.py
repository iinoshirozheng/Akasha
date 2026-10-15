"""Compare native Qdrant quantized scores with Akasha SQ8/PQ indexes.

Uses a built scalar-quantized segment, forces quantized plain scan, disables
authoritative rescoring, and requests every candidate. Exact results separately
detect an accidentally unquantized reference path. No speed gates are changed.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import subprocess
import struct

import qdrant_edge as q

ROOT=Path(__file__).resolve().parents[1]
REVISION="21db2f3ff95d50de3a2b88a741312c056fd1762d"


def main():
    parser=argparse.ArgumentParser(__doc__)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--codec",choices=("sq8","pq"),default="sq8")
    args=parser.parse_args()
    if importlib.metadata.version("qdrant-edge-py") != "0.8.0":
        raise RuntimeError("pinned native Edge 0.8.0 required")
    args.output.mkdir(parents=True,exist_ok=False)
    fixtures=[]
    populations = ([(3,None),(16,None),(19,None),(3,0.0),(3,2.0)]
                   if args.codec == "sq8" else [(8,None),(16,None)])
    for dimension,constant in populations:
        for metric,distance in [(0,q.Distance.Dot),(1,q.Distance.Euclid),(2,q.Distance.Cosine)]:
            vectors=[[(float((row*17+col*7)%103)-51)*0.125+(row%3)*0.0625
                      for col in range(dimension)] for row in range(256 if args.codec == "sq8" else 512)]
            if args.codec == "pq":
                for row,vector in enumerate(vectors):
                    for col in range(dimension):
                        vector[col] += ((row//103)*(col+1)%7)*0.015625
            if constant is None:
                vectors[0]=[0.0]*dimension
            else:
                vectors=[[constant]*dimension for _ in vectors]
            queries=[[0.0]*dimension,
                     [float((col*13)%31-15)*0.25 for col in range(dimension)],
                     [100.0 if col%2 else -80.0 for col in range(dimension)]]
            path=args.output/f"qdrant-{len(fixtures)}"
            path.mkdir()
            shard=q.EdgeShard.create(str(path),q.EdgeConfig(
                vectors=q.EdgeVectorParams(dimension,distance,
                    quantization_config=(q.ScalarQuantizationConfig(q.ScalarType.Int8)
                        if args.codec == "sq8" else q.ProductQuantizationConfig(q.CompressionRatio.X8))),
                max_search_threads=1,
                hnsw_config=q.HnswIndexConfig(m=16,ef_construct=128,
                    full_scan_threshold=1_000_000,max_indexing_threads=1),
                optimizers=q.EdgeOptimizersConfig(default_segment_number=1,
                    indexing_threshold=1,prevent_unoptimized=False)))
            try:
                shard.update(q.UpdateOperation.upsert_points([q.Point(i,v) for i,v in enumerate(vectors)]))
                shard.optimize(); shard.flush()
                indexed=shard.info().indexed_vectors_count
                if indexed != len(vectors):
                    raise RuntimeError(f"reference index incomplete: {indexed}")
                metadata_paths=list(path.rglob("quantized.meta.json"))
                if len(metadata_paths) != 1:
                    raise RuntimeError("reference has no materialized scalar quantizer")
                pq_state={}
                if args.codec == "pq":
                    # Reuse native trained centroids/codes to isolate scoring
                    # from Qdrant's unseeded empty-cluster RNG. Training itself
                    # has a separate unedited-Rust differential.
                    metadata=json.loads(metadata_paths[0].read_text())
                    directory=metadata_paths[0].parent
                    raw=(directory/"matrix.dat").read_bytes()[4:]
                    stride=dimension*4
                    rows_by_value={raw[i*stride:(i+1)*stride]:i for i in range(len(vectors))}
                    encoded=(directory/"quantized.data").read_bytes()
                    subquantizers=len(metadata["vector_division"])
                    codes=[None]*len(vectors)
                    for point in shard.retrieve(list(range(len(vectors))),with_vector=True,with_payload=False):
                        key=struct.pack("<"+"f"*dimension,*point.vector)
                        physical=rows_by_value[key]
                        codes[point.id]=list(encoded[physical*subquantizers:(physical+1)*subquantizers])
                    if any(code is None for code in codes):
                        raise RuntimeError("native PQ row mapping incomplete")
                    pq_state=dict(pq_centroids=metadata["centroids"],pq_codes=codes)
                expected=[]; exact=[]
                for query in queries:
                    def search(use_exact):
                        hits=shard.search(q.SearchRequest(query=q.Query.Nearest(query),limit=len(vectors),
                            params=q.SearchParams(hnsw_ef=len(vectors),exact=use_exact,
                                quantization=q.QuantizationSearchParams(rescore=False,oversampling=1.0)),
                            with_payload=False,with_vector=False))
                        return sorted((h.id,float(h.score)**(2 if metric==1 else 1)) for h in hits)
                    expected.append(search(False)); exact.append(search(True))
                if constant is None and not any(a!=b for a,b in zip(expected,exact)):
                    raise RuntimeError("quantized reference indistinguishable from exact; inspect build")
                if any(len(hits)!=len(vectors) for hits in expected):
                    raise RuntimeError(f"reference did not expose every candidate: dim={dimension} metric={metric} counts={[len(hits) for hits in expected]}")
                fixtures.append(dict(dimension=dimension,metric=metric,constant=constant,vectors=vectors,
                    subquantizers=dimension//2,centroids=256,
                    queries=queries,expected=expected,exact=exact,indexed=indexed,**pq_state))
            finally:
                shard.close()
    fixture_path=args.output/"fixtures.json"
    fixture_path.write_text(json.dumps(fixtures)+"\n")
    binary=args.output/"akasha"
    subprocess.run(["rtk","proxy","pixi","run","mojo","build","-I","src",
        f"benchmarks/mojo/qdrant_{args.codec}_scores.mojo","-o",str(binary)],cwd=ROOT,check=True)
    raw=subprocess.check_output([str(binary),str(fixture_path)],text=True)
    (args.output/"akasha.log").write_text(raw)
    actual={}
    for line in raw.splitlines():
        case,query,id,score=line.split()
        actual.setdefault((int(case),int(query)),[]).append((int(id),float(score)))
    results=[]
    for i,fixture in enumerate(fixtures):
        for qi,expected in enumerate(fixture["expected"]):
            got=sorted(actual[(i,qi)])
            passed=len(got)==len(expected) and all(a[0]==e[0] and math.isclose(a[1],e[1],rel_tol=2e-5,abs_tol=2e-5)
                for a,e in zip(got,expected))
            results.append(dict(case=i,query=qi,dimension=fixture["dimension"],metric=fixture["metric"],
                passed=passed,max_score_delta=max(abs(a[1]-e[1]) for a,e in zip(got,expected))))
    report=dict(upstream_revision=REVISION,codec=args.codec,results=results,
        implementation_sha256=hashlib.sha256((ROOT/"src/akasha/index/quantization.mojo").read_bytes()).hexdigest(),
        passed=sum(r["passed"] for r in results),total=len(results),
        adapters=["squared public Euclid score", "IDs canonicalized", "F32 numeric tolerance 2e-5",
                  "native quantile unset, rescore false, oversampling 1, forced quantized plain scan"])
    if args.codec == "pq":
        report["adapters"].append("native PQ centroids/codes mapped by retrieved stored-vector bytes; isolates scorer from unseeded native training")
    (args.output/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"{report['passed']}/{report['total']} {args.codec.upper()} query fixtures passed")
    return 0 if report["passed"]==report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
