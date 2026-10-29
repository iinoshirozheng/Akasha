"""Generate DBSF fixtures by compiling unedited functions from pinned Qdrant."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"
SOURCE = "lib/segment/src/common/score_fusion.rs"


def extract(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


def bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def value(raw: int) -> float:
    return struct.unpack("<f", struct.pack("<I", raw))[0]


def main() -> None:
    source = subprocess.check_output(
        ["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
         "show", f"{REVISION}:{SOURCE}"], text=True,
    )
    extracted = "\n\n".join(extract(source, signature) for signature in
                           ["fn norm(", "fn welfords_mean_variance(", "pub fn distr_norm("])
    scaffold = """type ScoreType = f32;
pub struct ScoredPoint { score: f32 }
__FUNCTIONS__
fn main() {
    let points = std::env::args().skip(1)
        .map(|arg| ScoredPoint { score: f32::from_bits(arg.parse().unwrap()) })
        .collect();
    for point in distr_norm(points) { println!("{}", point.score.to_bits()); }
}
""".replace("__FUNCTIONS__", extracted)
    build = ROOT / ".build/qdrant-dbsf-reference"
    build.mkdir(parents=True, exist_ok=True)
    rust = build / "reference.rs"
    binary = build / "reference"
    rust.write_text(scaffold)
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2021", str(rust),
                    "-o", str(binary)], check=True)
    rng = random.Random(20261030)
    inputs = [[], [999.0], [0.0, 0.0], [7.0] * 4, [-3.0, 0.0, 3.0],
              [0.0] * 63 + [1000.0], [1e10, 1e10 + 1024, 1e10 + 2048],
              [-100.0, 1.0, 2.0, 5.0, 80.0], [1e-15, -1e-15, 3e-15]]
    inputs += [[rng.uniform(-100, 100) for _ in range(size)]
               for size in (2, 3, 7, 16, 64, 129) for _ in range(8)]
    inputs += [sorted(scores, reverse=True) for scores in inputs.copy()]
    cases = []
    for scores in inputs:
        raw = [bits(item) for item in scores]
        output = subprocess.check_output([str(binary), *map(str, raw)], text=True)
        expected = list(map(int, output.split()))
        cases.append({"input_bits": raw, "output_bits": expected,
                      "input": list(map(value, raw)), "output": list(map(value, expected))})
    fixture = {
        "upstream": "https://github.com/qdrant/qdrant", "revision": REVISION,
        "source": SOURCE, "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "extracted_sha256": hashlib.sha256(extracted.encode()).hexdigest(),
        "scaffold_sha256": hashlib.sha256(scaffold.encode()).hexdigest(),
        "adapter": "ScoredPoint contains only score; ScoreType aliases f32; functions extracted verbatim",
        "cases": cases,
    }
    target = ROOT / "tests/fixtures/qdrant-dbsf"
    target.mkdir(parents=True, exist_ok=True)
    (target / "normalization.json").write_text(json.dumps(fixture, indent=2) + "\n")
    print(json.dumps({"cases": len(cases), "scores": sum(len(x["input"]) for x in cases),
                      "source_sha256": fixture["source_sha256"]}))


if __name__ == "__main__":
    main()
