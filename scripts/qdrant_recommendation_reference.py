"""Compile verbatim pinned Qdrant recommendation functions into a portable oracle.

Only storage, transport, type/iterator plumbing and result serialization are
substituted. F32 transforms, reducers, metrics, sparse merge and MaxSim execute
upstream source. This is not a full Qdrant server or ANN compatibility test.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"


def bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def encode(vector, kind):
    if kind == "sparse":
        return ",".join(f"{term}:{bits(value)}" for term, value in vector) or "e"
    if kind == "multivector":
        vector = [value for row in vector for value in row]
    return ",".join(str(bits(value)) for value in vector) or "e"


def main():
    sources = {}
    functions = {}

    def get(path, signatures):
        source = subprocess.check_output(
            ["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
             "show", f"{REVISION}:{path}"], text=True,
        )
        sources[path] = hashlib.sha256(source.encode()).hexdigest()
        result = []
        for name, signature in signatures:
            function = extract(source, signature)
            functions[name] = dict(source=path, signature=signature,
                                   sha256=hashlib.sha256(function.encode()).hexdigest())
            result.append(function)
        return "\n\n".join(result)

    average = get("lib/collection/src/recommendations.rs", [
        ("avg_vectors", "fn avg_vectors<'a>("),
        ("merge", "fn merge_positive_and_negative_avg("),
        ("average", "pub fn avg_vector_for_recommendation<'a>("),
    ])
    sparse = get("lib/sparse/src/common/sparse_vector.rs", [("combine", "pub fn combine_aggregate(")])
    sparse_score = get("lib/sparse/src/common/sparse_vector.rs", [("sparse_score", "pub fn score_vectors<T: Ord + Eq>(")])
    sigmoid = get("lib/common/common/src/math.rs", [
        ("fast_sigmoid", "pub fn fast_sigmoid("), ("scaled_fast_sigmoid", "pub fn scaled_fast_sigmoid("),
    ])
    metrics = get("lib/segment/src/spaces/simple.rs", [
        ("dot", "pub fn dot_similarity("), ("euclid", "pub fn euclid_similarity("),
        ("cosine", "pub fn cosine_preprocess("),
    ])
    normalized = get("lib/segment/src/spaces/tools.rs", [("normalized", "pub fn is_length_zero_or_normalized(")])
    maxsim = get("lib/segment/src/vector_storage/query_scorer/mod.rs", [("maxsim", "pub fn score_max_similarity<")])
    reco_path = "lib/segment/src/vector_storage/query/reco_query.rs"
    reco = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
                                   "show", f"{REVISION}:{reco_path}"], text=True)
    sources[reco_path] = hashlib.sha256(reco.encode()).hexdigest()
    reducers = []
    for label in ("RecoBestScoreQuery", "RecoSumScoresQuery"):
        body = extract(reco[reco.index(f"impl<T> Query<T> for {label}"):], "fn score_by(")
        functions[label] = dict(source=reco_path, signature=f"{label}::score_by",
                               sha256=hashlib.sha256(body.encode()).hexdigest())
        reducers.append(f"struct {label}<T>(RecoQuery<T>);\nimpl<T> Query<T> for {label}<T> {{\n{body}\n}}")

    scaffold = r'''
use std::borrow::Cow;
use std::iter::Peekable;
type ScoreType = f32;
type VectorElementType = f32;
type DimWeight = f32;
type DenseVector = Vec<f32>;
type CollectionResult<T> = Result<T, CollectionError>;
#[derive(Debug)] struct CollectionError(String);
impl CollectionError { fn bad_input(s: String) -> Self { Self(s) } }
#[derive(Clone, Default)] struct SparseVector { indices: Vec<u32>, values: Vec<f32> }
impl SparseVector {
    fn is_sorted(&self) -> bool { self.indices.windows(2).all(|w| w[0] < w[1]) }
    fn sort_by_indices(&mut self) {
        let mut rows: Vec<_> = self.indices.iter().copied().zip(self.values.iter().copied()).collect();
        rows.sort_by_key(|r| r.0); (self.indices, self.values) = rows.into_iter().unzip();
    }
    fn validate(&self) -> Result<(), ()> { if self.indices.len() == self.values.len() { Ok(()) } else { Err(()) } }
    __SPARSE__
}
#[derive(Clone)] struct TypedMultiDenseVector<T> { flattened_vectors: Vec<T>, dim: usize }
struct TypedMultiDenseVectorRef<'a, T> { flattened_vectors: &'a [T], dim: usize }
impl<T: Clone> TypedMultiDenseVectorRef<'_, T> {
    fn to_owned(&self) -> TypedMultiDenseVector<T> { TypedMultiDenseVector { flattened_vectors: self.flattened_vectors.to_vec(), dim: self.dim } }
    fn is_empty(&self) -> bool { self.flattened_vectors.is_empty() }
    fn multi_vectors(&self) -> impl Iterator<Item=&[T]> { self.flattened_vectors.chunks(self.dim) }
}
#[derive(Clone)] enum VectorInternal { Dense(DenseVector), Sparse(SparseVector), MultiDense(TypedMultiDenseVector<f32>) }
enum VectorRef<'a> { Dense(&'a [f32]), Sparse(&'a SparseVector), MultiDense(TypedMultiDenseVectorRef<'a, f32>) }
impl From<DenseVector> for VectorInternal { fn from(v: DenseVector) -> Self { Self::Dense(v) } }
impl From<SparseVector> for VectorInternal { fn from(v: SparseVector) -> Self { Self::Sparse(v) } }
impl From<TypedMultiDenseVector<f32>> for VectorInternal { fn from(v: TypedMultiDenseVector<f32>) -> Self { Self::MultiDense(v) } }
impl VectorInternal {
    fn as_ref(&self) -> VectorRef<'_> {
        match self {
            Self::Dense(v) => VectorRef::Dense(v), Self::Sparse(v) => VectorRef::Sparse(v),
            Self::MultiDense(v) => VectorRef::MultiDense(TypedMultiDenseVectorRef { flattened_vectors: &v.flattened_vectors, dim: v.dim }),
        }
    }
}
struct RecoQuery<T> { positives: Vec<T>, negatives: Vec<T> }
trait Query<T> { fn score_by(&self, similarity: impl Fn(&T) -> ScoreType) -> ScoreType; }
trait PrimitiveVectorElement: Clone {}
impl PrimitiveVectorElement for f32 {}
trait Metric<T> { fn similarity(a: &[T], b: &[T]) -> f32; }
struct Dot; struct Euclid;
impl Metric<f32> for Dot { fn similarity(a: &[f32], b: &[f32]) -> f32 { dot_similarity(a, b) } }
impl Metric<f32> for Euclid { fn similarity(a: &[f32], b: &[f32]) -> f32 { euclid_similarity(a, b) } }
__FUNCTIONS__
fn parse(raw: &str, kind: &str, dim: usize) -> VectorInternal {
    if kind == "sparse" {
        let mut v = SparseVector::default();
        if raw != "e" { for term in raw.split(',') {
            let (id, value) = term.split_once(':').unwrap();
            v.indices.push(id.parse().unwrap()); v.values.push(f32::from_bits(value.parse().unwrap()));
        }}
        return v.into();
    }
    let v: Vec<f32> = if raw == "e" { vec![] } else { raw.split(',').map(|x| f32::from_bits(x.parse().unwrap())).collect() };
    if kind == "dense" { v.into() } else { TypedMultiDenseVector { flattened_vectors: v, dim }.into() }
}
fn vectors(raw: &str, kind: &str, dim: usize) -> Vec<VectorInternal> {
    if raw == "-" { vec![] } else { raw.split('/').map(|s| parse(s, kind, dim)).collect() }
}
fn preprocess(v: VectorInternal, metric: &str) -> VectorInternal {
    if metric != "cosine" { return v; }
    match v {
        VectorInternal::Dense(v) => cosine_preprocess(v).into(),
        VectorInternal::MultiDense(v) => TypedMultiDenseVector {
            flattened_vectors: v.flattened_vectors.chunks(v.dim).flat_map(|row| cosine_preprocess(row.to_vec())).collect(), dim: v.dim,
        }.into(),
        other => other,
    }
}
fn similarity(a: &VectorInternal, b: &VectorInternal, metric: &str) -> f32 {
    match (a.as_ref(), b.as_ref()) {
        (VectorRef::Dense(a), VectorRef::Dense(b)) => if metric == "l2" { euclid_similarity(a, b) } else { dot_similarity(a, b) },
        (VectorRef::Sparse(a), VectorRef::Sparse(b)) => score_vectors(&a.indices, &a.values, &b.indices, &b.values).unwrap_or(0.0),
        (VectorRef::MultiDense(a), VectorRef::MultiDense(b)) => if metric == "l2" { score_max_similarity::<f32, Euclid>(a,b) } else { score_max_similarity::<f32, Dot>(a,b) },
        _ => panic!("type mismatch"),
    }
}
fn encoded(v: &VectorInternal) -> String {
    match v {
        VectorInternal::Dense(v) => v.iter().map(|x| x.to_bits().to_string()).collect::<Vec<_>>().join(","),
        VectorInternal::MultiDense(v) => v.flattened_vectors.iter().map(|x| x.to_bits().to_string()).collect::<Vec<_>>().join(","),
        VectorInternal::Sparse(v) => v.indices.iter().zip(&v.values).map(|(i,x)| format!("{}:{}", i, x.to_bits())).collect::<Vec<_>>().join(","),
    }
}
fn main() {
    let a: Vec<_> = std::env::args().skip(1).collect();
    if a[0] == "reduce" {
        let parse = |s: &str| if s == "-" { vec![] } else { s.split(',').map(|x| f32::from_bits(x.parse().unwrap())).collect() };
        let query = RecoQuery { positives: parse(&a[2]), negatives: parse(&a[3]) };
        let score = if a[1] == "best_score" { RecoBestScoreQuery(query).score_by(|x| *x) } else { RecoSumScoresQuery(query).score_by(|x| *x) };
        println!("{}", score.to_bits()); return;
    }
    let (kind, dim, metric, strategy) = (a[0].as_str(), a[1].parse().unwrap(), a[2].as_str(), a[3].as_str());
    let mut positive = vectors(&a[4], kind, dim); let mut negative = vectors(&a[5], kind, dim);
    // ID lookups retrieve canonical stored values before the recommendation
    // transform. Source field and target field can use different metrics.
    if a.len() > 7 {
        for index in a[7].split(',').filter(|x| !x.is_empty()) {
            let index: usize = index.parse().unwrap();
            positive[index] = preprocess(positive[index].clone(), &a[9]);
        }
        for index in a[8].split(',').filter(|x| !x.is_empty()) {
            let index: usize = index.parse().unwrap();
            negative[index] = preprocess(negative[index].clone(), &a[9]);
        }
    }
    let average = if strategy == "average_vector" {
        match avg_vector_for_recommendation(positive.iter().map(VectorInternal::as_ref), negative.iter().map(VectorInternal::as_ref).peekable()) {
            Ok(v) => { println!("average:{}", encoded(&v)); Some(preprocess(v, metric)) },
            Err(e) => { println!("error:{}", e.0); return; },
        }
    } else { None };
    let query = RecoQuery {
        positives: positive.into_iter().map(|v| preprocess(v, metric)).collect(),
        negatives: negative.into_iter().map(|v| preprocess(v, metric)).collect(),
    };
    let best = RecoBestScoreQuery(query);
    let sum = RecoSumScoresQuery(RecoQuery { positives: best.0.positives.clone(), negatives: best.0.negatives.clone() });
    let candidates = vectors(&a[6], kind, dim);
    let mut hits = vec![];
    for (i, v) in candidates.into_iter().enumerate() {
        let v = preprocess(v, metric);
        let score = match strategy {
            "average_vector" => similarity(average.as_ref().unwrap(), &v, metric),
            "best_score" => best.score_by(|q| similarity(q, &v, metric)),
            _ => sum.score_by(|q| similarity(q, &v, metric)),
        };
        if strategy == "average_vector" && kind == "sparse" && score == 0.0 { continue; }
        hits.push((i+1, score));
    }
    hits.sort_by(|a,b| b.1.partial_cmp(&a.1).unwrap().then(a.0.cmp(&b.0)));
    for (id, score) in hits {
        let score = if strategy == "average_vector" && metric == "l2" { score.abs().sqrt() } else { score };
        println!("{} {}", id, score.to_bits());
    }
}
'''.replace("__SPARSE__", sparse).replace("__FUNCTIONS__", "\n\n".join([
        average, sigmoid, metrics, normalized, sparse_score, maxsim, *reducers,
    ]))
    build = ROOT / ".build/qdrant-recommendation-reference"
    build.mkdir(parents=True, exist_ok=True)
    rust = build / "reference.rs"
    binary = build / "reference"
    rust.write_text(scaffold)
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2024", str(rust), "-o", str(binary)], check=True)

    rng = random.Random(20261030)
    cases = []
    for kind in ("dense", "sparse", "multivector"):
        dimension = 0 if kind == "sparse" else 3

        def vector():
            if kind == "sparse":
                return [[i, rng.choice([-3, -1, 0, 0.25, 2])] for i in sorted(rng.sample(range(8), rng.randrange(0, 7)))]
            if kind == "multivector":
                return [[rng.choice([-3, -0.5, 0, 0.25, 2]) for _ in range(3)] for _ in range(rng.randrange(1, 4))]
            return [rng.choice([-3, -0.5, 0, 0.25, 2]) for _ in range(3)]

        for metric in (("dot",) if kind == "sparse" else ("dot", "l2", "cosine")):
            for count in range(8):
                positive = [vector() for _ in range(count % 4)]
                negative = [vector() for _ in range(1 + count % 3)] if count < 6 else []
                candidates = [vector() for _ in range(7)]
                for strategy in ("average_vector", "best_score", "sum_scores"):
                    if not positive and not negative:
                        continue
                    args = [kind, str(dimension), metric, strategy,
                            *["/".join(encode(v, kind) for v in group) or "-" for group in (positive, negative, candidates)]]
                    for stored_ids in (False, True):
                        positive_ids = list(range(0, len(positive), 2)) if stored_ids else []
                        negative_ids = list(range(0, len(negative), 2)) if stored_ids else []
                        source_metric = "cosine" if kind != "sparse" else "dot"
                        lookup_args = [",".join(map(str, positive_ids)), ",".join(map(str, negative_ids)), source_metric]
                        lines = subprocess.check_output([str(binary), *args, *lookup_args], text=True).splitlines()
                        sample = dict(kind=kind, dimension=dimension, metric=metric, strategy=strategy,
                                      positive=positive, negative=negative, candidates=candidates,
                                      positive_ids=positive_ids, negative_ids=negative_ids, source_metric=source_metric)
                        if lines[0].startswith("error:"):
                            sample["error"] = lines[0]
                        else:
                            if lines[0].startswith("average:"):
                                sample["average_bits"] = lines.pop(0).removeprefix("average:")
                            sample["expected"] = [list(map(int, line.split())) for line in lines]
                        cases.append(sample)
    reductions = []
    pairs = [([42], [4]), ([4], [42]), ([-1], [-0.0, 0.0]), ([0.0, -0.0], [-1]),
             ([-42], [-84]), ([-84], [-42]), ([2], [2]), ([], [2]), ([2], []),
             ([1e20, -1e20, 3], [1]), ([3e38, 3e38], []), ([1e-38], [-1e-38])]
    for pos, neg in pairs:
        for strategy in ("best_score", "sum_scores"):
            score = int(subprocess.check_output([str(binary), "reduce", strategy,
                        ",".join(str(bits(v)) for v in pos) or "-", ",".join(str(bits(v)) for v in neg) or "-"], text=True))
            reductions.append(dict(strategy=strategy, positive_bits=list(map(bits, pos)), negative_bits=list(map(bits, neg)), score_bits=score))
    fixture = dict(revision=REVISION, sources=sources, functions=functions,
                   scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(),
                   adapter="F32 containers and storage-free query plumbing; verbatim transforms/reducers/scalar metrics/sparse merge/MaxSim; ascending ID ties; no ANN or datatype conversion oracle",
                   cases=cases, reductions=reductions)
    target = ROOT / "tests/fixtures/qdrant-recommendation"
    target.mkdir(parents=True, exist_ok=True)
    # One query per line keeps the deterministic fixture reviewable without
    # expanding nested vector coordinates into tens of thousands of lines.
    metadata = {key: value for key, value in fixture.items() if key not in ("cases", "reductions")}
    text = json.dumps(metadata, indent=2)[:-2] + ',\n  "cases": [\n'
    text += ",\n".join("    " + json.dumps(sample, separators=(",", ":")) for sample in cases)
    text += '\n  ],\n  "reductions": [\n'
    text += ",\n".join("    " + json.dumps(sample, separators=(",", ":")) for sample in reductions)
    (target / "recommendation.json").write_text(text + "\n  ]\n}\n")
    print(json.dumps(dict(queries=len(cases), reductions=len(reductions), functions=len(functions))))


if __name__ == "__main__":
    main()
