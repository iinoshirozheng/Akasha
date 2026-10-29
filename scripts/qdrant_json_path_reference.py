"""Compile Qdrant's unedited JSON-path parser/operations and formula variable parser.

Unicode classification uses Rust 1.97.1's original Alphabetic/N tables, matching
Qdrant's pinned Docker compiler. The oracle also checks the host Rust char
classification against those tables for every Unicode scalar before using nom.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess
import urllib.request

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"
UNICODE_SHA = "4438831f7c584a35457022c4016ab8a295f242ff809b81a5c81b9bb14dc5e166"
UNICODE_URL = "https://raw.githubusercontent.com/rust-lang/rust/1.97.1/library/core/src/unicode/unicode_data.rs"
METHODS_SHA = "6794677490411e762ee66df96438a112fb6ca5bdc0a1ae11a9933e93eee77909"
METHODS_URL = "https://raw.githubusercontent.com/rust-lang/rust/1.97.1/library/core/src/char/methods.rs"


def main():
    build = ROOT / ".build/qdrant-json-path-reference"
    (build / "src").mkdir(parents=True, exist_ok=True)
    sources, functions = {}, {}
    def source(path):
        value = subprocess.check_output(['rtk', 'proxy', 'git', '-C', str(ROOT/'reference/qdrant'),
                                         'show', f'{REVISION}:{path}'], text=True)
        sources[path] = hashlib.sha256(value.encode()).hexdigest()
        return value
    def unit(value, signature):
        body = extract(value, signature)
        functions[signature] = hashlib.sha256(body.encode()).hexdigest()
        return body
    parser = source('lib/segment/src/json_path/parse.rs')
    paths = source('lib/segment/src/json_path/mod.rs')
    formula = source('lib/segment/src/index/query_optimization/rescore_formula/parsed_formula.rs')
    assert 'latest-rust-1.97.1-bookworm' in source('Dockerfile')
    (build/'src/parse.rs').write_text(parser)
    unicode_file = ROOT/'reference/rust-unicode/1.97.1/unicode_data.rs'
    if not unicode_file.exists():
        unicode_file.parent.mkdir(parents=True,exist_ok=True)
        unicode_file.write_bytes(urllib.request.urlopen(UNICODE_URL).read())
    unicode = unicode_file.read_text()
    assert hashlib.sha256(unicode.encode()).hexdigest() == UNICODE_SHA
    methods_file = ROOT/'reference/rust-unicode/1.97.1/methods.rs'
    if not methods_file.exists():
        methods_file.write_bytes(urllib.request.urlopen(METHODS_URL).read())
    methods = methods_file.read_text()
    assert hashlib.sha256(methods.encode()).hexdigest() == METHODS_SHA
    unicode_units = [unit(unicode, sig) for sig in (
        'impl ShortOffsetRunHeader', 'unsafe fn skip_search', 'pub mod alphabetic', 'pub mod n {')]
    code = r'''
use std::fmt::{Display,Formatter};
use std::str::FromStr;
use serde_json::{Value,json};
mod parse;
mod intrinsics {pub unsafe fn assume(value:bool) {assert!(value);}}
mod unicode {
struct ShortOffsetRunHeader(u32);
'''+ '\n'.join(unicode_units) + r'''
    pub use alphabetic::lookup as Alphabetic;
    pub use n::lookup as N;
}
'''
    code += 'trait PinnedChar {fn is_alphanumeric(self)->bool;}\nimpl PinnedChar for char {\n'
    code += unit(methods,'pub fn is_alphanumeric(self)').removeprefix('pub ')+'\n}\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq)]\n'+unit(paths,'pub struct JsonPath {')+'\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq)]\n'+unit(paths,'pub enum JsonPathItem {').replace('#[anonymize(false)]','')+'\n'
    code += unit(paths,'impl Display for JsonPath {')+'\nimpl JsonPath {\n'
    for signature in ('pub fn strip_wildcard_suffix(', 'pub fn strip_prefix(', 'pub fn extend(',
                      'pub fn array_key(', 'pub fn has_wildcard_suffix(',
                      'pub fn check_include_pattern(', 'pub fn check_exclude_pattern(',
                      'pub fn compatible('):
        code += unit(paths,signature)+'\n'
    code += '}\n'
    code += '#[derive(Debug)] enum VariableId {Score(usize),Payload(JsonPath),Condition(usize)}\n'
    code += 'const SCORE_KEYWORD:&str="score";\nimpl FromStr for VariableId {type Err=String;\n'
    code += unit(formula,'fn from_str(var_str: &str)')+'\n}\n'
    code += r'''
fn path_value(p:&JsonPath)->Value {
    json!({"first":p.first_key,"rest":p.rest.iter().map(|x| match x {
        JsonPathItem::Key(k)=>json!(["key",k]),JsonPathItem::Index(i)=>json!(["index",i]),
        JsonPathItem::WildcardIndex=>json!(["wildcard"])}).collect::<Vec<_>>(),"display":p.to_string()})
}
fn main() {
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let mut ranges=Vec::new(); let mut start=None;
    for cp in 0..=0x110000u32 {
        let yes=char::from_u32(cp).is_some_and(|c| {
            let value=PinnedChar::is_alphanumeric(c);
            assert_eq!(value,c.is_alphanumeric(),"host Unicode mismatch at U+{cp:04X}");value
        });
        if yes && start.is_none(){start=Some(cp);}
        if !yes {if let Some(begin)=start.take(){ranges.push([begin,cp-1]);}}
    }
    let cases=input["paths"].as_array().unwrap().iter().map(|v| {
        let s=v.as_str().unwrap();
        let mut result=json!({"input":s,"needs_quoting":parse::key_needs_quoting(s)});
        result["path"]=match s.parse::<JsonPath>() {Ok(p)=>path_value(&p),Err(_)=>Value::Null};
        result["variable"]=match s.parse::<VariableId>() {
            Ok(VariableId::Score(i))=>json!({"score":i}),Ok(VariableId::Payload(p))=>json!({"payload":path_value(&p)}),
            _=>Value::Null};result
    }).collect::<Vec<_>>();
    let pairs=input["pairs"].as_array().unwrap().iter().map(|v| {
        let a=v[0].as_str().unwrap().parse::<JsonPath>().unwrap();
        let b=v[1].as_str().unwrap().parse::<JsonPath>().unwrap();
        json!({"left":v[0],"right":v[1],"strip":a.strip_prefix(&b).map(|p|p.to_string()),
        "extend":a.extend(&b).to_string(),"array":a.array_key().to_string(),
        "strip_wildcard":a.strip_wildcard_suffix().to_string(),"has_wildcard":a.has_wildcard_suffix(),
        "include":a.check_include_pattern(&b),"exclude":a.check_exclude_pattern(&b),"compatible":a.compatible(&b)})
    }).collect::<Vec<_>>();
    println!("{}",json!({"cases":cases,"pairs":pairs,"unicode_ranges":ranges}));
}
'''
    (build/'src/main.rs').write_text(code)
    (build/'Cargo.toml').write_text('[package]\nname="akasha-json-path-reference"\nversion="0.1.0"\nedition="2024"\n'
        '[dependencies]\nnom="=8.0.0"\nserde_json="=1.0.151"\n[workspace]\n')
    names=['a','a_b-9','0','中文','日本語','é','e\u0301','\u0345','\u2167','\u00bd','\U0001e4d0',
           '\U00011f02','\U00033479','😀','""','"a.b[]"','"a b"','"$score"','"line\nfeed"','"a\\b"','"a\\"b"']
    samples=['','a.','a..b','a[','a]','a[0]tail','a[01]','a[-1]','a[+1]','a[1.0]',
             'a[ 1]','a[1 ]','a[١]','a[18446744073709551615]','a[18446744073709551616]',
             'a[]','a[].b','a[1][50].bar-baz[]."qux[.]quux"',
             '$score','$"score"','$score[0]','$"score"[0001]','$score[9223372036854775808]',
             '$score[18446744073709551615]','$score[18446744073709551616]','$score[]',
             '$score[1][2]','$score.x','$invalid','a b',' a','a ','a\x00','"a\x00"']+names
    rng=random.Random(20261030)
    for _ in range(700):
        value=rng.choice(names)
        for _ in range(rng.randrange(5)):
            value+=rng.choice(['.'+rng.choice(names),'[0]','[123]','[]','[18446744073709551615]',
                               '[-1]','..',' '])
        samples.append(value)
    pairs=[[a,b] for a in ('a','a.b','a.b.c','a[]','a[0]','a[].b','a[1].b','b','"a.b"')
           for b in ('a','a.b','a.b.c','a[]','a[0]','a[].b','a[1].b','b','"a.b"')]
    (build/'input.json').write_text(json.dumps(dict(paths=list(dict.fromkeys(samples)),pairs=pairs)))
    target=ROOT/'tests/fixtures/qdrant-json-path';target.mkdir(parents=True,exist_ok=True)
    if (target/'Cargo.lock').exists():
        (build/'Cargo.lock').write_bytes((target/'Cargo.lock').read_bytes())
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(build/'Cargo.toml')],check=True)
    (target/'Cargo.lock').write_bytes((build/'Cargo.lock').read_bytes())
    result=json.loads(subprocess.check_output([str(build/'target/release/akasha-json-path-reference'),str(build/'input.json')],text=True))
    ranges=result['unicode_ranges']
    # Table is a representation adapter derived from the pinned Rust lookup,
    # not Python's potentially different Unicode database.
    native='"""Generated Unicode 17 alphanumeric table from Rust 1.97.1 (MIT/Apache-2.0).\n'
    native+='Regenerate with scripts/qdrant_json_path_reference.py; do not hand edit.\n"""\n\n'
    native+=f'def _ranges() -> Array[UInt32, {len(ranges)*2}]:\n    var result = Array[UInt32, {len(ranges)*2}](fill=0)\n'
    for i,(lo,hi) in enumerate(ranges):
        native+=f'    result[{i*2}] = {lo}\n    result[{i*2+1}] = {hi}\n'
    native+='    return result^\n\n\ncomptime _RANGES = _ranges()\n\n\ndef is_alphanumeric(codepoint: Int) -> Bool:\n'
    native+=f'    var ranges = materialize[_RANGES]()\n    var left = 0\n    var right = {len(ranges)}\n'
    native+='    while left < right:\n        var middle = left + (right - left) // 2\n'
    native+='        if codepoint < Int(ranges[middle * 2]):\n            right = middle\n'
    native+='        elif codepoint > Int(ranges[middle * 2 + 1]):\n            left = middle + 1\n'
    native+='        else:\n            return True\n    return False\n'
    (ROOT/'src/akasha/document/unicode_alphanumeric.mojo').write_text(native)
    result.update(revision=REVISION,sources=sources,units=functions,
                  unicode_source=dict(url=UNICODE_URL,sha256=UNICODE_SHA,version='17.0.0'),
                  unicode_method_source=dict(url=METHODS_URL,sha256=METHODS_SHA),
                  host_rustc=subprocess.check_output(['rtk','proxy','rustc','--version'],text=True).strip(),
                  parser_sha256=hashlib.sha256(parser.encode()).hexdigest(),
                  scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),
                  cargo_lock_sha256=hashlib.sha256((build/'Cargo.lock').read_bytes()).hexdigest(),
                  native_unicode_sha256=hashlib.sha256(native.encode()).hexdigest())
    metadata = {k:v for k,v in result.items() if k not in ('cases','pairs','unicode_ranges')}
    encoded = json.dumps(metadata,ensure_ascii=True,indent=2)[:-2]
    for key in ('cases','pairs','unicode_ranges'):
        encoded += ',\n  '+json.dumps(key)+': [\n'
        encoded += ',\n'.join('    '+json.dumps(v,ensure_ascii=True,separators=(',',':')) for v in result[key])
        encoded += '\n  ]'
    (target/'paths.json').write_text(encoded+'\n}\n')
    print(json.dumps(dict(cases=len(result['cases']),pairs=len(pairs),unicode_ranges=len(ranges))))


if __name__=='__main__':
    main()
