"""Compare complete serial HNSW construction against pinned Qdrant methods.

Use identical explicit point levels and distinct integer L2 scores. Storage,
locks and raw scoring are adapters; link selection and traversal are upstream.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
from benchmarks.qdrant_search_reference import ROOT, REVISION, RUST_ADAPTER, run


def method(source: str, name: str) -> str:
    match = re.search(r"    (?:pub )?fn " + name + r"[<(]", source)
    if match is None:
        raise ValueError(name)
    opening = source.index("{", match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


BASE = RUST_ADAPTER[:RUST_ADAPTER.index("struct FilteredScorer")]
BASE = BASE.replace("    fn top(&self)", "    fn iter_unsorted(&self) -> impl Iterator<Item=&T> { self.heap.iter().map(|p| &p.0) }\n    fn into_iter_sorted(self) -> impl Iterator<Item=T> { self.heap.into_sorted_vec().into_iter().map(|p| p.0) }\n    fn top(&self)")
ADAPTER = r'''
use std::cmp::min;
use std::cell::{Cell, RefCell, Ref, RefMut};
use std::rc::Rc;
type ScoreType = f32;
struct Lock<T>(RefCell<T>);
impl<T> Lock<T> {
    fn new(value: T) -> Self { Self(RefCell::new(value)) }
    fn lock(&self) -> RefMut<'_, T> { self.0.borrow_mut() }
    fn read(&self) -> Ref<'_, T> { self.0.borrow() }
    fn write(&self) -> RefMut<'_, T> { self.0.borrow_mut() }
}
struct Ready(Vec<Cell<bool>>);
impl Ready { fn set_aliased(&self, i: usize, value: bool) { self.0[i].set(value); } }
impl std::ops::Index<usize> for Ready { type Output=bool; fn index(&self, i: usize) -> &bool { if self.0[i].get() { &true } else { &false } } }
#[derive(Clone, Eq, PartialEq)] struct EntryPoint { point_id: u32, level: usize }
impl Ord for EntryPoint { fn cmp(&self, other: &Self) -> Ordering { self.level.cmp(&other.level) } }
impl PartialOrd for EntryPoint { fn partial_cmp(&self, other: &Self) -> Option<Ordering> { Some(self.cmp(other)) } }
struct EntryPoints { entry_points: Vec<EntryPoint>, extra_entry_points: FixedLengthPriorityQueue<EntryPoint> }
impl EntryPoints { __ENTRY_METHODS__ }
struct Degree { m: usize, m0: usize }
impl Degree { fn level_m(&self, level: usize) -> usize { if level == 0 { self.m0 } else { self.m } } }
struct FilteredScorer { query: u32, vectors: Rc<Vec<Vec<f32>>>, ready: Rc<Ready> }
impl FilteredScorer {
    fn filters(&self) -> &Self { self }
    fn check_vector(&self, id: u32) -> bool { self.ready[id as usize] }
    fn score_internal(&self, a: u32, b: u32) -> f32 {
        -self.vectors[a as usize].iter().zip(&self.vectors[b as usize]).map(|(a,b)| { let d=a-b; d*d }).sum::<f32>()
    }
    fn score_point(&self, id: u32) -> f32 { self.score_internal(self.query, id) }
    fn score_points(&self, ids: &mut Vec<u32>, limit: usize) -> std::vec::IntoIter<ScoredPointOffset> {
        ids.retain(|&id| self.check_vector(id));
        if limit != 0 { ids.truncate(limit); }
        ids.iter().map(|&idx| ScoredPointOffset { idx, score: self.score_point(idx) }).collect::<Vec<_>>().into_iter()
    }
}
trait Capacity { fn try_set_capacity_exact(&mut self, n: usize) -> Result<(), &'static str>; }
impl<T> Capacity for Vec<T> { fn try_set_capacity_exact(&mut self, n: usize) -> Result<(), &'static str> { if n > self.capacity() { self.reserve_exact(n-self.len()); } Ok(()) } }
mod links {
    use super::{PointOffsetType, ScoreType, ScoredPointOffset, Capacity};
    __LINKS__
}
use links::{LinksContainer, ItemsBuffer};
struct GraphLayersBuilder {
    links_layers: Vec<Vec<Lock<LinksContainer>>>, entry_points: Lock<EntryPoints>,
    ready_list: Rc<Ready>, ef_construct: usize, hnsw_m: Degree, use_heuristic: bool,
}
impl GraphLayersBuilder {
    fn get_point_level(&self, p: u32) -> usize { self.links_layers[p as usize].len() - 1 }
    fn get_m(&self, level: usize) -> usize { self.hnsw_m.level_m(level) }
    fn get_visited_list_from_pool(&self) -> Visited { Visited { flags: vec![false; self.links_layers.len()] } }
    fn for_each_link<F: FnMut(u32)>(&self, point: u32, level: usize, mut f: F) {
        for link in self.links_layers[point as usize][level].read().iter() { f(link); }
    }
    fn link_without_heuristic(&self, _: u32, _: usize, _: &FilteredScorer, _: FixedLengthPriorityQueue<ScoredPointOffset>) { panic!("heuristic required") }
    __SEARCH_METHODS__
    __BUILD_METHODS__
}
fn next(it: &mut std::str::SplitWhitespace<'_>) -> usize { it.next().unwrap().parse().unwrap() }
fn main() {
    let text = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let mut it = text.split_whitespace();
    for case_id in 0..next(&mut it) {
        let n = next(&mut it); let dim = next(&mut it); let m = next(&mut it); let m0 = next(&mut it); let ef = next(&mut it);
        let levels: Vec<_> = (0..n).map(|_| next(&mut it)).collect();
        let vectors = Rc::new((0..n).map(|_| (0..dim).map(|_| next(&mut it) as f32).collect::<Vec<_>>()).collect::<Vec<_>>());
        let ready_list = Rc::new(Ready((0..n).map(|_| Cell::new(false)).collect()));
        let graph = GraphLayersBuilder {
            links_layers: levels.iter().map(|&top| (0..=top).map(|l| Lock::new(LinksContainer::with_capacity(if l == 0 { m0 } else { m }))).collect()).collect(),
            entry_points: Lock::new(EntryPoints { entry_points: vec![], extra_entry_points: FixedLengthPriorityQueue::new(80) }),
            ready_list: ready_list.clone(), ef_construct: ef, hnsw_m: Degree { m, m0 }, use_heuristic: true,
        };
        for id in 0..n {
            graph.link_new_point(id as u32, FilteredScorer { query: id as u32, vectors: vectors.clone(), ready: ready_list.clone() });
        }
        for (id, layers) in graph.links_layers.iter().enumerate() {
            for (level, links) in layers.iter().enumerate() {
                print!("case {case_id} slot {id} level {level} links");
                for link in links.read().iter() { print!(" {link}"); }
                println!();
            }
        }
    }
    assert!(it.next().is_none());
}
'''


def fixtures() -> list[dict]:
    result = []
    for seed in range(24):
        rng = random.Random(seed)
        n, dim = 48, 4
        # Avoid tie-order adapters and all floating-point rounding ambiguity.
        while True:
            vectors = [[rng.randrange(1024) for _ in range(dim)] for _ in range(n)]
            distances = [sum((a-b)**2 for a,b in zip(vectors[i], vectors[j])) for i in range(n) for j in range(i)]
            if len(set(distances)) == len(distances):
                break
        m = [2, 4, 8][seed % 3]
        levels = [rng.randrange(4) for _ in range(n)] if seed % 4 else [0] * n
        result.append(dict(vectors=vectors, levels=levels, m=m, m0=m*2, ef=[16,32,64][seed % 3]))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    output = parser.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checkout = ROOT / "reference/qdrant-edge-0.8.0"
    sources, hashes = {}, {}
    for file in ["graph_layers.rs", "graph_layers_builder.rs", "entry_points.rs", "links_container.rs"]:
        relative = f"lib/segment/src/index/hnsw_index/{file}"
        raw = (checkout/relative).read_bytes()
        pinned = subprocess.check_output(["git", "-C", str(checkout), "show", f"{REVISION}:{relative}"])
        if raw != pinned: raise ValueError(f"modified upstream: {relative}")
        hashes[relative] = hashlib.sha256(raw).hexdigest()
        sources[file] = raw.decode()
    selections = {
        "SEARCH_METHODS": ("graph_layers.rs", ["search_on_level", "search_entry", "search_entry_on_level"]),
        "BUILD_METHODS": ("graph_layers_builder.rs", ["link_new_point", "link_new_point_on_level", "link_with_heuristic"]),
        "ENTRY_METHODS": ("entry_points.rs", ["new_point", "get_entry_point"]),
    }
    adapter = BASE + ADAPTER
    method_hashes = {}
    for marker, (file, names) in selections.items():
        snippets = [method(sources[file], name) for name in names]
        adapter = adapter.replace(f"__{marker}__", "\n".join(snippets))
        method_hashes.update({name: hashlib.sha256(code.encode()).hexdigest() for name,code in zip(names,snippets)})
    links = sources["links_container.rs"].split("\n#[cfg(test)]\nmod tests",1)[0]
    links = links.replace("use common::types::{PointOffsetType, ScoreType, ScoredPointOffset};", "").replace("use crate::common::vector_utils::TrySetCapacityExact as _;", "")
    adapter = adapter.replace("__LINKS__", links)
    rust = output/"reference.rs"; rust.write_text(adapter)
    cases = fixtures()
    data = output/"fixtures.json"; data.write_text(json.dumps(cases,indent=2)+"\n")
    words = [len(cases)]
    for c in cases:
        words.extend([len(c["vectors"]), len(c["vectors"][0]), c["m"], c["m0"], c["ef"], *c["levels"]])
        for row in c["vectors"]: words.extend(row)
    text_input=output/"fixtures.txt";text_input.write_text(" ".join(map(str,words))+"\n")
    executable=output/"reference"
    run(["rustc","--edition=2021",str(rust),"-o",str(executable)],output,"rust-build")
    expected=run([str(executable),str(text_input)],output,"rust-run")
    actual=run(["pixi","run","mojo","run","-I","src","benchmarks/mojo/qdrant_build_differential.mojo",str(data)],output,"mojo-run")
    a=[line for line in expected.splitlines() if line.startswith("case ")]
    b=[line for line in actual.splitlines() if line.startswith("case ")]
    failures=[{"expected":x,"actual":y} for x,y in zip(a,b) if x!=y]
    passed=len(a)==len(b)==sum(level+1 for c in cases for level in c["levels"]) and not failures
    files=[Path(__file__),ROOT/"benchmarks/mojo/qdrant_build_differential.mojo",*sorted((ROOT/"src/akasha/index").glob("hnsw*.mojo"))]
    report=dict(status="PASSED" if passed else "FAILED",cases=len(cases),adjacency_rows=len(a),failures=failures,revision=REVISION,
                upstream_sha256=hashes,method_sha256=method_hashes,
                source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
                scope="Complete serial L2 construction with explicit levels and no score ties; ordered links compared, no timing claim")
    (output/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({k:v for k,v in report.items() if k!='failures'},indent=2));print("mismatched rows:",len(failures))
    if not passed: raise SystemExit(1)


if __name__ == "__main__": main()
