"""Compile Qdrant's unedited MMR selection with its portable scalar scorers.

The IndexSet adapter preserves insertion order and swap_remove. OrderedFloat
preserves equal signed zeros and NaNs ordered after all numbers. Transport,
volatile storage and lazy matrix plumbing are adapters, not a server oracle.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess

from qdrant_dbsf_reference import extract, bits, value
import qdrant_recommendation_reference as metrics

ROOT = Path(__file__).resolve().parents[1]
REVISION = metrics.REVISION
SOURCE = "lib/shard/src/query/mmr/mod.rs"


def main():
    # Reuse the existing verbatim metric/scorer fixture generator; its historical
    # fixture must remain byte-for-byte unchanged.
    historical = ROOT / "tests/fixtures/qdrant-recommendation/recommendation.json"
    old = historical.read_bytes()
    metrics.main()
    assert historical.read_bytes() == old
    metric_fixture = json.loads(old)
    base = (ROOT / ".build/qdrant-recommendation-reference/reference.rs").read_text()
    base = base.rsplit("fn main() {", 1)[0]
    source = subprocess.check_output([
        "rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
        "show", f"{REVISION}:{SOURCE}",
    ], text=True)
    selection = extract(source, "fn maximal_marginal_relevance(")
    scaffold = base + r'''
#[derive(Clone)] struct ScoredPoint { id: usize, score: f32 }
mod ahash { pub struct RandomState; }
struct IndexSet<T, S> { values: Vec<T>, marker: std::marker::PhantomData<S> }
impl<T, S> FromIterator<T> for IndexSet<T, S> {
    fn from_iter<I: IntoIterator<Item=T>>(iter: I) -> Self {
        Self { values: iter.into_iter().collect(), marker: std::marker::PhantomData }
    }
}
impl<T: PartialEq, S> IndexSet<T, S> {
    fn iter(&self) -> std::slice::Iter<'_, T> { self.values.iter() }
    fn is_empty(&self) -> bool { self.values.is_empty() }
    fn swap_remove(&mut self, value: &T) -> bool {
        if let Some(i) = self.values.iter().position(|v| v == value) {
            self.values.swap_remove(i); true
        } else { false }
    }
}
#[derive(Clone, Copy)] struct OrderedFloat(f32);
impl PartialEq for OrderedFloat {
    fn eq(&self, other: &Self) -> bool { self.0 == other.0 || (self.0.is_nan() && other.0.is_nan()) }
}
impl Eq for OrderedFloat {}
impl PartialOrd for OrderedFloat { fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(other)) } }
impl Ord for OrderedFloat {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0.partial_cmp(&other.0).unwrap_or_else(|| self.0.is_nan().cmp(&other.0.is_nan()))
    }
}
struct LazyMatrix { values: Vec<Vec<f32>> }
impl LazyMatrix { fn get_similarity(&mut self, i: usize, j: usize) -> f32 { self.values[i][j] } }
__SELECTION__
fn floats(raw: &str) -> Vec<f32> {
    if raw == "-" { vec![] } else { raw.split(',').map(|x| f32::from_bits(x.parse().unwrap())).collect() }
}
fn main() {
    let a: Vec<_> = std::env::args().skip(1).collect();
    let (query, matrix, lambda, limit) = if a[0] == "reduce" {
        let q = floats(&a[1]);
        let m = if a[2] == "-" { vec![] } else { a[2].split('/').map(floats).collect() };
        (q, m, f32::from_bits(a[3].parse().unwrap()), a[4].parse().unwrap())
    } else {
        let (kind, dim, metric) = (a[0].as_str(), a[1].parse().unwrap(), a[2].as_str());
        let q = preprocess(parse(&a[3], kind, dim), metric);
        let stored: Vec<_> = vectors(&a[4], kind, dim).into_iter().map(|v| preprocess(v, metric)).collect();
        let relevance = stored.iter().map(|v| similarity(&q, v, metric)).collect();
        // RawScorer prepares each stored vector again when it becomes a query.
        let matrix = stored.iter().map(|v| {
            let prepared = preprocess(v.clone(), metric);
            stored.iter().map(|other| similarity(&prepared, other, metric)).collect()
        }).collect();
        (relevance, matrix, f32::from_bits(a[5].parse().unwrap()), a[6].parse().unwrap())
    };
    let candidates = (0..query.len()).map(|id| ScoredPoint { id, score: (id as f32 + 0.25) * -3.0 }).collect();
    let result = maximal_marginal_relevance(candidates, query.clone(), LazyMatrix { values: matrix.clone() }, lambda, limit);
    println!("q:{}", query.iter().map(|x| x.to_bits().to_string()).collect::<Vec<_>>().join(","));
    for row in matrix { println!("m:{}", row.iter().map(|x| x.to_bits().to_string()).collect::<Vec<_>>().join(",")); }
    for hit in result { println!("{} {}", hit.id, hit.score.to_bits()); }
}
'''.replace("__SELECTION__", selection)
    build = ROOT / ".build/qdrant-mmr-reference"
    build.mkdir(parents=True, exist_ok=True)
    (build / "reference.rs").write_text(scaffold)
    binary = build / "reference"
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2024", "-Awarnings",
                    str(build / "reference.rs"), "-o", str(binary)], check=True)

    def run(args):
        lines = subprocess.check_output([str(binary), *args], text=True).splitlines()
        relevance = [int(x) for x in lines.pop(0)[2:].split(',') if x]
        matrix = []
        while lines and lines[0].startswith("m:"):
            matrix.append([int(x) for x in lines.pop(0)[2:].split(',') if x])
        return relevance, matrix, [list(map(int, line.split())) for line in lines]

    rng = random.Random(20261030)
    reductions = []
    for size in (0, 1, 2, 3, 5, 9):
        for variant in range(8):
            values = [0.0, -0.0, 1.0, -1.0, 1.0000001192092896, -3.75, float('inf'), -float('inf'), float('nan')]
            q = [rng.choice(values) if variant < 4 else rng.uniform(-3, 3) for _ in range(size)]
            matrix = [[rng.choice(values) if variant < 4 else rng.uniform(-4, 4) for _ in range(size)] for _ in range(size)]
            if variant == 0:
                q = [1.0] * size
                matrix = [[0.0] * size for _ in range(size)]
            for lam in (0.0, 0.01, 0.5, 1.0):
                limit = (0, 1, 3, size + 2)[variant % 4]
                qb, mb, expected = run(["reduce", ','.join(str(bits(x)) for x in q) or "-",
                    '/'.join(','.join(str(bits(x)) for x in row) for row in matrix) or "-", str(bits(lam)), str(limit)])
                reductions.append(dict(query_bits=qb, matrix_bits=mb, lambda_bits=bits(lam), limit=limit, expected=expected))
    cases = []
    for kind in ("dense", "sparse", "multivector"):
        for metric in (("dot",) if kind == "sparse" else ("dot", "l2", "cosine")):
            for variant in range(16):
                def vector():
                    values = [-2, -0.5, 0, 0.25, 1, 3]
                    if variant >= 8:
                        values = [value(bits(rng.uniform(-3, 3))) for _ in range(6)]
                    if kind == "sparse":
                        return [[i, rng.choice(values)] for i in sorted(rng.sample(range(6), rng.randrange(1, 6)))]
                    if kind == "multivector":
                        return [[rng.choice(values) for _ in range(3)] for _ in range(rng.randrange(1, 4))]
                    return [rng.choice(values) for _ in range(3)]
                query = vector()
                candidates = [vector() for _ in range(7)]
                diversity = value(bits((1, 0.99, 0.5, 0)[variant % 4]))
                lam = value(bits(1 - diversity))
                qb, mb, expected = run([kind, "3", metric, metrics.encode(query, kind),
                    '/'.join(metrics.encode(v, kind) for v in candidates), str(bits(lam)), "4"])
                cases.append(dict(kind=kind, metric=metric, query=query, candidates=candidates,
                    lambda_bits=bits(lam), diversity_bits=bits(diversity), limit=4,
                    query_bits=qb, matrix_bits=mb, expected=expected))
    fixture = dict(revision=REVISION, source=SOURCE, source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        selection_sha256=hashlib.sha256(selection.encode()).hexdigest(),
        scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(),
        metric_sources=metric_fixture['sources'], metric_functions=metric_fixture['functions'],
        adapter=__doc__, reductions=reductions, cases=cases)
    target = ROOT / "tests/fixtures/qdrant-mmr"
    target.mkdir(parents=True, exist_ok=True)
    metadata = {k:v for k,v in fixture.items() if k not in ('reductions', 'cases')}
    text = json.dumps(metadata, indent=2)[:-2] + ',\n'
    for key in ('reductions', 'cases'):
        text += f'  "{key}": [\n' + ',\n'.join('    ' + json.dumps(x, separators=(',', ':')) for x in fixture[key]) + '\n  ]'
        text += ',\n' if key == 'reductions' else '\n}\n'
    (target / "mmr.json").write_text(text)
    print(json.dumps(dict(reductions=len(reductions), vector_cases=len(cases))))


if __name__ == "__main__":
    main()
