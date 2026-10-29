"""Freeze results from unedited pinned Qdrant RRF functions, compiled with rustc."""

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
SOURCE = "lib/segment/src/common/reciprocal_rank_fusion.rs"


def bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def main() -> None:
    source = subprocess.check_output(
        ["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
         "show", f"{REVISION}:{SOURCE}"], text=True,
    )
    extracted = "\n\n".join(extract(source, name) for name in
                           ["fn position_score(", "pub fn rrf_scoring("])
    # Containers/error/iterator/point shims avoid building the Qdrant service.
    # OrderedFloat's ordering is equivalent for the nonnegative, non-NaN scores
    # generated here. Upstream leaves ties unspecified; canonicalize only ties
    # when serializing output, matching Akasha's documented ascending-ID rule.
    scaffold = r"""
use std::collections::{HashMap, hash_map::Entry};
type AHashMap<K, V> = HashMap<K, V>;
type ExtendedPointId = i64;
pub struct ScoredPoint { id: i64, score: f32 }
#[derive(Debug)]
pub struct OperationError(String);
impl OperationError { fn validation_error(s: String) -> Self { Self(s) } }
type OperationResult<T> = Result<T, OperationError>;
enum Either<L, R> { Left(L), Right(R) }
impl<T, L: Iterator<Item=T>, R: Iterator<Item=T>> Iterator for Either<L, R> {
    type Item = T;
    fn next(&mut self) -> Option<T> {
        match self { Self::Left(l) => l.next(), Self::Right(r) => r.next() }
    }
}
struct OrderedFloat(f32);
impl PartialEq for OrderedFloat { fn eq(&self, b: &Self) -> bool { self.0 == b.0 } }
impl Eq for OrderedFloat {}
impl PartialOrd for OrderedFloat {
    fn partial_cmp(&self, b: &Self) -> Option<std::cmp::Ordering> { Some(self.cmp(b)) }
}
impl Ord for OrderedFloat {
    fn cmp(&self, b: &Self) -> std::cmp::Ordering { self.0.total_cmp(&b.0) }
}
__FUNCTIONS__
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args[0] == "position" {
        println!("{}", position_score(args[1].parse().unwrap(), args[2].parse().unwrap(),
            f32::from_bits(args[3].parse().unwrap())).to_bits());
        return;
    }
    let k = args[1].parse().unwrap();
    let weights: Option<Vec<f32>> = match args[2].as_str() {
        "none" => None,
        "empty" => Some(vec![]),
        raw => Some(raw.split(',').map(|s| f32::from_bits(s.parse().unwrap())).collect()),
    };
    let responses = args[3..].iter().map(|branch| {
        if branch == "empty" { return vec![]; }
        branch.split(',').map(|s| ScoredPoint { id: s.parse().unwrap(), score: -123.0 }).collect()
    }).collect();
    match rrf_scoring(responses, k, weights.as_deref()) {
        Ok(mut hits) => {
            hits.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.id.cmp(&b.id)));
            for hit in hits { println!("{} {}", hit.id, hit.score.to_bits()); }
        },
        Err(e) => println!("error:{}", e.0),
    }
}
""".replace("__FUNCTIONS__", extracted)
    build = ROOT / ".build/qdrant-rrf-reference"
    build.mkdir(parents=True, exist_ok=True)
    rust = build / "reference.rs"
    binary = build / "reference"
    rust.write_text(scaffold)
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2021", str(rust),
                    "-o", str(binary)], check=True)

    positions = []
    weights = [-7.0, -0.0, 0.0, 0.125, 0.7, 1.0, 1.5, 3.0, 1e-38, 1e38]
    for position in (0, 1, 2, 15, 127, 16_777_216):
        for constant in (1, 2, 60, 16_777_216, 2**63 - 1):
            for weight in weights:
                output = subprocess.check_output(
                    [str(binary), "position", str(position), str(constant), str(bits(weight))], text=True,
                )
                positions.append([position, constant, bits(weight), int(output)])

    inputs = [
        ([], 2, None), ([], 2, []), ([[], []], 2, None),
        ([[1, 2], [2, 1]], 2, None), ([[1, 2], [2, 1]], 2, [1.0, 1.0]),
        ([[1, 2], [2, 1]], 2, [3.0, 1.0]),
        ([[1, 2], [2, 1]], 2, [0.125, 1.5]),
        ([[2, 1], [3, 1]], 2, [0.0, 1.0]),
        ([[2, 1], [3, 1]], 2, [-1.0, 0.0]),
        ([[], [2, 1]], 2, [3.0, 0.7]),
        ([[1, 2], []], 16_777_216, [1.0, 1.0]),
        ([[1, 2], [2, 3], [3, 1]], 60, [0.7, 1.5, 3.0]),
        ([[1], [1]], 1, [1e38, 1.0]),  # upstream infinite; Akasha rejects
        ([[1, 2], [2, 3]], 2, [1e-38, 0.0]),
        ([[1], []], 2, []), ([[1], []], 2, [1.0]),
        ([[1], []], 2, [1.0, 1.0, 1.0]),
        ([[1, 1, 2], [2, 2, 1]], 2, [3.0, 0.7]),
    ]
    rng = random.Random(20261030)
    for count in (1, 2, 3, 8):
        for _ in range(8):
            branches = [rng.sample(range(-20, 21), rng.randrange(0, 40)) for _ in range(count)]
            inputs.append((branches, rng.choice([1, 2, 60, 16_777_216]),
                           [rng.choice(weights[:8]) for _ in branches]))
    cases = []
    for branches, constant, weight_values in inputs:
        raw_weights = None if weight_values is None else list(map(bits, weight_values))
        encoded = "none" if raw_weights is None else ",".join(map(str, raw_weights)) or "empty"
        output = subprocess.check_output(
            [str(binary), "fusion", str(constant), encoded,
             *[",".join(map(str, branch)) or "empty" for branch in branches]], text=True,
        )
        sample = dict(branches=branches, rank_constant=constant, weight_bits=raw_weights)
        if output.startswith("error:"):
            sample["error"] = output.strip().removeprefix("error:")
        else:
            sample["expected"] = [list(map(int, line.split())) for line in output.splitlines()]
        cases.append(sample)
    fixture = dict(
        upstream="https://github.com/qdrant/qdrant", revision=REVISION, source=SOURCE,
        source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        extracted_sha256=hashlib.sha256(extracted.encode()).hexdigest(),
        scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(),
        adapter="Verbatim functions; std HashMap, Either iterator, nonnegative-score OrderedFloat, i64 IDs, score-only point/error shims; output ties canonicalized by ID",
        position_columns=["rank", "k", "weight_bits", "score_bits"],
        positions=positions, cases=cases,
    )
    target = ROOT / "tests/fixtures/qdrant-rrf"
    target.mkdir(parents=True, exist_ok=True)
    (target / "weighted.json").write_text(json.dumps(fixture, indent=2) + "\n")
    print(json.dumps(dict(positions=len(positions), fusions=len(cases), source_sha256=fixture["source_sha256"])))


if __name__ == "__main__":
    main()
