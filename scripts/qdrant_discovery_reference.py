"""Run unedited Qdrant discovery/context methods with portable scalar metrics.

Transport, vector containers, fixture generation and deterministic ID tie order
are adapters. This is a scorer oracle, not a full Qdrant server/HNSW oracle.
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


def main():
    historical = ROOT / "tests/fixtures/qdrant-recommendation/recommendation.json"
    old = historical.read_bytes()
    metrics.main()
    assert historical.read_bytes() == old
    metric_fixture = json.loads(old)
    base = (ROOT / ".build/qdrant-recommendation-reference/reference.rs").read_text().rsplit("fn main() {", 1)[0]
    sources, functions = {}, {}

    def get(file, name, signature, after="", full_path=None):
        path = full_path or f"lib/segment/src/vector_storage/query/{file}.rs"
        source = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
                                          "show", f"{REVISION}:{path}"], text=True)
        sources[path] = hashlib.sha256(source.encode()).hexdigest()
        function = extract(source[source.index(after):] if after else source, signature)
        functions[name] = dict(source=path, signature=signature, after=after,
                               sha256=hashlib.sha256(function.encode()).hexdigest())
        return function

    pair_rank = get("discover_query", "pair_rank", "fn rank_by(")
    rank = get("discover_query", "rank", "fn rank_by(", "impl<T> DiscoverQuery<T>")
    discover = get("discover_query", "discover_score", "fn score_by(")
    loss = get("context_query", "pair_loss", "pub fn loss_by(")
    context = get("context_query", "context_score", "fn score_by(")
    entry = get("", "custom_entry", "fn get_entry_point(", "impl GraphLayers {",
                "lib/segment/src/index/hnsw_index/graph_layers.rs")
    scaffold = base + "\n" + "\n".join([
        "type RankType = i32;",
        "#[derive(Clone)] struct ContextPair<T> { positive: T, negative: T }",
        "struct DiscoverQuery<T> { target: T, pairs: Vec<ContextPair<T>> }",
        "struct ContextQuery<T> { pairs: Vec<ContextPair<T>> }",
        f"impl<T> ContextPair<T> {{ {pair_rank}\n{loss} }}",
        f"impl<T> DiscoverQuery<T> {{ {rank} }}",
        f"impl<T> Query<T> for DiscoverQuery<T> {{ {discover} }}",
        f"impl<T> Query<T> for ContextQuery<T> {{ {context} }}",
        "type PointOffsetType = u32;",
        "#[derive(Clone, Copy)] struct EntryPoint { point_id: u32, level: usize }",
        "struct ScorerFilters { allowed: Vec<bool> }",
        "impl ScorerFilters { fn check_vector(&self, point: u32) -> bool { self.allowed[point as usize] } }",
        "struct Entries { normal: Vec<EntryPoint> }",
        "impl Entries { fn get_entry_point(&self, filter: impl Fn(u32)->bool) -> Option<EntryPoint> { self.normal.iter().find(|e| filter(e.point_id)).copied() } }",
        "struct GraphLayers { levels: Vec<usize>, entry_points: Entries }",
        f"impl GraphLayers {{ fn point_level(&self, point: u32) -> usize {{ self.levels[point as usize] }}\n{entry} }}",
    ]) + r'''
fn floats(raw: &str) -> Vec<f32> {
    if raw == "-" { vec![] } else { raw.split(',').map(|x| f32::from_bits(x.parse().unwrap())).collect() }
}
fn main() {
    let a: Vec<_> = std::env::args().skip(1).collect();
    if a[0] == "entry" {
        let levels: Vec<usize> = a[1].split(',').map(|x| x.parse().unwrap()).collect();
        let filters = ScorerFilters { allowed: a[2].split(',').map(|x| x == "1").collect() };
        let custom: Vec<u32> = if a[3] == "-" { vec![] } else { a[3].split(',').map(|x| x.parse().unwrap()).collect() };
        let normal = levels.iter().enumerate().map(|(id, &level)| EntryPoint { point_id: id as u32, level }).collect();
        let graph = GraphLayers { levels, entry_points: Entries { normal } };
        println!("{}", graph.get_entry_point(&filters, Some(&custom)).map(|p| p.point_id as i64).unwrap_or(-1));
        return;
    }
    if a[0] == "reduce" {
        let p = floats(&a[2]); let n = floats(&a[3]);
        let pairs: Vec<_> = p.into_iter().zip(n).map(|(positive, negative)| ContextPair { positive, negative }).collect();
        for pair in &pairs { println!("p:{} {}", pair.rank_by(|x| *x), pair.loss_by(|x| *x).to_bits()); }
        let context = ContextQuery { pairs: pairs.clone() }.score_by(|x| *x);
        let discover = DiscoverQuery { target: f32::from_bits(a[1].parse().unwrap()), pairs }.score_by(|x| *x);
        println!("s:{} {}", context.to_bits(), discover.to_bits());
        return;
    }
    let (kind, dim, metric) = (a[0].as_str(), a[1].parse().unwrap(), a[2].as_str());
    let target = if a[3] == "-" { None } else { Some(preprocess(parse(&a[3], kind, dim), metric)) };
    let p = vectors(&a[4], kind, dim).into_iter().map(|v| preprocess(v, metric));
    let n = vectors(&a[5], kind, dim).into_iter().map(|v| preprocess(v, metric));
    let pairs: Vec<_> = p.zip(n).map(|(positive, negative)| ContextPair { positive, negative }).collect();
    let candidates: Vec<_> = vectors(&a[6], kind, dim).into_iter().map(|v| preprocess(v, metric)).collect();
    let scores: Vec<_> = candidates.iter().enumerate().map(|(id, v)| {
        let s = if let Some(t) = &target {
            DiscoverQuery { target: t.clone(), pairs: pairs.clone() }.score_by(|q| similarity(q, v, metric))
        } else { ContextQuery { pairs: pairs.clone() }.score_by(|q| similarity(q, v, metric)) };
        (id + 1, s)
    }).collect();
    for (id, s) in scores { println!("{} {}", id, s.to_bits()); }
}
'''
    build = ROOT / ".build/qdrant-discovery-reference"
    build.mkdir(parents=True, exist_ok=True)
    (build / "reference.rs").write_text(scaffold)
    binary = build / "reference"
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2024", "-Awarnings", str(build / "reference.rs"), "-o", str(binary)], check=True)

    def run(args):
        return subprocess.check_output([str(binary), *args], text=True).splitlines()

    rng = random.Random(20261030)
    reductions = []
    numbers = [0, -0.0, 1, -1, 1.0000001192092896, 3e38, -3e38,
               float('inf'), -float('inf'), float('nan'), value(0xffc00001)]
    for count in (0, 1, 2, 5, 11):
        for variant in range(24):
            choose = lambda: rng.choice(numbers) if variant < 16 else rng.uniform(-5, 5)
            target = choose()
            p, n = [choose() for _ in range(count)], [choose() for _ in range(count)]
            lines = run(["reduce", str(bits(target)), ','.join(str(bits(x)) for x in p) or "-",
                         ','.join(str(bits(x)) for x in n) or "-"])
            pair_results = [list(map(int, line[2:].split())) for line in lines[:-1]]
            context_bits, discover_bits = map(int, lines[-1][2:].split())
            reductions.append(dict(target_bits=bits(target), positive_bits=list(map(bits, p)),
                                   negative_bits=list(map(bits, n)), pairs=pair_results,
                                   context_bits=context_bits, discover_bits=discover_bits))
    cases = []
    for kind in ("dense", "sparse", "multivector"):
        for metric in (("dot",) if kind == "sparse" else ("dot", "l2", "cosine")):
            for variant in range(24):
                def vector():
                    values = [-2, -0.5, 0, 0.25, 1, 3] if variant < 12 else [value(bits(rng.uniform(-3, 3))) for _ in range(6)]
                    if kind == "sparse":
                        return [[i, rng.choice(values)] for i in sorted(rng.sample(range(6), rng.randrange(0, 6)))]
                    if kind == "multivector":
                        return [[rng.choice(values) for _ in range(3)] for _ in range(rng.randrange(1, 4))]
                    return [rng.choice(values) for _ in range(3)]
                target = None if variant % 3 == 0 else vector()
                size = 1 + variant % 4 if target is None else variant % 4
                positive, negative = [vector() for _ in range(size)], [vector() for _ in range(size)]
                candidates = [vector() for _ in range(7)]
                encode = lambda vs: '/'.join(metrics.encode(v, kind) for v in vs) or '-'
                lines = run([kind, "3", metric, "-" if target is None else metrics.encode(target, kind),
                             encode(positive), encode(negative), encode(candidates)])
                cases.append(dict(kind=kind, metric=metric, dimension=0 if kind == "sparse" else 3,
                                  target=target, positive=positive, negative=negative, candidates=candidates,
                                  expected=[list(map(int, line.split())) for line in lines]))
    entries = []
    for _ in range(48):
        levels = [rng.randrange(4) for _ in range(7)]
        allowed = [rng.choice([False, True]) for _ in levels]
        custom = [rng.randrange(7) for _ in range(rng.randrange(10))]
        selected = int(run(["entry", ','.join(map(str, levels)), ','.join(str(int(x)) for x in allowed),
                            ','.join(map(str, custom)) or '-'])[0])
        entries.append(dict(levels=levels, allowed=allowed, custom=custom, expected=selected))
    fixture = dict(revision=REVISION, sources=sources, functions=functions,
                   metric_sources=metric_fixture['sources'], metric_functions=metric_fixture['functions'],
                   scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(), adapter=__doc__,
                   reductions=reductions, cases=cases, entries=entries)
    target = ROOT / "tests/fixtures/qdrant-discovery"
    target.mkdir(parents=True, exist_ok=True)
    metadata = {k: v for k, v in fixture.items() if k not in ('reductions', 'cases', 'entries')}
    text = json.dumps(metadata, indent=2)[:-2] + ',\n'
    for key in ('reductions', 'cases', 'entries'):
        text += f'  "{key}": [\n' + ',\n'.join('    ' + json.dumps(x, separators=(',', ':')) for x in fixture[key]) + '\n  ]'
        text += ',\n' if key != 'entries' else '\n}\n'
    (target / "discovery.json").write_text(text)
    print(json.dumps(dict(reductions=len(reductions), vector_cases=len(cases), entries=len(entries))))


if __name__ == "__main__":
    main()
