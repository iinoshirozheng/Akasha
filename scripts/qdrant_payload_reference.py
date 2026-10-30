"""Run Qdrant's original JSON value access/mutation routines, not a Python oracle."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"


def main():
    build = ROOT / ".build/qdrant-payload-reference"
    target = ROOT / "tests/fixtures/qdrant-payload-values"
    (build / "src").mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    sources, units = {}, {}

    def source(path):
        text = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
                                        "show", f"{REVISION}:{path}"], text=True)
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    def unit(text, signature):
        body = extract(text, signature)
        units[signature.strip()] = hashlib.sha256(body.encode()).hexdigest()
        return body

    paths = source("lib/segment/src/json_path/mod.rs")
    parser = source("lib/segment/src/json_path/parse.rs")
    utils = source("lib/segment/src/common/utils.rs")
    checker = source("lib/segment/src/payload_storage/condition_checker.rs")
    assert 'serde_json = { version = "~1.0", features = ["preserve_order"] }' in source("Cargo.toml")
    (build / "src/parse.rs").write_text(parser)
    code = 'use serde_json::{Value,json};\nmod parse;\ntype MultiValue<T> = Vec<T>;\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq)]\n' + unit(paths, 'pub struct JsonPath {') + '\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq)]\n' + unit(paths, 'pub enum JsonPathItem {').replace('#[anonymize(false)]', '') + '\n'
    code += 'impl JsonPath {\n'
    for signature in ('pub fn value_get<', 'pub fn value_set<', 'pub fn value_remove('):
        code += unit(paths, signature) + '\n'
    code += '}\n'
    for signature in ('\nfn value_get<', '\nfn value_set(', '\nfn value_set_map(', '\nfn value_remove('):
        code += unit(paths, signature) + '\n'
    code += unit(utils, 'pub fn merge_map(') + '\n'
    code += r'''
use std::collections::HashSet;
const INDEXSET_ITER_THRESHOLD:usize=13;
enum ValueVariants {Bool(bool),String(String),Integer(i64)}
enum AnyVariants {Strings(HashSet<String>),Integers(HashSet<i64>)}
struct MatchValue {value:ValueVariants} struct MatchAny {any:AnyVariants}
struct MatchExcept {except:AnyVariants} struct MatchText {text:String}
struct MatchPhrase {phrase:String} struct MatchTextAny {text_any:String}
struct MatchPrefix {prefix:String}
enum Match {Value(MatchValue),Any(MatchAny),Except(MatchExcept),Text(MatchText),
Phrase(MatchPhrase),TextAny(MatchTextAny),Prefix(MatchPrefix)}
'''
    code += unit(checker, 'pub trait ValueChecker {') + '\n'
    code += unit(checker, 'impl ValueChecker for Match {') + '\n'
    code += r'''
fn main() {
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let mut output=Vec::new();
    for case in input.as_array().unwrap() {
        let mut dest=case["input"].as_object().unwrap().clone();
        let path=case["path"].as_str().map(|p|p.parse::<JsonPath>().unwrap());
        let mut removed=Vec::new();
        match case["op"].as_str().unwrap() {
            "get"=>removed=path.as_ref().unwrap().value_get(&dest).into_iter().cloned().collect(),
            "set"=>JsonPath::value_set(path.as_ref(),&mut dest,case["source"].as_object().unwrap()),
            "remove"=>removed=path.as_ref().unwrap().value_remove(&mut dest),
            _=>unreachable!()
        }
        let mut row=case.clone(); row["output"]=Value::Object(dest); row["values"]=json!(removed);
        output.push(row);
    }
    let mut filters=Vec::new();
    let values:Value=serde_json::from_str(r#"[null,false,true,0,1,2,2.0,2.5,18446744073709551615,"2","other",{},[],[null],[2],[2,3],[[2]],[null,2],[null,3],[{}],[[2],null],[true,false]]"#).unwrap();
    let queries=[
        ("eq_int",Match::Value(MatchValue{value:ValueVariants::Integer(2)})),
        ("ne_int",Match::Except(MatchExcept{except:AnyVariants::Integers(HashSet::from([2]))})),
        ("eq_string",Match::Value(MatchValue{value:ValueVariants::String("2".to_string())})),
        ("ne_string",Match::Except(MatchExcept{except:AnyVariants::Strings(HashSet::from(["2".to_string()]))})),
        ("eq_bool",Match::Value(MatchValue{value:ValueVariants::Bool(true)}))];
    for value in values.as_array().unwrap() {
        for (kind,query) in &queries {filters.push(json!({"value":value,"kind":kind,"matches":query.check(value)}));}
    }
    println!("{}",json!({"cases":output,"filters":filters}));
}
'''
    (build / "src/main.rs").write_text(code)
    (build / "Cargo.toml").write_text('[package]\nname="akasha-payload-reference"\nversion="0.1.0"\nedition="2024"\n'
        '[dependencies]\nnom="=8.0.0"\nserde_json={version="=1.0.151",features=["preserve_order"]}\n[workspace]\n')
    paths_in = ['a', 'a.b', 'a.b.c', 'a[]', 'a[0]', 'a[1]', 'a[10]',
                'a[18446744073709551615]', 'a[].b', 'a[0].b', 'a[].b[]', 'a[][].b',
                'a[].""', 'a."nul\0key"', '""', '"a.b"', '中文']
    roots = [{}, {"a": None}, {"a": 0}, {"a": False}, {"a": "x"}, {"a": []},
             {"a": {}}, {"a": [None, 1, {}, {"b": [1, 2]}]},
             {"a": {"b": {"c": 3}, "nul\0key": 4}},
             {"a": [[{"b": None}], [{"b": 5}]]},
             {"a": [{"b": 1, "": 2}, {"b": None}, {}]},
             {"first": 1, "a": 2, "third": 3, "last": 4},
             {"a": [-(1 << 63), (1 << 64)-1, -0.0, True, "中文😀"]},
             {"": "empty", "a.b": "literal", "中文": {"": None}}]
    patches = [{}, {"b": None}, {"b": 7}, {"x": None, "y": [None, {}]},
               {"a": None, "first": None, "new": 10}, {"b": {"inner": None}}]
    cases = []
    for root in roots:
        for path in paths_in:
            for op in ('get', 'remove'):
                cases.append(dict(input=root, path=path, op=op))
            for patch in patches:
                cases.append(dict(input=root, path=path, op='set', source=patch))
        for patch in patches:
            cases.append(dict(input=root, path=None, op='set', source=patch))
    rng = random.Random(20261030)
    for _ in range(100):
        root = {"a": [rng.choice(roots).get("a")]}
        # Input generation only; expected values are produced exclusively by Rust.
        cases.append(dict(input=root, path=rng.choice(paths_in), op='set', source=rng.choice(patches)))
    (build / "input.json").write_text(json.dumps(cases, ensure_ascii=True))
    locked = target / "Cargo.lock"
    if locked.exists():
        (build / "Cargo.lock").write_bytes(locked.read_bytes())
    else:
        subprocess.run(['rtk','proxy','cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(build/'Cargo.toml')],check=True)
    locked.write_bytes((build / "Cargo.lock").read_bytes())
    output = json.loads(subprocess.check_output([str(build/'target/release/akasha-payload-reference'),str(build/'input.json')],text=True))
    metadata = dict(revision=REVISION,sources=sources,units=units,
                    scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),
                    cargo_lock_sha256=hashlib.sha256(locked.read_bytes()).hexdigest())
    encoded = json.dumps(metadata, indent=2)[:-2]
    for key in ('cases', 'filters'):
        encoded += ',\n  '+json.dumps(key)+': [\n'
        encoded += ',\n'.join('    '+json.dumps(row,ensure_ascii=True,separators=(',',':')) for row in output[key])
        encoded += '\n  ]'
    (target / "values.json").write_text(encoded + '\n}\n')
    print(f"{len(output['cases'])} original Qdrant payload cases; {len(output['filters'])} filters; {len(units)} extracted units")


if __name__ == '__main__':
    main()
