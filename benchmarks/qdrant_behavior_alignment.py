"""Reproducible existing-capability differentials against pinned Qdrant Edge.

Run with both python/ and the installed qdrant_edge 0.8.0 on PYTHONPATH.
Reports mismatches without changing either database or any acceptance gate.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path

import qdrant_edge as q
from benchmarks.qdrant_match_reference import boolean_matches
from akashadb import Collection, FieldQuery, PayloadField, PointMutation, SparseElement, VectorField

ROOT = Path(__file__).resolve().parents[1]
REVISION = "21db2f3ff95d50de3a2b88a741312c056fd1762d"


def rows(hits, *, square=False):
    return sorted([(int(h.id), float(h.score) ** (2 if square else 1)) for h in hits])


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    version = importlib.metadata.version("qdrant-edge-py")
    if version != "0.8.0":
        raise RuntimeError(f"pinned Edge 0.8.0 required, got {version}")
    results = []
    kernel_sha256 = hashlib.sha256((ROOT / "python/akashadb/_kernel.so").read_bytes()).hexdigest()

    def compare(name, actual, expected, *, tolerance=2e-5):
        passed = len(actual) == len(expected) and all(
            a[0] == e[0] and math.isclose(a[1], e[1], rel_tol=tolerance, abs_tol=tolerance)
            for a, e in zip(actual, expected)
        )
        results.append(dict(name=name, passed=passed, akasha=[(i,s if math.isfinite(s) else str(s)) for i,s in actual], qdrant=[(i,s if math.isfinite(s) else str(s)) for i,s in expected],
                            tolerance=tolerance))
        print(name, "PASS" if passed else "FAIL", flush=True)

    def compare_state(name, a, b, ids):
        actual=[]
        expected=[]
        for id in ids:
            point=a.get_point(id)
            actual.append(dict(id=id,vectors=point.vectors,payload={v.name:v.value for v in point.fields}))
        for point in b.retrieve(ids,with_vector=True,with_payload=True):
            expected.append(dict(id=point.id,vectors=point.vector or {},payload=point.payload or {}))
        expected.sort(key=lambda p:p["id"])
        actual.sort(key=lambda p:p["id"])
        passed=actual==expected
        results.append(dict(name=name,passed=passed,akasha=actual,qdrant=expected))
        print(name,"PASS" if passed else "FAIL",flush=True)

    def pair(name, ak_fields, q_vectors=None, q_sparse=None):
        ap = output / name / "akasha"
        qp = output / name / "qdrant"
        qp.mkdir(parents=True)
        return (Collection(ap, 2, vectors=ak_fields),
                q.EdgeShard.create(str(qp), q.EdgeConfig(vectors=q_vectors,
                    sparse_vectors=q_sparse, max_search_threads=1)))

    for metric, distance in [("dot", q.Distance.Dot), ("l2", q.Distance.Euclid),
                             ("cosine", q.Distance.Cosine)]:
        for kind in ("dense", "multivector"):
            multivector = kind == "multivector"
            a, b = pair(f"{kind}-{metric}", {"v": VectorField(2, kind=kind, metric=metric)},
                {"v": q.EdgeVectorParams(2, distance,
                    multivector_config=q.MultiVectorConfig(q.MultiVectorComparator.MaxSim) if multivector else None)})
            dense = [[1., 2.], [-2., 3.], [4., -1.], [0.5, -0.25]]
            vectors = [[v, [v[1], -v[0]]] for v in dense] if multivector else dense
            a.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v}) for i,v in enumerate(vectors)])
            b.update(q.UpdateOperation.upsert_points([q.Point(i+1, {"v": v}) for i,v in enumerate(vectors)]))
            query = [[0.5, 1.], [-0.25, 0.75]] if multivector else [0.5, 1.]
            compare(f"{kind}-{metric}", rows(a.search_field("v", query, 10)),
                    rows(b.query(q.QueryRequest(10, query=q.Query.Nearest(query, using="v"))), square=metric=="l2"))
            a.flush(); a.close(); b.flush(); b.close()

    # Raw compact storage is distinct from learned quantization. Check shared
    # half/byte representations through both ingestion and reopen.
    for dtype, datatype in [("f16", q.VectorStorageDatatype.Float16),
                            ("u8", q.VectorStorageDatatype.Uint8)]:
        for metric, distance in [("dot", q.Distance.Dot), ("l2", q.Distance.Euclid),
                                 ("cosine", q.Distance.Cosine)]:
            name = f"compact-{dtype}-{metric}"
            a, b = pair(name, {"v": VectorField(2, dtype=dtype, metric=metric)},
                        {"v": q.EdgeVectorParams(2, distance, datatype=datatype)})
            vectors = ([[0., 0.], [1.5, -2.25], [-4., 0.125], [0.5, 0.75]]
                       if dtype == "f16" else [[0, 0], [255, 1], [4, 128], [17, 29]])
            query = [0.5, 1.25] if dtype == "f16" else [13, 21]
            a.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v})
                                 for i, v in enumerate(vectors)])
            b.update(q.UpdateOperation.upsert_points([
                q.Point(i+1, {"v": v}) for i, v in enumerate(vectors)]))
            for phase in ("live", "reopen"):
                if phase == "reopen":
                    a.flush(); a.close(); b.flush(); b.close()
                    a = Collection(output/name/"akasha", 2)
                    b = q.EdgeShard.load(str(output/name/"qdrant"))
                actual = rows(a.search_field("v", query, 10))
                expected = rows(b.query(q.QueryRequest(10,
                    query=q.Query.Nearest(query, using="v"))), square=metric == "l2")
                compare(name+"-"+phase, actual, expected,
                        tolerance=0 if dtype == "f16" and metric == "cosine" else 2e-5)
            a.close(); b.close()

    # Canonical native-half inputs isolate half metric semantics from ingestion
    # rounding. Cover both preprocessing thresholds and multi-row aggregation.
    for kind in ("dense", "multivector"):
        multi = kind == "multivector"
        name = f"half-cosine-boundaries-{kind}"
        a, b = pair(name, {"v": VectorField(3, dtype="f16", kind=kind, metric="cosine")},
                    {"v": q.EdgeVectorParams(3, q.Distance.Cosine,
                        datatype=q.VectorStorageDatatype.Float16,
                        multivector_config=q.MultiVectorConfig(q.MultiVectorComparator.MaxSim) if multi else None)})
        dense = [[0., 0., 0.], [2**-13, 0., 0.], [2**-12, 2**-12, 0.],
                 [1., 2**-12, 0.], [3., -2., 4.]]
        vectors = [[v, [-v[0], v[2], v[1]]] for v in dense] if multi else dense
        a.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v}) for i, v in enumerate(vectors)])
        b.update(q.UpdateOperation.upsert_points([q.Point(i+1, {"v": v}) for i, v in enumerate(vectors)]))
        for phase in ("live", "reopen"):
            if phase == "reopen":
                a.flush(); a.close(); b.flush(); b.close()
                a = Collection(output/name/"akasha", 2)
                b = q.EdgeShard.load(str(output/name/"qdrant"))
            for case, base_query in enumerate(dense):
                query = [base_query, [1., 2., -3.]] if multi else base_query
                compare(f"{name}-{phase}-{case}", rows(a.search_field("v", query, 10)),
                        rows(b.query(q.QueryRequest(10, query=q.Query.Nearest(query, using="v")))),
                        tolerance=2e-7 if multi else 0)
            assert [a.get_point(i+1).vectors["v"] for i in range(len(vectors))] == vectors
        a.close(); b.close()

    for kind in ("dense", "multivector"):
        multi = kind == "multivector"
        a, b = pair(f"zero-cosine-{kind}", {"v": VectorField(2, kind=kind, metric="cosine")},
                    {"v": q.EdgeVectorParams(2, q.Distance.Cosine,
                        multivector_config=q.MultiVectorConfig(q.MultiVectorComparator.MaxSim) if multi else None)})
        vectors = [[[0., 0.], [0., 0.]], [[1., 0.], [0., 0.]], [[-1., 0.], [0., 0.]]] if multi else [[0., 0.], [1., 0.], [-1., 0.]]
        a.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v}) for i, v in enumerate(vectors)])
        b.update(q.UpdateOperation.upsert_points([q.Point(i+1, {"v": v}) for i, v in enumerate(vectors)]))
        for zero_query in (False, True):
            query = [0., 0.] if zero_query else [1., 0.]
            if multi:
                query = [query, [0., 0.]]
            name = f"cosine-{kind}-zero-{'query' if zero_query else 'stored'}"
            expected = rows(b.query(q.QueryRequest(10, query=q.Query.Nearest(query, using="v"))))
            try:
                actual = rows(a.search_field("v", query, 10))
            except Exception as error:
                results.append(dict(name=name, passed=False, akasha_error=str(error), qdrant=expected))
                print(name, "FAIL", flush=True)
            else:
                compare(name, actual, expected)
        a.close(); b.close()

    a, b = pair("sparse", {"s": VectorField(0, kind="sparse", metric="dot")},
                q_sparse={"s": q.EdgeSparseVectorParams(full_scan_threshold=0)})
    vectors = [(1,[1],[3]), (2,[1],[-2]), (3,[2],[9]), (4,[],[]),
               (5,[1,2],[1,-1]), (6,[1,2,3],[1e10,1,-1e10]),
               (7,[4,5],[3e38,-3e38]), (8,[4],[3e38]), (9,[4],[-3e38])]
    a.apply_point_batch([PointMutation.upsert(i, vectors={"s": [SparseElement(x,y) for x,y in zip(ix,v)]}) for i,ix,v in vectors])
    b.update(q.UpdateOperation.upsert_points([q.Point(i,{"s":q.SparseVector(ix,v)}) for i,ix,v in vectors]))
    for name,ix,v in [("overlap",[1],[1]), ("cancellation",[1,2],[1,1]),
                      ("float32-cancellation",[1,2,3],[1,1,1]), ("missing",[9],[1]), ("empty",[],[]), ("overflow",[4,5],[3e38,3e38])]:
        compare("sparse-"+name,
                rows(a.search_field("s",[SparseElement(x,y) for x,y in zip(ix,v)],10)),
                rows(b.query(q.QueryRequest(10,query=q.Query.Nearest(q.SparseVector(ix,v),using="s")))))
    a.close(); b.close()

    a,b = pair("rrf", {n: VectorField(2,metric="dot") for n in ["a","b"]},
               {n:q.EdgeVectorParams(2,q.Distance.Dot) for n in ["a","b"]})
    vectors = [{"a":[4.,1.],"b":[1.,1.]}, {"a":[3.,1.],"b":[4.,1.]},
               {"a":[1.,1.],"b":[3.,1.]}]
    a.apply_point_batch([PointMutation.upsert(i+1,vectors=v,fields=[PayloadField("tag","string","old")]) for i,v in enumerate(vectors)])
    b.update(q.UpdateOperation.upsert_points([q.Point(i+1,v,payload={"tag":"old"}) for i,v in enumerate(vectors)]))
    branches=[FieldQuery(n,[1.,0.]) for n in ["a","b"]]
    prefetch=[q.Prefetch(10,query=q.Query.Nearest([1.,0.],using=n)) for n in ["a","b"]]
    for constant in [None, 1, 2, 17, 16_777_216]:
        options={} if constant is None else {"rank_constant":constant}
        compare("rrf-"+str(constant), rows(a.search_fields(branches,3,fetch_k=10,**options)),
                rows(b.query(q.QueryRequest(3,query=q.Fusion.Rrf(k=constant or 2),prefetches=prefetch))), tolerance=0)
    # Test update before replacement so a failed upsert cannot contaminate it.
    a.apply_point_batch([PointMutation.update(2,vectors={"a":[8.,1.]})])
    b.update(q.UpdateOperation.update_vectors([q.PointVectors(2,{"a":[8.,1.]})]))
    compare("update-preserves-omitted-vector",rows(a.search_field("b",[1.,0.],10)),
            rows(b.query(q.QueryRequest(10,query=q.Query.Nearest([1.,0.],using="b")))))
    compare_state("update-preserves-payload",a,b,[2])
    # Upsert is whole-point replacement.
    a.apply_point_batch([PointMutation.upsert(1,vectors={"a":[9.,1.]})])
    b.update(q.UpdateOperation.upsert_points([q.Point(1,{"a":[9.,1.]})]))
    compare("upsert-removes-omitted-vector",rows(a.search_field("b",[1.,0.],10)),
            rows(b.query(q.QueryRequest(10,query=q.Query.Nearest([1.,0.],using="b")))))
    compare_state("upsert-replaces-payload",a,b,[1,2])
    a.flush(); a.close(); b.flush(); b.close()
    a=Collection(output/"rrf"/"akasha",2)
    b=q.EdgeShard.load(str(output/"rrf"/"qdrant"))
    compare_state("upsert-update-reopen",a,b,[1,2])
    a.apply_point_batch([PointMutation.upsert(1)])
    b.update(q.UpdateOperation.upsert_points([q.Point(1,{})]))
    compare_state("empty-upsert",a,b,[1])
    a.close(); b.close()
    # Flat scalar predicates: each key has one declared Akasha type. Qdrant
    # has no typed-predicate parameter; heterogeneous type semantics are separate.
    a,b = pair("filters", {"v": VectorField(2,metric="dot")},
               {"v": q.EdgeVectorParams(2,q.Distance.Dot)})
    payloads = [{"tag":"a","n":1,"f":1.5,"keep":True},
                {"tag":"b","n":2,"f":2.5,"keep":False},
                {"tag":"a","n":3,"f":3.5,"keep":True}, {},
                {"tag":"c","n":-1,"f":-1.5,"keep":False}]
    types={"tag":"string","n":"int","f":"float","keep":"bool"}
    a.apply_point_batch([PointMutation.upsert(i+1,vectors={"v":[i+1.,1.]},
        fields=[PayloadField(key,types[key],value) for key,value in payload.items()])
        for i,payload in enumerate(payloads)])
    b.update(q.UpdateOperation.upsert_points([q.Point(i+1,{"v":[i+1.,1.]},payload=payload)
        for i,payload in enumerate(payloads)]))
    bool_matches, bool_source = boolean_matches(ROOT / "reference/qdrant-edge-0.8.0", output, [p.get("keep") for p in payloads])
    predicates=[]
    for key,value in [("tag","a"),("n",2),("f",2.5),("keep",True)]:
        for op in (["eq","ne"] if key in ("tag","keep") else ["eq","ne","lt","lte","gt","gte"]):
            condition=dict(kind="condition",name=key,type=types[key],operator={"lte":"le","gte":"ge"}.get(op,op),value=value)
            if op=="eq":
                target=q.FieldCondition(key,range=q.RangeFloat(gte=value,lte=value)) if key=="f" else q.FieldCondition(key,match=q.MatchValue(value))
            elif op=="ne":
                target=(q.FieldCondition(key,match=q.MatchExcept([value])) if key in ("tag","n") else
                        q.FieldCondition(key,match=q.MatchValue(not value)) if key=="keep" else
                        q.Filter(should=[q.FieldCondition(key,range=q.RangeFloat(lt=value)),q.FieldCondition(key,range=q.RangeFloat(gt=value))]))
            else:
                target=q.FieldCondition(key,range=q.RangeFloat(**{op:value}))
            predicates.append((key+"-"+op,condition,target))
    _,first,qa=predicates[0]
    _,second,qb=predicates[3]
    predicates.extend([
        ("and",dict(kind="all",children=[first,second]),q.Filter(must=[qa,qb])),
        ("or",dict(kind="any",children=[first,second]),q.Filter(min_should=q.MinShould([qa,qb],1))),
        ("not-with-missing",dict(kind="not",child=first),q.Filter(must_not=[qa])),
        ("all-empty",dict(kind="all",children=[]),q.Filter(must=[])),
        ("any-empty",dict(kind="any",children=[]),q.Filter(min_should=q.MinShould([],1))),
    ])
    for phase in ("live","reopen"):
        if phase=="reopen":
            a.flush(); a.close(); b.flush(); b.close()
            a=Collection(output/"filters"/"akasha",2)
            b=q.EdgeShard.load(str(output/"filters"/"qdrant"))
        for name,condition,target in predicates:
            expected = ([(i+1,float(i+1)) for i,match in enumerate(bool_matches[0 if name=="keep-eq" else 1]) if match]
                        if name.startswith("keep-") else
                        rows(b.query(q.QueryRequest(10,query=q.Query.Nearest([1.,0.],using="v"),filter=q.Filter(must=[target])))))
            compare("filter-"+phase+"-"+name, rows(a.search_field("v",[1.,0.],10,filter=condition)), expected)
            results[-1]["reference"] = "extracted-rust-MatchValue" if name.startswith("keep-") else "native-Edge"

    a.close(); b.close()
    # Mixed scalar payloads expose MatchExcept and numeric-range coercion.
    a,b = pair("mixed-filters", {"v": VectorField(2, metric="dot")},
               {"v": q.EdgeVectorParams(2,q.Distance.Dot)})
    values = [("int", 2), ("float", 2.0), ("float", 2.5), ("int", 3),
              ("string", "2"), ("bool", True), (None, None),
              ("int", 9_007_199_254_740_993)]
    a.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": [i+1.,1.]},
        fields=[] if kind is None else [PayloadField("x", kind, value)])
        for i,(kind,value) in enumerate(values)])
    b.update(q.UpdateOperation.upsert_points([q.Point(i+1, {"v": [i+1.,1.]},
        payload={} if kind is None else {"x": value}) for i,(kind,value) in enumerate(values)]))
    for phase in ("live", "reopen"):
        if phase == "reopen":
            a.flush(); a.close(); b.flush(); b.close()
            a=Collection(output/"mixed-filters"/"akasha",2)
            b=q.EdgeShard.load(str(output/"mixed-filters"/"qdrant"))
        for kind,value in [("string","2"), ("int",2), ("float",2.0),
                           ("int",9_007_199_254_740_992)]:
            for op in (["eq","ne"] if kind == "string" else ["eq","ne","lt","lte","gt","gte"]):
                condition=dict(kind="condition",name="x",type=kind,
                    operator={"lte":"le","gte":"ge"}.get(op,op),value=value)
                if op == "eq" and kind != "float":
                    target=q.FieldCondition("x",match=q.MatchValue(value))
                elif op == "ne" and kind != "float":
                    target=q.FieldCondition("x",match=q.MatchExcept([value]))
                elif op == "eq":
                    target=q.FieldCondition("x",range=q.RangeFloat(gte=value,lte=value))
                elif op == "ne":
                    target=q.Filter(should=[q.FieldCondition("x",range=q.RangeFloat(lt=value)),
                                           q.FieldCondition("x",range=q.RangeFloat(gt=value))])
                else:
                    target=q.FieldCondition("x",range=q.RangeFloat(**{op:value}))
                expected=rows(b.query(q.QueryRequest(20,query=q.Query.Nearest([1.,0.],using="v"),filter=q.Filter(must=[target]))))
                compare(f"mixed-filter-{phase}-{kind}-{value}-{op}",
                    rows(a.search_field("v",[1.,0.],20,filter=condition)), expected)
    a.close(); b.close()
    report=dict(upstream_revision=REVISION,edge_version=version,cases=results,
                kernel_sha256=kernel_sha256, boolean_reference=bool_source,
                reference_limitations=["Edge 0.8.0 MatchValue(True/False) incorrectly extracts integer 1/0; boolean cases execute the unedited Rust core arm"],
                passed=sum(r["passed"] for r in results),total=len(results),
                adapters=["Euclid public scores squared to Akasha L2 units", "IDs canonicalized to ignore upstream unspecified score ties", "native numeric tolerance per case; RRF exact", "logical any maps to Qdrant min_should(count=1), including empty any"],
                source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((ROOT/"src/akasha").rglob("*.mojo"))})
    (output/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"{report['passed']}/{report['total']} passed")
    return 0 if report['passed']==report['total'] else 1

if __name__ == "__main__":
    raise SystemExit(main())
