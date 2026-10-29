"""Run the pinned, unedited Qdrant planner with opaque type/transport adapters.

This verifies planning, not server/protocol or multi-shard execution. Vector
contents and filter clauses are labels; filter conjunction is represented by
an ordered label list. Scoring is covered by the separate scorer oracles.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"

SCAFFOLD = r'''
type ScoreType = f32;
#[derive(Clone, Debug, PartialEq)] struct OrderedFloat<T>(T);
impl<T> OrderedFloat<T> { fn into_inner(self) -> T { self.0 } }
#[derive(Debug)] struct OperationError(String);
impl OperationError { fn validation_error(s: String) -> Self { Self(s) } }
type OperationResult<T> = Result<T, OperationError>;
#[derive(Clone, Debug, PartialEq)] struct Filter(Vec<usize>);
impl Filter {
    fn merge_opts(a: Option<Self>, b: Option<Self>) -> Option<Self> {
        match (a,b) { (None,b) => b, (a,None) => a, (Some(mut a),Some(b)) => { a.0.extend(b.0); Some(a) } }
    }
}
#[derive(Clone, Debug, PartialEq)] struct SearchParams;
#[derive(Clone, Debug, PartialEq)] struct WithVector(bool);
impl WithVector { fn merge(&self, other: &Self) -> Self { Self(self.0 || other.0) } }
impl From<bool> for WithVector { fn from(b: bool) -> Self { Self(b) } }
impl From<String> for WithVector { fn from(_: String) -> Self { Self(true) } }
#[derive(Clone, Debug, PartialEq)] struct WithPayloadInterface(bool);
impl From<bool> for WithPayloadInterface { fn from(b: bool) -> Self { Self(b) } }
#[derive(Clone, Debug, PartialEq)] struct NamedQuery { vector: usize, using: String }
impl NamedQuery { fn new(vector: usize, using: impl AsRef<str>) -> Self { Self { vector, using: using.as_ref().into() } } }
#[derive(Clone, Debug, PartialEq)] enum QueryEnum { Nearest(NamedQuery) }
#[derive(Clone, Debug, PartialEq)] enum FusionInternal { Rrf { k: usize, weights: Option<Vec<f32>> }, Dbsf }
#[derive(Clone, Debug, PartialEq)] enum SampleInternal { Random }
#[derive(Clone, Debug, PartialEq)] struct MmrInternal { vector: usize, using: String, lambda: f32, candidates_limit: usize }
#[derive(Clone, Debug, PartialEq)] enum ScoringQuery {
    Vector(QueryEnum), Fusion(FusionInternal), Mmr(MmrInternal), OrderBy(()), Formula(()), Sample(SampleInternal)
}
#[derive(Debug, Default)] enum ScrollOrder { #[default] ById, ByField(()), Random }
#[derive(Debug)] struct QueryScrollRequestInternal {
    scroll_order: ScrollOrder, filter: Option<Filter>, with_vector: WithVector,
    with_payload: WithPayloadInterface, limit: usize
}
#[derive(Debug)] struct CoreSearchRequest {
    query: QueryEnum, filter: Option<Filter>, params: Option<SearchParams>, limit: usize,
    offset: usize, with_vector: Option<WithVector>, with_payload: Option<WithPayloadInterface>, score_threshold: Option<f32>
}
struct ShardPrefetch { prefetches: Vec<ShardPrefetch>, query: Option<ScoringQuery>, limit: usize,
    params: Option<SearchParams>, filter: Option<Filter>, score_threshold: Option<OrderedFloat<f32>> }
struct ShardQueryRequest { prefetches: Vec<ShardPrefetch>, query: Option<ScoringQuery>, limit: usize,
    offset: usize, params: Option<SearchParams>, filter: Option<Filter>, score_threshold: Option<OrderedFloat<f32>>,
    with_vector: WithVector, with_payload: WithPayloadInterface }
'''

DRIVER = r'''
struct Input { kind: usize, limit: usize, offset: usize, candidates: usize, filter: bool, children: Vec<usize> }
fn query(n: &Input, id: usize) -> Option<ScoringQuery> {
    Some(match n.kind {
        0 => ScoringQuery::Vector(QueryEnum::Nearest(NamedQuery::new(id, "v"))),
        1 => ScoringQuery::Fusion(FusionInternal::Rrf { k: 2, weights: None }),
        2 => ScoringQuery::Fusion(FusionInternal::Dbsf),
        3 => ScoringQuery::Mmr(MmrInternal { vector: id, using: "v".into(), lambda: 0.5, candidates_limit: n.candidates }),
        _ => return None,
    })
}
fn prefetch(nodes: &[Input], i: usize) -> ShardPrefetch {
    let n = &nodes[i];
    ShardPrefetch { prefetches: n.children.iter().map(|&j| prefetch(nodes,j)).collect(), query: query(n,i),
        limit: n.limit, params: None, filter: n.filter.then(|| Filter(vec![i])), score_threshold: None }
}
fn leaf(source: &Source, plan: &PlannedQuery) -> (usize, Vec<usize>) {
    match source {
        Source::SearchesIdx(i) => (plan.searches[*i].limit, plan.searches[*i].filter.as_ref().map(|x| x.0.clone()).unwrap_or_default()),
        Source::ScrollsIdx(i) => (plan.scrolls[*i].limit, plan.scrolls[*i].filter.as_ref().map(|x| x.0.clone()).unwrap_or_default()),
        _ => panic!("expected leaf"),
    }
}
fn describe(merge: &MergePlan, plan: &PlannedQuery, nodes: &[Input], id: usize, rows: &mut Vec<String>) {
    let n = &nodes[id];
    let (mut retrieval, mut filters) = (0, vec![]);
    if n.children.is_empty() { (retrieval, filters) = leaf(&merge.sources[0], plan); }
    let (mut mmr, mut nearest) = (false, false);
    if let Some(stages) = &merge.rescore_stages {
        for stage in [&stages.shard_level, &stages.collection_level].into_iter().flatten() {
            match &stage.rescore {
                ScoringQuery::Mmr(_) => mmr = true,
                ScoringQuery::Vector(_) => { retrieval = stage.limit; nearest = n.kind == 3; },
                _ => {},
            }
        }
    }
    rows.push(format!("{} {} {} {} {}", id, retrieval, mmr as u8, nearest as u8,
        if filters.is_empty() { "-".into() } else { filters.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",") }));
    for (child, source) in n.children.iter().zip(&merge.sources) {
        match source {
            Source::Prefetch(inner) => describe(inner,plan,nodes,*child,rows),
            _ => {
                let (limit, filters) = leaf(source,plan);
                rows.push(format!("{} {} 0 0 {}", child, limit,
                    if filters.is_empty() { "-".into() } else { filters.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",") }));
            },
        }
    }
}
fn main() {
    let input = std::env::args().nth(1).unwrap();
    let nodes: Vec<_> = input.split(';').map(|row| {
        let v: Vec<_> = row.split('|').collect();
        Input { kind:v[0].parse().unwrap(), limit:v[1].parse().unwrap(), offset:v[2].parse().unwrap(),
            candidates:v[3].parse().unwrap(), filter:v[4]=="1",
            children: if v[5]=="-" {vec![]} else {v[5].split(',').map(|x|x.parse().unwrap()).collect()} }
    }).collect();
    let root = nodes.len()-1; let n = &nodes[root];
    let request = ShardQueryRequest { prefetches:n.children.iter().map(|&i|prefetch(&nodes,i)).collect(),
        query:query(n,root), filter:n.filter.then(||Filter(vec![root])), score_threshold:None,
        limit:n.limit, offset:n.offset, params:None, with_vector:WithVector(false), with_payload:WithPayloadInterface(false) };
    let mut plan = PlannedQuery::new();
    match plan.add(request) {
        Err(e) => println!("ERROR {}",e.0),
        Ok(()) => { let mut rows=vec![]; describe(&plan.root_plans[0].merge_plan,&plan,&nodes,root,&mut rows); for row in rows {println!("{}",row);} }
    }
}
'''


def main():
    sources = {}

    def read(path):
        data = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
                                        "show", f"{REVISION}:{path}"], text=True)
        sources[path] = hashlib.sha256(data.encode()).hexdigest()
        return data

    planner = read("lib/shard/src/query/planned_query.rs")
    validation = read("lib/shard/src/query/validation.rs")
    structs = read("lib/shard/src/query/mod.rs")
    units = [planner[planner.index("const MAX_PREFETCH_DEPTH"):],
             validation[validation.index("impl MergePlan"):],
             "impl ShardQueryRequest {" + extract(structs, "pub fn prefetches_depth(") + "}",
             "impl ShardPrefetch {" + extract(structs, "pub fn depth(") + "}"]
    rust = SCAFFOLD + "\n".join(units) + DRIVER
    build = ROOT / ".build/qdrant-query-plan-reference"
    build.mkdir(parents=True, exist_ok=True)
    (build / "reference.rs").write_text(rust)
    binary = build / "reference"
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2024", "-Awarnings", str(build / "reference.rs"), "-o", str(binary)], check=True)
    rng = random.Random(20261030)
    inputs = []

    def node(kind, children=(), *, offset=0):
        return dict(kind=kind, limit=rng.randrange(1, 12), offset=offset,
                    candidates=rng.randrange(0, 15), filter=rng.choice([False, True]), children=list(children))

    for _ in range(96):
        nodes = []
        def tree(depth):
            kind = rng.choice([0, 1, 2, 3]) if depth else rng.choice([0, 3, 4])
            children = [tree(depth-1) for _ in range(rng.randrange(1, 4))] if depth else []
            nodes.append(node(kind, children)); return len(nodes)-1
        tree(rng.randrange(4)); nodes[-1]["offset"] = rng.randrange(4)
        inputs.append(nodes)
    for depth in (0, 1, 64, 65):
        nodes = [node(0)]
        for i in range(depth):
            nodes.append(node(1, [i]))
        inputs.append(nodes)
    inputs += [[node(1)], [node(2)], [node(0), node(4, [0])]]
    cases = []
    for nodes in inputs:
        encoded = ';'.join('|'.join(map(str, [n['kind'], n['limit'], n['offset'], n['candidates'], int(n['filter']),
                                             ','.join(map(str, n['children'])) or '-'])) for n in nodes)
        output = subprocess.check_output([str(binary), encoded], text=True).splitlines()
        case = dict(nodes=nodes)
        if output[0].startswith('ERROR'):
            case['error'] = output[0][6:]
        else:
            case['expected'] = []
            for line in output:
                id_, retrieval, mmr, nearest, filters = line.split()
                case['expected'].append(dict(id=int(id_), retrieval=int(retrieval), mmr=bool(int(mmr)),
                    nearest=bool(int(nearest)), filters=[] if filters=='-' else list(map(int, filters.split(',')))))
        cases.append(case)
    fixture = dict(revision=REVISION, sources=sources,
                   units_sha256=[hashlib.sha256(u.encode()).hexdigest() for u in units],
                   scaffold_sha256=hashlib.sha256(rust.encode()).hexdigest(), adapter=__doc__, cases=cases)
    target = ROOT / "tests/fixtures/qdrant-query-plan"
    target.mkdir(parents=True, exist_ok=True)
    (target / "plans.json").write_text(json.dumps(fixture, indent=2) + '\n')
    print(json.dumps(dict(cases=len(cases), errors=sum('error' in c for c in cases))))


if __name__ == "__main__":
    main()
