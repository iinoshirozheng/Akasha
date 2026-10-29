"""Run pinned, unedited Qdrant sparse search methods with native-free shims.

The posting iterator has no reliable suffix maxima, so the source non-pruning
path runs. Fixtures distinguish indexed batches, the final posting, and plain
search; recommendation transforms/reducers have their own existing Rust oracle.
"""
from __future__ import annotations

import hashlib
import argparse
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nearest", action="store_true", help="Add ordinary nearest overflow/TopK fixtures without changing the recommendation fixture")
    args = parser.parse_args()
    sources = {}
    functions = {}

    def source(path):
        text = subprocess.check_output(
            ["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
             "show", f"{REVISION}:{path}"], text=True,
        )
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    path = "lib/sparse/src/index/search_context.rs"
    context = source(path)
    methods = []
    for name, signature in [
        ("plain_search", "pub fn plain_search("),
        ("advance_batch", "fn advance_batch<"),
        ("process_last_posting_list", "fn process_last_posting_list<"),
        ("next_min_id", "fn next_min_id("),
        ("promote_longest", "pub(crate) fn promote_longest_posting_lists_to_the_front("),
        ("search", "pub fn search<"),
        ("prune_longest", "pub fn prune_longest_posting_list("),
    ]:
        body = extract(context, signature)
        functions[name] = dict(source=path, signature=signature,
                               sha256=hashlib.sha256(body.encode()).hexdigest())
        methods.append(body)
    path = "lib/sparse/src/common/sparse_vector.rs"
    scoring = extract(source(path), "pub fn score_vectors<T: Ord + Eq>(")
    functions["score_vectors"] = dict(source=path, signature="pub fn score_vectors<T: Ord + Eq>(",
                                      sha256=hashlib.sha256(scoring.encode()).hexdigest())
    topk = source("lib/common/common/src/top_k.rs").split("#[cfg(test)]")[0]
    source("lib/segment/src/index/sparse_index/sparse_vector_index/read_view/search.rs")
    source("lib/segment/src/index/sparse_index/sparse_vector_index/vector_index_impl.rs")
    source("lib/segment/src/types.rs")
    if args.nearest:
        source("lib/collection/src/shards/local_shard/query.rs")

    scaffold = r'''
use std::cmp::{Ordering, min, max};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::collections::BTreeMap;
mod ordered_float {
    pub trait Float { fn min_value() -> Self; }
    impl Float for f32 { fn min_value() -> Self { f32::MIN } }
}
mod types {
    pub type ScoreType = f32;
    #[derive(Clone, Copy, Debug)] pub struct ScoredPointOffset { pub score: f32, pub idx: u32 }
    impl PartialEq for ScoredPointOffset { fn eq(&self, other: &Self) -> bool { self.cmp(other).is_eq() } }
    impl Eq for ScoredPointOffset {}
    impl PartialOrd for ScoredPointOffset { fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(other)) } }
    impl Ord for ScoredPointOffset { fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (if self.score == other.score { std::cmp::Ordering::Equal } else { self.score.total_cmp(&other.score) })
            .then_with(|| other.idx.cmp(&self.idx))
    }}
}
__TOPK__
type PointOffsetType = u32;
type DimWeight = f32;
const ADVANCE_BATCH_SIZE: usize = 10_000;
struct Counter;
impl Counter { fn cpu_counter(&self) -> &Self { self } fn incr_delta(&self, _: usize) {} }
#[derive(Clone, Copy)] struct Element { record_id: u32, weight: f32, max_next_weight: f32 }
trait PostingListIter {
    fn peek(&self) -> Option<Element>;
    fn skip_to(&mut self, id: u32) -> Option<Element>;
    fn skip_to_end(&mut self);
    fn current_index(&self) -> usize;
    fn len_to_end(&self) -> usize;
    fn element_size(&self) -> usize;
    fn for_each_till_id<S: ?Sized, F: FnMut(&mut S, u32, f32)>(&mut self, last: u32, state: &mut S, f: F);
}
struct Posting { rows: Vec<Element>, cursor: usize }
impl PostingListIter for Posting {
    fn peek(&self) -> Option<Element> { self.rows.get(self.cursor).copied() }
    fn skip_to(&mut self, id: u32) -> Option<Element> {
        self.cursor += self.rows[self.cursor..].partition_point(|p| p.record_id < id);
        self.peek().filter(|p| p.record_id == id)
    }
    fn skip_to_end(&mut self) { self.cursor = self.rows.len(); }
    fn current_index(&self) -> usize { self.cursor }
    fn len_to_end(&self) -> usize { self.rows.len() - self.cursor }
    fn element_size(&self) -> usize { size_of::<Element>() }
    fn for_each_till_id<S: ?Sized, F: FnMut(&mut S, u32, f32)>(&mut self, last: u32, state: &mut S, mut f: F) {
        while let Some(p) = self.peek() {
            if p.record_id > last { break; }
            f(state, p.record_id, p.weight); self.cursor += 1;
        }
    }
}
struct SparseVector { indices: Vec<u32>, values: Vec<f32> }
struct IndexedPostingListIterator<T> { posting_list_iterator: T, query_index: u32, query_weight: f32 }
struct SearchContext<T> {
    postings_iterators: Vec<IndexedPostingListIterator<T>>, query: SparseVector, top: usize,
    is_stopped: AtomicBool, top_results: TopK, min_record_id: Option<u32>, max_record_id: u32,
    scores: Vec<f32>, use_pruning: bool, hardware_counter: Counter,
}
__SCORING__
impl<T: PostingListIter> SearchContext<T> {
    const DEFAULT_SCORE: f32 = 0.0;
    __METHODS__
}
fn parse_vector(raw: &str) -> SparseVector {
    let mut v = SparseVector { indices: vec![], values: vec![] };
    if raw != "-" { for pair in raw.split(',') {
        let (index, value) = pair.split_once(':').unwrap();
        v.indices.push(index.parse().unwrap()); v.values.push(f32::from_bits(value.parse().unwrap()));
    }} v
}
fn main() {
    let input = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    for line in input.lines() {
        let columns: Vec<_> = line.split('|').collect();
        let size: usize = columns[1].parse().unwrap(); let k: usize = columns[2].parse().unwrap();
        let query = parse_vector(columns[3]);
        let allowed: Vec<u32> = if columns[4] == "all" { (0..size as u32).collect() }
            else if columns[4] == "-" { vec![] } else { columns[4].split(',').map(|x| x.parse().unwrap()).collect() };
        let mut posting_map: BTreeMap<u32, Vec<Element>> = BTreeMap::new();
        if columns[5] != "-" { for point in columns[5].split(';') {
            let (id, raw) = point.split_once('=').unwrap(); let id: u32 = id.parse().unwrap();
            let vector = parse_vector(raw);
            for (term, weight) in vector.indices.into_iter().zip(vector.values) {
                posting_map.entry(term).or_default().push(Element { record_id: id, weight, max_next_weight: f32::MIN });
            }
        }}
        let mut cursors = vec![]; let mut first = None; let mut last = 0;
        for (&term, &weight) in query.indices.iter().zip(&query.values) {
            if let Some(mut rows) = posting_map.remove(&term) {
                rows.sort_by_key(|p| p.record_id);
                first = Some(first.map_or(rows[0].record_id, |old: u32| old.min(rows[0].record_id)));
                last = last.max(rows.last().unwrap().record_id);
                cursors.push(IndexedPostingListIterator { posting_list_iterator: Posting { rows, cursor: 0 }, query_index: term, query_weight: weight });
            }
        }
        let mut context = SearchContext { postings_iterators: cursors, query, top: k,
            is_stopped: AtomicBool::new(false), top_results: TopK::new(k), min_record_id: first,
            max_record_id: last, scores: vec![], use_pruning: false, hardware_counter: Counter };
        let mut hits = if columns[0] == "plain" { context.plain_search(&allowed) }
            else { context.search(&|id| allowed.binary_search(&id).is_ok()) };
        hits.sort_by(|a, b| (if a.score == b.score { Ordering::Equal } else { b.score.total_cmp(&a.score) }).then_with(|| a.idx.cmp(&b.idx)));
        println!("{}", hits.iter().map(|h| format!("{}:{}", h.idx, h.score.to_bits())).collect::<Vec<_>>().join(","));
    }
}
'''.replace("__TOPK__", topk).replace("__SCORING__", scoring).replace("__METHODS__", "\n\n".join(methods))
    cases = []

    def add(name, size, points, query, allowed=None, k=None):
        for mode in ("plain", "indexed"):
            cases.append(dict(name=name, mode=mode, size=size, points=points, query=query,
                              allowed=allowed, k=min(size, 64) if k is None else k))

    add("empty_query", 4, {0: [[1, 2]]}, [])
    add("empty_postings", 4, {0: [[7, 2]]}, [[1, 2]])
    add("zero_cancellation_and_no_overlap", 6,
        {0: [[1, 1], [2, -1]], 1: [[1, -2]], 2: [[1, 0]], 3: [[9, 4]], 5: [[2, 3]]}, [[1, 1], [2, 1]])
    add("zero_query_weight", 3, {0: [[1, 2]], 1: [[1, -2]], 2: [[9, 3]]}, [[1, 0]])
    add("filtered_zero", 4, {0: [[1, 1], [2, -1]], 1: [[1, 9]], 2: [[2, -3]]}, [[1, 1], [2, 1]], [0, 2, 3])
    add("last_posting_zero_tail", 10005, {0: [[1, 2], [2, 1]], 10001: [[1, 0]], 10004: [[1, -2]]}, [[1, 1], [2, 1]])
    add("last_posting_signed_zero", 10003, {0: [[1, -1], [2, 1]], 10001: [[1, 0.0]], 10002: [[1, -0.0]]}, [[1, -1], [2, 1]])
    add("two_postings_zero_next_batch", 10005,
        {0: [[1, 1], [2, 1]], 10001: [[1, 1], [2, -1]], 10004: [[1, -2], [2, 0]]}, [[1, 1], [2, 1]])
    add("nonzero_start_boundary", 20009, {7: [[1, 1], [2, 2]], 10008: [[1, 0]], 20008: [[1, 4]]}, [[1, 1], [2, 1]])
    rng = random.Random(20261030)
    for index in range(48):
        size = rng.choice([7, 17, 39])
        points = {row: [[term, rng.choice([-4, -2, -1, 0, 1, 3, 5])] for term in range(7) if rng.random() < 0.4]
                  for row in range(size)}
        query = [[term, rng.choice([-2, -1, 0, 1, 2])] for term in range(8) if rng.random() < 0.5]
        allowed = None if index % 2 else [row for row in range(size) if rng.random() < 0.6]
        add(f"random_{index}", size, points, query, allowed)

    transforms_path = ROOT / "tests/fixtures/qdrant-recommendation/recommendation.json"
    transforms = json.loads(transforms_path.read_text())
    for index, sample in enumerate(transforms["cases"]):
        if sample["kind"] != "sparse" or sample["strategy"] != "average_vector" or "expected" not in sample:
            continue
        query = []
        for pair in sample["average_bits"].split(","):
            if not pair:
                continue
            term, value = map(int, pair.split(":"))
            query.append([term, struct.unpack("<f", struct.pack("<I", value))[0]])
        add(f"pipeline_{index}", len(sample["candidates"]), dict(enumerate(sample["candidates"])), query)

    if args.nearest:
        add("rounded_products_cancel", 2, {0: [[1, 1.0000001192092896], [2, -1.0000001192092896]]}, [[1, 0.9999998807907104], [2, 0.9999998807907104]])
        add("overflow_admission", 6, {
            0: [[1, 3e38], [2, -3e38]], 1: [[1, 3e38]],
            2: [[1, -3e38]], 3: [[1, 1]], 4: [[9, 1]],
        }, [[1, 3e38], [2, 3e38]])
        add("minimum_threshold", 4, {0: [[1, -3.4028234663852886e38]], 1: [[1, -3e38]], 2: [[1, 0]]}, [[1, 1]])
        add("filtered_overflow", 4, {0: [[1, 3e38]], 1: [[1, -3e38]], 2: [[1, 1]]}, [[1, 3e38]], [2, 3])
        add("last_posting_overflow", 10005, {0: [[1, 1], [2, 1]], 10001: [[1, 3e38]], 10002: [[1, -3e38]], 10004: [[1, 0]]}, [[1, 2], [2, 1]])
        add("bounded_topk", 101, {row: [[1, row-50]] for row in range(101)}, [[1, 1]], k=5)
        for index in range(32):
            points = {row: [[term, rng.uniform(-8, 8)] for term in range(11) if rng.random() < 0.6] for row in range(19)}
            query = [[term, rng.uniform(-8, 8)] for term in range(11)]
            add(f"fractional_{index}", 19, points, query)

    def encode(vector):
        return ",".join(f"{term}:{bits(value)}" for term, value in vector) or "-"

    inputs = []
    for case in cases:
        allowed = "all" if case["allowed"] is None else ",".join(map(str, case["allowed"])) or "-"
        points = ";".join(f"{row}={encode(vector)}" for row, vector in sorted(case["points"].items())) or "-"
        inputs.append(f"{case['mode']}|{case['size']}|{case['k']}|{encode(case['query'])}|{allowed}|{points}")
    build = ROOT / ".build/qdrant-sparse-recommendation-reference"
    build.mkdir(parents=True, exist_ok=True)
    rust = build / "reference.rs"; rust.write_text(scaffold)
    data = build / "inputs.txt"; data.write_text("\n".join(inputs) + "\n")
    binary = build / "reference"
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2021", str(rust), "-o", str(binary)], check=True)
    output = subprocess.check_output(["rtk", "proxy", str(binary), str(data)], text=True).splitlines()
    assert len(output) == len(cases)
    for case, line in zip(cases, output):
        case["expected"] = [list(map(int, row.split(":"))) for row in line.split(",")] if line else []
    fixture = dict(upstream="https://github.com/qdrant/qdrant", revision=REVISION,
                   sources=sources, functions=functions, topk_sha256=hashlib.sha256(topk.encode()).hexdigest(),
                   scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(),
                   adapter="Owned postings/counters and deterministic ID ties; original search methods and TopK; source use_pruning=false; no server/IDF/planner oracle",
                   transforms_fixture=str(transforms_path.relative_to(ROOT)),
                   transforms_fixture_sha256=hashlib.sha256(transforms_path.read_bytes()).hexdigest(),
                   cases=cases)
    target = ROOT / ("tests/fixtures/qdrant-sparse-nearest/search.json" if args.nearest else "tests/fixtures/qdrant-recommendation/sparse-search.json")
    target.parent.mkdir(parents=True, exist_ok=True)
    metadata = {key: value for key, value in fixture.items() if key != "cases"}
    target.write_text(json.dumps(metadata, indent=2)[:-2] + ',\n  "cases": [\n' +
                      ',\n'.join('    ' + json.dumps(case, separators=(',', ':')) for case in cases) + '\n  ]\n}\n')
    # Check compact formatting, especially empty output rows.
    assert json.loads(target.read_text())["cases"] == json.loads(json.dumps(cases))
    print(json.dumps(dict(cases=len(cases), functions=len(functions), fixture=str(target.relative_to(ROOT)))))


if __name__ == "__main__":
    main()
