"""Check payload connectivity against two unedited Qdrant methods.

The only algorithm adapter is the explicitly shared SplitMix64 RNG. In-memory
locks/bitsets represent Qdrant storage; no Edge runtime or timing is measured.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
from benchmarks.qdrant_search_reference import ROOT, REVISION, run


def extract(source: str, name: str) -> str:
    start = source.index(f"    pub fn {name}<")
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


ADAPTER = r'''
use std::ops::Range;
type PointOffsetType = u32;
trait Sample: Sized { fn sample(rng: &mut Random, range: Range<Self>) -> Self; }
trait Rng { fn random_range<T: Sample>(&mut self, range: Range<T>) -> T; }
struct Random { state: u64 }
impl Random {
    fn next(&mut self) -> u64 {
        let mut x = self.state.wrapping_add(0x9E3779B97F4A7C15);
        self.state = x;
        x = (x ^ (x >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        x = (x ^ (x >> 27)).wrapping_mul(0x94D049BB133111EB);
        x ^ (x >> 31)
    }
}
impl Rng for Random {
    fn random_range<T: Sample>(&mut self, range: Range<T>) -> T { T::sample(self, range) }
}
impl Sample for usize {
    fn sample(rng: &mut Random, range: Range<Self>) -> Self {
        assert_eq!(range.start, 0);
        let bound = range.end as u64;
        let limit = u64::MAX - u64::MAX % bound;
        loop { let value = rng.next(); if value < limit { return (value % bound) as usize; } }
    }
}
impl Sample for f32 {
    fn sample(rng: &mut Random, range: Range<Self>) -> Self {
        assert_eq!(range.start, 0.0); assert_eq!(range.end, 1.0);
        ((rng.next() >> 40) as f32) / 16777216.0
    }
}
struct BitVec(Vec<bool>);
impl BitVec {
    fn repeat(value: bool, len: usize) -> Self { Self(vec![value; len]) }
    fn set(&mut self, i: usize, value: bool) { self.0[i] = value; }
    fn get_bit(&self, i: usize) -> Option<bool> { self.0.get(i).copied() }
    fn fill(&mut self, value: bool) { self.0.fill(value); }
}
struct Links(Vec<u32>);
impl Links { fn iter(&self) -> std::iter::Copied<std::slice::Iter<'_ , u32>> { self.0.iter().copied() } }
struct Lock<T>(T);
impl<T> Lock<T> { fn lock(&self) -> &T { &self.0 } fn read(&self) -> &T { &self.0 } }
#[derive(Clone)] struct EntryPoint { point_id: u32 }
struct Extras(Vec<EntryPoint>);
impl Extras { fn iter_unsorted(&self) -> std::slice::Iter<'_, EntryPoint> { self.0.iter() } }
struct EntryPoints { entry_points: Vec<EntryPoint>, extra_entry_points: Extras }
impl EntryPoints { __ENTRIES__ }
const SUBGRAPH_CONNECTIVITY_SEARCH_BUDGET: usize = 64;
struct GraphLayersBuilder { links_layers: Vec<Vec<Lock<Links>>>, entry_points: Lock<EntryPoints> }
impl GraphLayersBuilder {
    fn get_point_level(&self, p: u32) -> usize { self.links_layers[p as usize].len() - 1 }
    __CONNECTIVITY__
}
fn next(it: &mut std::str::SplitWhitespace<'_>) -> usize { it.next().unwrap().parse().unwrap() }
fn main() {
    let text = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut it = text.split_whitespace();
    for case_id in 0..next(&mut it) {
        let n = next(&mut it); let np = next(&mut it); let ne = next(&mut it); let ns = next(&mut it);
        let mut rng = Random { state: next(&mut it) as u64 };
        let q = f32::from_bits(next(&mut it) as u32);
        let primary = (0..np).map(|_| EntryPoint { point_id: next(&mut it) as u32 }).collect();
        let extra = (0..ne).map(|_| EntryPoint { point_id: next(&mut it) as u32 }).collect();
        let points: Vec<_> = (0..ns).map(|_| next(&mut it) as u32).collect();
        let links_layers = (0..n).map(|_| (0..next(&mut it)).map(|_| {
            Lock(Links((0..next(&mut it)).map(|_| next(&mut it) as u32).collect()))
        }).collect()).collect();
        let graph = GraphLayersBuilder { links_layers, entry_points: Lock(EntryPoints { entry_points: primary, extra_entry_points: Extras(extra) }) };
        let score = graph.subgraph_connectivity(&mut rng, &points, q);
        println!("case {case_id} bits {} state {}", score.to_bits(), rng.state);
    }
    assert!(it.next().is_none());
}
'''


def fixtures() -> list[dict]:
    result = []
    for seed in range(128):
        rng = random.Random(seed)
        n = 16
        levels = [rng.randrange(3) for _ in range(n)]
        links = []
        for i in range(n):
            layers = []
            for layer in range(levels[i] + 1):
                candidates = [j for j in range(n) if j != i and levels[j] >= layer]
                layers.append(rng.sample(candidates, rng.randrange(min(8, len(candidates)) + 1)))
            links.append(layers)
        result.append(dict(levels=levels, links=links, primary=rng.sample(range(n), seed % 3),
                           extra=[] if seed % 2 else [15], points=rng.sample(range(n), seed % 17),
                           seed=seed, q=[0.0, 0.25, 0.5, 0.75, 1.0][seed % 5]))
    return result


def main() -> None:
    import struct
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    output = parser.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checkout = ROOT / "reference/qdrant-edge-0.8.0"
    source_hashes, methods = {}, {}
    for file, name in [("graph_layers_builder.rs", "subgraph_connectivity"), ("entry_points.rs", "get_random_entry_point")]:
        relative = f"lib/segment/src/index/hnsw_index/{file}"
        source = (checkout / relative).read_bytes()
        pinned = subprocess.check_output(["git", "-C", str(checkout), "show", f"{REVISION}:{relative}"])
        if source != pinned:
            raise ValueError(f"modified upstream: {relative}")
        source_hashes[relative] = hashlib.sha256(source).hexdigest()
        methods[name] = extract(source.decode(), name)
    rust = output / "reference.rs"
    rust.write_text(ADAPTER.replace("__ENTRIES__", methods["get_random_entry_point"]).replace("__CONNECTIVITY__", methods["subgraph_connectivity"]))
    cases = fixtures()
    data = output / "fixtures.json"
    data.write_text(json.dumps(cases, indent=2) + "\n")
    words = [len(cases)]
    for c in cases:
        words.extend([len(c["levels"]), len(c["primary"]), len(c["extra"]), len(c["points"]), c["seed"], struct.unpack("I", struct.pack("f", c["q"]))[0]])
        for key in ["primary", "extra", "points"]:
            words.extend(c[key])
        for layers in c["links"]:
            words.append(len(layers))
            for links in layers:
                words.extend([len(links), *links])
    text_input = output / "fixtures.txt"
    text_input.write_text(" ".join(map(str, words)) + "\n")
    executable = output / "reference"
    run(["rustc", "--edition=2021", str(rust), "-o", str(executable)], output, "rust-build")
    expected = run([str(executable), str(text_input)], output, "rust-run")
    actual = run(["pixi", "run", "mojo", "run", "-I", "src", "benchmarks/mojo/qdrant_connectivity_differential.mojo", str(data)], output, "mojo-run")
    expected_rows = [line for line in expected.splitlines() if line.startswith("case ")]
    actual_rows = [line for line in actual.splitlines() if line.startswith("case ")]
    failures = [{"case": i, "expected": a, "actual": b} for i, (a, b) in enumerate(zip(expected_rows, actual_rows)) if a != b]
    passed = len(expected_rows) == len(actual_rows) == len(cases) and not failures
    files = [Path(__file__), ROOT / "benchmarks/mojo/qdrant_connectivity_differential.mojo", ROOT / "src/akasha/index/hnsw_connectivity.mojo", ROOT / "src/akasha/index/hnsw_payload.mojo"]
    report = dict(status="PASSED" if passed else "FAILED", cases=len(cases), revision=REVISION,
                  upstream_sha256=source_hashes, method_sha256={k: hashlib.sha256(v.encode()).hexdigest() for k, v in methods.items()},
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
                  failures=failures, scope="Connectivity values and RNG consumption; shared deterministic RNG, no timings or full construction claim")
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
