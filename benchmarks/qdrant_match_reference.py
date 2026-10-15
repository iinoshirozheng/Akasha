"""Compile Qdrant's unedited MatchValue arm without the Edge bool conversion bug."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess


def boolean_matches(reference: Path, output: Path, values: list[bool | None]):
    source = reference / "lib/segment/src/payload_storage/condition_checker.rs"
    text = source.read_text()
    start = text.index("            Match::Value(MatchValue { value }) => match")
    end = text.index("            Match::Text(", start)
    arm = text[start:end]
    # These are representation adapters only. Match logic is inserted verbatim.
    scaffold = r'''
#![allow(dead_code)]
enum Value { Bool(bool), String(String), Number(Number), Null }
struct Number(i64);
impl Number { fn as_i64(&self) -> Option<i64> { Some(self.0) } }
enum ValueVariants { Bool(bool), Integer(i64), String(String) }
struct MatchValue { value: ValueVariants }
enum Match { Value(MatchValue) }
impl Match {
    fn check_match(&self, payload: &Value) -> bool {
        match self { __ARM__ }
    }
}
fn main() {
    let input = std::env::args().nth(1).unwrap();
    for target in [true, false] {
        let condition = Match::Value(MatchValue { value: ValueVariants::Bool(target) });
        for item in input.chars() {
            let value = match item {
                'T' => Value::Bool(true), 'F' => Value::Bool(false),
                'I' => Value::Number(Number(1)), 'S' => Value::String("true".into()),
                _ => Value::Null,
            };
            print!("{} ", usize::from(condition.check_match(&value)));
        }
        println!();
    }
}
'''
    path = output / "match-reference.rs"
    binary = output / "match-reference"
    path.write_text(scaffold.replace("__ARM__", arm))
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2021", str(path), "-o", str(binary)], check=True)
    raw = subprocess.check_output([str(binary), "".join("T" if x is True else "F" if x is False else "M" for x in values)], text=True)
    (output / "match-reference.log").write_text(raw)
    # Also prove that the core doesn't confuse true with integer 1 or string true.
    typed = subprocess.check_output([str(binary), "TISM"], text=True)
    assert typed.splitlines()[0].split() == ["1", "0", "0", "0"]
    return [[bool(int(x)) for x in line.split()] for line in raw.splitlines()], {
        "source": str(source.relative_to(reference)),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "extracted_arm_sha256": hashlib.sha256(arm.encode()).hexdigest(),
        "adapter_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "typed_probe": typed,
    }
