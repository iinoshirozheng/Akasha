"""Original Qdrant payload retriever + formula scorer, with actual JSON paths.

Retains the scalar oracle separately. Storage/counter/type wrappers are adapters;
all traversal, flattening, defaults and numeric evaluation bodies are upstream.
Geo/date remain explicitly outside this oracle.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

from qdrant_dbsf_reference import extract
from qdrant_formula_reference import SCAFFOLD

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"
BASE = "lib/segment/src/index/query_optimization/rescore_formula/"


def main():
    build = ROOT / ".build/qdrant-formula-payload-reference"
    target = ROOT / "tests/fixtures/qdrant-formula-payload"
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
    parsed = source(BASE + "parsed_formula.rs")
    scorer = source(BASE + "formula_scorer.rs")
    helper = source("lib/segment/src/index/struct_payload_index/read_view/value_retriever/helpers.rs")
    (build / "src/parse.rs").write_text(parser)
    code = SCAFFOLD.replace("type JsonPath = String;", "")
    start = code.index("#[derive(Clone,Debug)] enum Value")
    end = code.index("#[derive(Clone,Copy,Debug)] struct GeoPoint;")
    code = code[:start] + "use serde_json::{Value,json};\n" + code[end:]
    code = code.replace("#[derive(Clone,Copy,Debug)] struct GeoPoint;",
                        "#[derive(Clone,Copy,Debug,serde::Deserialize)] struct GeoPoint;")
    code = code.replace('mod serde_json {use super::*; pub fn from_value<T>(_:Value)->Result<T,String>{Err("geo outside scalar oracle".into())}}', "")
    code = code.replace("field_name:String", "field_name:JsonPath")
    code = code.replace("Payload(String)", "Payload(JsonPath)")
    code = code.replace("key:String", "key:JsonPath")
    code = code.replace("PayloadVariable(String)", "PayloadVariable(JsonPath)")
    code = code.replace("type VariableRetrieverFn = Box<dyn Fn(u32)->Vec<Value>>;",
                        "type VariableRetrieverFn<'a> = Box<dyn Fn(u32)->Vec<Value> + 'a>;")
    code = code.replace("struct FormulaScorer {", "struct FormulaScorer<'a> {")
    code = code.replace("HashMap<String,VariableRetrieverFn>", "HashMap<JsonPath,VariableRetrieverFn<'a>>")
    code += '\nuse std::fmt::{Display,Formatter};\nuse std::str::FromStr;\nmod parse;\n'
    code += 'const SCORE_KEYWORD:&str="score";\ntype MultiValue<T> = Vec<T>;\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq,Hash)]\n' + unit(paths, 'pub struct JsonPath {') + '\n'
    code += '#[derive(Debug,Clone,PartialEq,Eq,Hash)]\n' + unit(paths, 'pub enum JsonPathItem {').replace('#[anonymize(false)]', '') + '\n'
    code += 'impl JsonPath {\n' + unit(paths, 'pub fn value_get<') + '\n'
    code += unit(paths, 'pub fn has_wildcard_suffix(') + '\n}\n'
    code += unit(paths, '\nfn value_get<') + '\n' + unit(paths, 'impl Display for JsonPath {') + '\n'
    code += unit(parsed, 'impl FromStr for VariableId {') + '\n'
    code += r'''
struct HardwareCounterCell;
trait PayloadStorageRead {
    fn get_value_cloned(&self, path:&JsonPath)->MultiValue<Value>;
}
impl PayloadStorageRead for serde_json::Map<String,Value> {
    fn get_value_cloned(&self, path:&JsonPath)->MultiValue<Value> {
        path.value_get(self).into_iter().cloned().collect()
    }
}
struct PayloadProvider<P>(P);
impl<P> PayloadProvider<P> {
    fn with_payload<R>(&self,_:u32,f:impl FnOnce(&P)->R,_:&HardwareCounterCell)->R { f(&self.0) }
}
'''
    code += unit(helper, "fn payload_variable_retriever<") + '\n'
    code += "impl<'a> FormulaScorer<'a> {\n"
    for signature in ('pub fn score(', 'fn eval_expression(', 'fn get_payload_value(', 'fn get_parsed_payload_value<'):
        code += unit(scorer, signature) + '\n'
    code += '}\n'
    for name in ('exp_decay', 'gauss_decay', 'linear_decay'):
        code += unit(scorer, 'fn ' + name + '(') + '\n'
    code += r'''
fn expression(raw:&Value, vars:&mut Vec<JsonPath>)->ParsedExpression {
    if let Some(name)=raw.as_str() {
        let variable:VariableId=name.parse().unwrap();
        if let VariableId::Payload(path)=&variable {vars.push(path.clone());}
        return ParsedExpression::Variable(variable)
    }
    if let Some(n)=raw.as_f64() {return ParsedExpression::Constant(OrderedFloat(f64::from(n as f32)))}
    let (kind,arg)=raw.as_object().unwrap().iter().next().unwrap();
    match kind.as_str() {
        "sum"=>ParsedExpression::Sum(arg.as_array().unwrap().iter().map(|v|expression(v,vars)).collect()),
        "mult"=>ParsedExpression::Mult(arg.as_array().unwrap().iter().map(|v|expression(v,vars)).collect()),
        "neg"=>ParsedExpression::Neg(Box::new(expression(arg,vars))),
        "div"=>ParsedExpression::Div{left:Box::new(expression(&arg["left"],vars)),
            right:Box::new(expression(&arg["right"],vars)),by_zero_default:None},
        _=>panic!("unsupported transport expression")
    }
}
fn main() {
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let counter=HardwareCounterCell;
    let mut output=Vec::new();
    for row in input.as_array().unwrap() {
        let mut paths=Vec::new();
        let formula=expression(&row["expression"],&mut paths);
        let defaults=row["defaults"].as_object().unwrap().iter()
            .map(|(k,v)|(k.parse().unwrap(),v.clone())).collect();
        let payload_retrievers=paths.into_iter().map(|p| {
            let retriever=payload_variable_retriever(PayloadProvider(row["payload"].as_object().unwrap().clone()),p.clone(),&counter);
            (p,retriever)
        }).collect();
        let scorer=FormulaScorer{formula,defaults,payload_retrievers,condition_checkers:vec![],
            prefetches_scores:vec![HashMap::from([(1,0.0)])]};
        let result=scorer.score(1);
        let mut row=row.clone();
        match result {
            Ok(score)=>{row["expected_bits"]=json!(score.to_bits());row["error"]=Value::Null;},
            Err(error)=>{row["expected_bits"]=Value::Null;row["error"]=json!(format!("{error:?}"));}
        }
        output.push(row);
    }
    println!("{}",json!(output));
}
'''
    (build / 'src/main.rs').write_text(code)
    (build / 'Cargo.toml').write_text('[package]\nname="akasha-formula-payload-reference"\nversion="0.1.0"\nedition="2024"\n'
        '[dependencies]\nnom="=8.0.0"\nserde={version="=1.0.228",features=["derive"]}\n'
        'serde_json={version="=1.0.151",features=["preserve_order"]}\n[workspace]\n')
    values = [None, False, True, -0.0, 0, 2.5, -(1 << 63), (1 << 64)-1, '2', {}, [],
              [3], [None], [3,4], [[3]], [[3,4]], {'b': 7}, {'b': []}, {'b': [7]},
              [{'b': 1}], [{'b': []}, {'b': [4]}], [{'b': [3,4]}],
              [{'b': None}, {'b': 4}], [{'b': 4}, {}], [[{'b': 9}]],
              {'nul\0key': 3, '': 4, '中文': 5, 'a.b': 6}]
    paths = ['a','a[]','a[0]','a[1]','a[18446744073709551615]', 'a.b', 'a[].b',
             'a[].b[]','a[][].b','a[0].b','a[0][]','a.b[]','a."nul\0key"','a.""','a.中文','a."a.b"']
    cases = []
    for value in values:
        for path in paths:
            for defaults in ({}, {path: 6.25}):
                cases.append(dict(expression=path,payload={'a':value},defaults=defaults))
    for value in values:
        for name in ('a.b', '$score[1]', '$score[18446744073709551615]'):
            cases.append(dict(expression=name,payload={},defaults={name:value}))
        cases.append(dict(expression='$score',payload={},defaults={'$score':value}))
    for expr in ({'mult':[0,'a.b']},{'mult':['a.b',0]}, {'div':{'left':0,'right':'a.b'}},
                 {'sum':['$score','a.b']}, {'neg':'a.b'}):
        for value in values:
            cases.append(dict(expression=expr,payload={'a':value},defaults={'a.b':5}))
    cases += [dict(expression='a.b[0]',payload={},defaults={'"a"."b"[00]':7}),
              dict(expression='$"score"[01]',payload={},defaults={'$score[1]':(1<<64)-1})]
    (build / 'input.json').write_text(json.dumps(cases,ensure_ascii=True))
    lock = target / 'Cargo.lock'
    if lock.exists():
        (build / 'Cargo.lock').write_bytes(lock.read_bytes())
    else:
        subprocess.run(['rtk','proxy','cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(build/'Cargo.toml')],check=True)
    lock.write_bytes((build/'Cargo.lock').read_bytes())
    output = json.loads(subprocess.check_output([str(build/'target/release/akasha-formula-payload-reference'),str(build/'input.json')],text=True))
    metadata = dict(revision=REVISION,sources=sources,units=units,
                    scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),
                    cargo_lock_sha256=hashlib.sha256(lock.read_bytes()).hexdigest())
    text = json.dumps(metadata,indent=2)[:-2] + ',\n  "cases": [\n'
    text += ',\n'.join('    '+json.dumps(row,ensure_ascii=True,separators=(',',':')) for row in output)
    (target/'formula.json').write_text(text+'\n  ]\n}\n')
    print(f'{len(output)} original Qdrant rich formula cases; {len(units)} extracted units')


if __name__ == '__main__':
    main()
