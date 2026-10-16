"""Differential check of the Mojo port against extracted upstream Rust loops.

This compiles three unedited search methods from the pinned Qdrant checkout
with a small in-memory graph/scorer adapter. It does not build or time Edge.
Run with: pixi run python -m benchmarks.qdrant_search_reference --output <fresh-dir>
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys

REVISION = "21db2f3ff95d50de3a2b88a741312c056fd1762d"
ROOT = Path(__file__).resolve().parents[1]


def method(source: str, name: str) -> str:
    start = source.index(f"    fn {name}(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Only storage/scorer, queue plumbing, and fixture I/O are adapted. The three
# upstream traversal method bodies are inserted verbatim below this scaffold.
RUST_ADAPTER = r'''
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;
use std::sync::atomic::AtomicBool;
type PointOffsetType = u32;
type CancellableResult<T> = Result<T, &'static str>;
fn check_process_stopped(_: &AtomicBool) -> CancellableResult<()> { Ok(()) }
fn rev_range(top: usize, bottom: usize) -> impl Iterator<Item=usize> {
    ((bottom + 1)..=top).rev()
}
#[derive(Clone, Copy, Debug, PartialEq)]
struct ScoredPointOffset { idx: u32, score: f32 }
impl Eq for ScoredPointOffset {}
impl Ord for ScoredPointOffset {
    fn cmp(&self, other: &Self) -> Ordering { self.score.partial_cmp(&other.score).unwrap() }
}
impl PartialOrd for ScoredPointOffset {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.cmp(other)) }
}
struct FixedLengthPriorityQueue<T: Ord> { heap: BinaryHeap<Reverse<T>>, length: usize }
impl<T: Ord> FixedLengthPriorityQueue<T> {
    fn new(length: usize) -> Self { Self { heap: BinaryHeap::new(), length } }
    fn push(&mut self, value: T) -> Option<T> {
        if self.heap.len() < self.length { self.heap.push(Reverse(value)); return None; }
        let mut x = self.heap.peek_mut().unwrap();
        let mut value = Reverse(value);
        if x.0 < value.0 { std::mem::swap(&mut *x, &mut value); }
        Some(value.0)
    }
    fn top(&self) -> Option<&T> { self.heap.peek().map(|x| &x.0) }
}
struct SearchContext {
    nearest: FixedLengthPriorityQueue<ScoredPointOffset>,
    candidates: BinaryHeap<ScoredPointOffset>,
}
impl SearchContext {
    fn new(ef: usize) -> Self {
        Self { nearest: FixedLengthPriorityQueue::new(ef), candidates: BinaryHeap::new() }
    }
    fn lower_bound(&self) -> f32 { self.nearest.top().map_or(f32::MIN, |v| v.score) }
    fn process_candidate(&mut self, p: ScoredPointOffset) {
        let added = match self.nearest.push(p) { None => true, Some(v) => v.idx != p.idx };
        if added { self.candidates.push(p); }
    }
}
struct Visited { flags: Vec<bool> }
impl Visited {
    fn check(&self, id: u32) -> bool { self.flags[id as usize] }
    fn check_and_update_visited(&mut self, id: u32) -> bool {
        std::mem::replace(&mut self.flags[id as usize], true)
    }
}
struct FilteredScorer { values: Vec<f32>, allowed: Vec<bool>, calls: usize }
impl FilteredScorer {
    fn score_point(&mut self, id: u32) -> f32 {
        self.calls += 1; let x = self.values[id as usize]; -(x * x)
    }
    fn score_points(&mut self, ids: &mut Vec<u32>, limit: usize)
        -> std::vec::IntoIter<ScoredPointOffset> {
        ids.retain(|&id| self.allowed[id as usize]);
        if limit != 0 { ids.truncate(limit); }
        ids.iter().map(|&idx| ScoredPointOffset { idx, score: self.score_point(idx) })
            .collect::<Vec<_>>().into_iter()
    }
}
struct Graph { levels: Vec<usize>, links: Vec<Vec<Vec<u32>>>, m: usize, m0: usize }
impl Graph {
    fn get_m(&self, level: usize) -> usize { if level == 0 { self.m0 } else { self.m } }
    fn get_visited_list_from_pool(&self) -> Visited { Visited { flags: vec![false; self.levels.len()] } }
    fn for_each_link<F: FnMut(u32)>(&self, point: u32, level: usize, mut f: F) {
        for &link in &self.links[point as usize][level] { f(link); }
    }
    __UPSTREAM_METHODS__
}
fn next(it: &mut std::str::SplitWhitespace<'_>) -> usize { it.next().unwrap().parse().unwrap() }
fn main() {
    let text = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut it = text.split_whitespace();
    let cases = next(&mut it);
    for case_id in 0..cases {
        let n = next(&mut it); let m = next(&mut it); let m0 = next(&mut it);
        let k = next(&mut it); let ef = next(&mut it);
        let np = next(&mut it); let ne = next(&mut it);
        let values = (0..n).map(|_| next(&mut it) as f32).collect();
        let levels: Vec<_> = (0..n).map(|_| next(&mut it)).collect();
        let allowed: Vec<_> = (0..n).map(|_| next(&mut it) != 0).collect();
        let primary: Vec<_> = (0..np).map(|_| (next(&mut it) as u32, next(&mut it))).collect();
        let extra: Vec<_> = (0..ne).map(|_| (next(&mut it) as u32, next(&mut it))).collect();
        let links = levels.iter().map(|&l| (0..=l).map(|_| {
            let count = next(&mut it); (0..count).map(|_| next(&mut it) as u32).collect()
        }).collect()).collect();
        let graph = Graph { levels, links, m, m0 };
        let entry = primary.iter().find(|&&(p, _)| allowed[p as usize]).copied().or_else(||
            extra.iter().filter(|&&(p, _)| allowed[p as usize]).max_by_key(|&&(_, level)| level).copied());
        let mut scorer = FilteredScorer { values, allowed, calls: 0 };
        let mut ids = Vec::new();
        if k > 0 {
            if let Some(entry) = entry {
                let zero = graph.search_entry(entry.0, entry.1, 0, &mut scorer, &AtomicBool::new(false)).unwrap();
                let nearest = graph.search_on_level(zero, 0, ef.max(k), &mut scorer, &AtomicBool::new(false)).unwrap();
                ids = nearest.heap.into_sorted_vec().into_iter().take(k).map(|p| p.0.idx).collect();
            }
        }
        print!("case {case_id} distances {} ids", scorer.calls);
        for id in ids { print!(" {id}"); }
        println!();
    }
    assert!(it.next().is_none());
}
'''


def fixtures() -> list[dict]:
    result = []
    for seed in range(96):
        rng = random.Random(seed)
        n, m, m0 = 24, 4, 8
        values = list(range(1, n + 1))
        rng.shuffle(values)  # Distinct, exactly representable squared distances.
        levels = [rng.randrange(3) for _ in range(n)]
        links = []
        for i in range(n):
            layers = []
            for level in range(levels[i] + 1):
                candidates = [j for j in range(n) if j != i and levels[j] >= level]
                count = rng.randrange(min(len(candidates), m0 if level == 0 else m) + 1)
                layers.append(rng.sample(candidates, count))
            links.append(layers)
        selectivity = [0.0, 0.125, 0.25, 0.5, 1.0][seed % 5]
        result.append(dict(values=values, levels=levels, links=links, m=m, m0=m0,
                           allowed=[rng.random() < selectivity for _ in range(n)],
                           primary=[(i, levels[i]) for i in rng.sample(range(n), 2)],
                           extra=[(i, levels[i]) for i in rng.sample(range(n), 8)],
                           k=[0, 1, 3, 5][seed % 4], ef=[1, 4, 8, 16][(seed // 4) % 4]))
    # A payload component entry may be lower than its main-graph point.
    # Explicit fixture: descending level one would reach point 1 and change
    # both the answer and the distance-call count; the level-zero entry must not.
    result.append(dict(values=[8, 1, 7], levels=[1, 1, 0],
                       links=[[[2], [1]], [[], [0]], [[0]]],
                       m=2, m0=2, allowed=[True, True, True],
                       primary=[(0, 0)], extra=[], k=1, ef=3))
    result.append(dict(values=[8, 1, 7], levels=[1, 1, 0],
                       links=[[[2], [1]], [[], [0]], [[0]]],
                       m=2, m0=2, allowed=[True, True, True],
                       primary=[], extra=[(0, 0)], k=1, ef=3))
    return result


def run(command: list[str], output: Path, label: str) -> str:
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    (output / f"{label}.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode}); see {output / f'{label}.log'}")
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checkout = ROOT / "reference/qdrant-edge-0.8.0"
    head = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if head != REVISION:
        raise ValueError(f"expected upstream {REVISION}, found {head}")
    source_path = checkout / "lib/segment/src/index/hnsw_index/graph_layers.rs"
    upstream = source_path.read_text()
    pinned = subprocess.check_output(["git", "-C", str(checkout), "show", f"{REVISION}:lib/segment/src/index/hnsw_index/graph_layers.rs"])
    if upstream.encode() != pinned:
        raise ValueError("upstream graph_layers.rs has local edits")
    names = ["search_on_level", "search_entry", "search_entry_on_level"]
    methods = "\n".join(method(upstream, name) for name in names)
    rust = output / "reference.rs"
    rust.write_text(RUST_ADAPTER.replace("__UPSTREAM_METHODS__", methods))
    cases = fixtures()
    data = output / "fixtures.json"
    data.write_text(json.dumps(cases, indent=2) + "\n")
    words = [len(cases)]
    for c in cases:
        words.extend([len(c["values"]), c["m"], c["m0"], c["k"], c["ef"], len(c["primary"]), len(c["extra"])])
        for key in ["values", "levels", "allowed"]:
            words.extend(int(v) for v in c[key])
        for key in ["primary", "extra"]:
            for entry in c[key]:
                words.extend(entry)
        for layers in c["links"]:
            for links in layers:
                words.extend([len(links), *links])
    text_input = output / "fixtures.txt"
    text_input.write_text(" ".join(map(str, words)) + "\n")
    executable = output / "reference"
    run(["rustc", "--edition=2021", str(rust), "-o", str(executable)], output, "rust-build")
    expected = run([str(executable), str(text_input)], output, "rust-run")
    actual = run(["pixi", "run", "mojo", "run", "-I", "src", "benchmarks/mojo/qdrant_search_differential.mojo", str(data)], output, "mojo-run")
    expected_rows = [line for line in expected.splitlines() if line.startswith("case ")]
    actual_rows = [line for line in actual.splitlines() if line.startswith("case ")]
    batched_rows = [line.removeprefix("batched ") for line in actual.splitlines() if line.startswith("batched case ")]
    if len(expected_rows) != len(cases) or expected_rows != actual_rows:
        raise AssertionError("Mojo / upstream Rust traversal results or distance counts differ")
    if expected_rows != batched_rows:
        raise AssertionError("Batched Mojo / upstream Rust traversal results or distance counts differ")
    inputs = [Path(__file__), ROOT / "benchmarks/mojo/qdrant_search_reference.mojo",
              ROOT / "benchmarks/mojo/qdrant_search_differential.mojo",
              ROOT / "benchmarks/mojo/test_qdrant_search_reference.mojo"]
    inputs.extend(sorted((ROOT / "src/akasha/index").glob("hnsw*.mojo")))
    summary = dict(status="PASSED", cases=len(cases), scoring_paths=["scalar", "batched-f32"], revision=REVISION,
                   upstream_sha256=hashlib.sha256(pinned).hexdigest(),
                   extracted_methods=names,
                   methods_sha256=hashlib.sha256(methods.encode()).hexdigest(),
                   source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                   python_version=sys.version,
                   rust_version=subprocess.check_output(["rustc", "--version"], text=True).strip(),
                   mojo_version=subprocess.check_output(["pixi", "run", "mojo", "--version"], text=True).strip(),
                   scope="Production single-entry descent/beam primitives on distinct-score fixtures; excludes multi-entry query seed reuse, Edge binary, graph build, timing and production acceptance")
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
