"""Compile original Qdrant plain filter routines; Python generates inputs only."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"


def main(*, cases_override=None, fixture_name="qdrant-payload-filter"):
    build = ROOT / f".build/{fixture_name}-reference"
    target = ROOT / "tests/fixtures" / fixture_name
    (build / "src").mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    sources, units = {}, {}

    def source(path):
        text = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
            "show", f"{REVISION}:{path}"], text=True)
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    def unit(text, signature):
        body = (text[text.index(signature):].split(";", 1)[0] + ";"
                if signature == "pub struct DateTimeWrapper(" else extract(text, signature))
        units[signature] = hashlib.sha256(body.encode()).hexdigest()
        return body

    types = source("lib/segment/src/types.rs")
    paths = source("lib/segment/src/json_path/mod.rs")
    checker = source("lib/segment/src/payload_storage/condition_checker.rs")
    query = source("lib/segment/src/payload_storage/query_checker.rs")
    (build / "src/parse.rs").write_text(source("lib/segment/src/json_path/parse.rs"))
    source("Cargo.lock")
    code = r'''
use serde::{Deserialize,Deserializer};
use serde_json::{Value,json};
use std::{str::FromStr,borrow::Cow};
use ordered_float::OrderedFloat;
use indexmap::IndexSet;
use fnv::FnvBuildHasher;
use geo::{Point,LineString,Coord,Polygon,Contains,Haversine,Distance};
mod parse;
type MultiValue<T> = Vec<T>;
type IntPayloadType = i64;
type FloatPayloadType = f64;
type OrderedFloatPayloadType = OrderedFloat<f64>;
type PayloadKeyType = JsonPath;
type OperationResult<T> = Result<T,OperationError>;
#[derive(Debug)] pub struct OperationError(String);
impl OperationError {fn validation_error(s:impl Into<String>)->Self {Self(s.into())}}
impl std::fmt::Display for OperationError {fn fmt(&self,f:&mut std::fmt::Formatter)->std::fmt::Result {write!(f,"{}",self.0)}}
'''
    code += '#[derive(Clone,Debug,PartialEq,Eq)]\n' + unit(paths, 'pub struct JsonPath {') + '\n'
    code += '#[derive(Clone,Debug,PartialEq,Eq)]\n' + unit(paths, 'pub enum JsonPathItem {').replace('#[anonymize(false)]', '') + '\n'
    code += 'impl JsonPath {\n' + unit(paths, 'pub fn value_get<') + '\n'
    code += unit(paths, 'pub fn array_key(') + '\n}\n' + unit(paths, '\nfn value_get<') + '\n'
    code += '''impl<'de> Deserialize<'de> for JsonPath {
        fn deserialize<D:Deserializer<'de>>(d:D)->Result<Self,D::Error> {
            String::deserialize(d)?.parse().map_err(|_|serde::de::Error::custom("invalid JSON path"))
        }
    }\n'''
    code += '#[derive(Clone,Copy,Debug,PartialEq,Eq,PartialOrd,Ord)]\n' + unit(types, 'pub struct DateTimeWrapper(') + '\n'
    code += 'type DateTimePayloadType = DateTimeWrapper;\n'
    for sig in ('impl DateTimeWrapper {', "impl<'de> Deserialize<'de> for DateTimePayloadType {",
                'impl FromStr for DateTimePayloadType {', 'impl From<chrono::DateTime<chrono::Utc>> for DateTimePayloadType {'):
        code += unit(types, sig) + '\n'
    for name in ('ValueVariants', 'AnyVariants', 'MatchInterface'):
        code += '#[derive(Deserialize)]\n#[serde(untagged)]\n' + unit(types, f'pub enum {name} {{') + '\n'
    for name in ('MatchValue', 'MatchAny', 'MatchExcept', 'MatchText', 'MatchPhrase', 'MatchPrefix', 'MatchTextAny'):
        code += '#[derive(Deserialize)]\n' + unit(types, f'pub struct {name} {{') + '\n'
    code += '#[derive(Deserialize)]\n#[serde(untagged,from="MatchInterface")]\n' + unit(types, 'pub enum Match {') + '\n'
    code += unit(types, 'impl From<MatchInterface> for Match {') + '\n'
    code += '#[derive(Clone,Copy,Debug,Deserialize)]\n' + unit(types, 'pub struct Range<T> {') + '\n'
    code += unit(types, 'impl<T: Copy + PartialOrd> Range<T> {') + '\n'
    code += '#[derive(Clone,Copy,Debug)]\n' + unit(types, 'pub enum RangeInterface {') + '\n'
    code += '#[derive(Deserialize)]\n#[serde(untagged)]\n' + unit(types, 'enum RangeInterfaceUntagged {') + '\n'
    code += unit(types, "impl<'de> serde::Deserialize<'de> for RangeInterface {") + '\n'
    for name in ('ValuesCount', 'GeoPointShadow', 'GeoLineString', 'GeoBoundingBox', 'GeoRadius', 'GeoPolygonShadow'):
        visibility = '' if name == 'GeoPointShadow' else 'pub '
        code += '#[derive(Deserialize)]\n' + unit(types, f'{visibility}struct {name} {{') + '\n'
    code += '#[derive(Clone,Copy,Debug,Deserialize)]\n#[serde(try_from="GeoPointShadow")]\n' + unit(types, 'pub struct GeoPoint {') + '\n'
    code += '#[derive(Debug)]\n' + unit(types, 'pub struct GeoPointValidationError {') + '\n'
    code += '#[derive(Deserialize)]\n#[serde(try_from="GeoPolygonShadow")]\n' + unit(types, 'pub struct GeoPolygon {') + '\n'
    for sig in ('impl ValuesCount {', 'impl GeoPoint {', 'impl std::fmt::Display for GeoPointValidationError {',
                'impl TryFrom<GeoPointShadow> for GeoPoint {', 'impl From<GeoPoint> for geo::Point {',
                'pub trait CheckGeoPoint {', 'impl CheckGeoPoint for GeoBoundingBox {',
                'impl CheckGeoPoint for GeoRadius {', 'pub struct PolygonWrapper {',
                'impl CheckGeoPoint for PolygonWrapper {', 'impl GeoPolygon {',
                'impl TryFrom<GeoPolygonShadow> for GeoPolygon {'):
        code += unit(types, sig) + '\n'
    code += '#[derive(Deserialize)]\n' + unit(types, 'pub struct FieldCondition {') + '\n'
    code += 'const INDEXSET_ITER_THRESHOLD:usize=13;\n'
    for sig in ('pub trait ValueChecker {', 'fn check_is_empty(', 'fn check_is_null(',
                'impl ValueChecker for FieldCondition {', 'impl ValueChecker for Match {',
                'impl ValueChecker for Range<OrderedFloat<FloatPayloadType>> {',
                'impl ValueChecker for Range<DateTimePayloadType> {',
                'impl ValueChecker for GeoBoundingBox {', 'impl ValueChecker for GeoRadius {',
                'impl ValueChecker for GeoPolygon {', 'impl ValueChecker for ValuesCount {'):
        code += unit(checker, sig) + '\n'
    # These types are only the transport into original Boolean combinators.
    code += r'''
enum Condition {Filter(Filter),Field(FieldCondition),Nested(NestedCondition),
    IsEmpty(()),IsNull(()),HasId(()),HasVector(()),Slice(()),CustomIdChecker(())}
#[derive(Default)] struct Filter {should:Option<Vec<Condition>>,min_should:Option<MinShould>,
    must:Option<Vec<Condition>>,must_not:Option<Vec<Condition>>}
struct MinShould {conditions:Vec<Condition>,min_count:usize}
struct NestedCondition {key:JsonPath,filter:Filter}
impl NestedCondition {fn array_key(&self)->JsonPath {self.key.array_key()}}
'''
    for sig in ('fn check_condition<F>', 'pub fn check_filter<F>', 'fn check_should<F>',
                'fn check_min_should<F>', 'fn check_must<F>', 'fn check_must_not<F>'):
        code += unit(query, sig) + '\n'
    # Extract the actual plain field branch and nested any-object recursion.
    plain = unit(query, 'pub fn check_field_condition<R, FI>')
    assert 'Ok(field_values.into_iter().any(|p| field_condition.check(p)))' in plain
    nested = unit(query, 'Condition::Nested(nested) => {')
    code += r'''
fn condition(v:&Value)->Result<Condition,String> {
    let children=||->Result<Vec<Condition>,String> {v["children"].as_array().ok_or("children")?.iter().map(condition).collect()};
    Ok(match v["kind"].as_str().ok_or("kind")? {
        "field"=>Condition::Field(serde_json::from_value(v.clone()).map_err(|e|e.to_string())?),
        "nested"=>Condition::Nested(NestedCondition{key:v["key"].as_str().ok_or("key")?.parse().map_err(|e|format!("{e:?}"))?,
            filter:Filter{must:Some(vec![condition(&v["filter"])?]),..Default::default()}}),
        "all"=>Condition::Filter(Filter{must:Some(children()?),..Default::default()}),
        "any"=>Condition::Filter(Filter{should:Some(children()?),..Default::default()}),
        "not"=>Condition::Filter(Filter{must_not:Some(vec![condition(&v["child"])?]),..Default::default()}),
        "at_least"=>Condition::Filter(Filter{min_should:Some(MinShould{conditions:children()?,
            min_count:v["min_count"].as_u64().ok_or("min_count")? as usize}),..Default::default()}),
        _=>return Err("unsupported oracle expression".into())
    })
}
fn matches(payload:&serde_json::Map<String,Value>,filter:&Filter)->bool {
    let checker=|condition:&Condition| match condition {
        Condition::Field(field_condition)=>{
            let field_values=field_condition.key.value_get(payload);
            if field_values.is_empty() {return field_condition.check_empty();}
            field_values.into_iter().any(|p| field_condition.check(p))
        },
'''
    # Only storage/index plumbing is replaced; traversal/shape/any-object branch stays source code.
    adapted = nested.replace('            let nested_indexes = select_nested_indexes(&nested_path, field_indexes);\n', '')
    adapted = adapted.replace('get_payload()\n                .get_value(&nested_path)', 'nested_path.value_get(payload)')
    start = adapted.index('                    check_payload(')
    end = adapted.index('\n                })', start)
    adapted = adapted[:start] + '                    matches(object, &nested.filter)' + adapted[end:]
    code += adapted + ',\n_=>unreachable!()\n}; check_filter(&checker,filter)\n}\n'
    code += r'''
fn main() {
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let output:Vec<Value>=input.as_array().unwrap().iter().map(|row| {
        let mut result=row.clone();
        match condition(&row["filter"]) {
            Ok(c)=>result["matches"]=json!(matches(row["payload"].as_object().unwrap(),&Filter{must:Some(vec![c]),..Default::default()})),
            Err(e)=>result["error"]=json!(e)
        }
        result
    }).collect();
    println!("{}",json!(output));
}
'''
    (build / 'src/main.rs').write_text(code)
    (build / 'Cargo.toml').write_text('''[package]
name="akasha-payload-filter-reference"
version="0.1.0"
edition="2024"
[dependencies]
nom="=8.0.0"
serde={version="=1.0.228",features=["derive"]}
serde_json={version="=1.0.151",features=["preserve_order"]}
ordered-float={version="=5.3.0",features=["serde"]}
indexmap={version="=2.14.0",features=["serde"]}
fnv="=1.0.7"
geo="=0.33.1"
chrono={version="=0.4.45",default-features=false,features=["std"]}
[workspace]
''')
    values = [None, False, True, -1, 0, 1, 2, 2.0, 2.5, 2**53+1, 2**63, 2**64-1,
        "", "2", "other", "Hello world", "中文😀", {}, [], [None], [2], [2, 3], [[2]],
        [None, 2], [None, 3], [{}], [[2], None], [True, False], "1970-01-01",
        "1970-01-01T00:00:00.000000001Z", "1969-12-31T23:59:60.5Z", "not a date"]
    specs = [{'match':{kind:value}} for kind,value in [
        ('value',2),('value','2'),('value',True),('any',[]),('except',[]),
        ('any',[2,3]),('except',[2,3]),('any',['2','other']),('except',['2','other']),
        ('any',list(range(20))),('except',list(range(20))),('text','world'),('text',''),
        ('phrase','Hello world'),('prefix','He'),('prefix',''),('text','😀'),
        ('text_any','absent\u3000world\u00a0😀'),('text_any',' \t\n'),('text_any','')]]
    bounds = [{}, {'lt':2}, {'gt':2}, {'lte':2}, {'gte':2}, {'gt':2,'lt':3},
              {'gte':2,'lte':2}, {'gt':5,'lt':0}, {'gte':None}, {'gte':2**64-1}]
    specs += [{'range':b} for b in bounds]
    specs += [{'values_count':b} for b in bounds]
    specs += [{key:flag} for key in ('is_empty','is_null') for flag in (True,False)]
    specs += [{'range':{'gte':'1970-01-01','lt':'1970-01-01T00:00:00.000000002Z'}},
        {'range':{'gt':'1970-01-01T00:00:00.000000001Z'}},
        {'match':{'value':2},'range':{'lt':0}},
        {'match':{'value':2},'is_empty':True},
        {'is_empty':False,'is_null':True},
        {'values_count':{'lte':0},'is_empty':False,'match':{'value':2}}]
    cases = []
    def field(key='a',**kwargs): return dict(kind='field',key=key,**kwargs)
    def add(payload, filt): cases.append(dict(payload=payload,filter=filt))
    for spec in specs:
        for payload in [{}, *[{'a':v} for v in values]]:
            add(payload,field(**spec))
            add({'root':[payload,{}]},field('root[].a',**spec))
    point = lambda x,y: dict(lon=x,lat=y)
    geo_values=[point(0,0),point(1,1),point(-1,0),point(0,1),point(180,0),point(-180,0),
                point(179,0),point(-179,0),point(181,0),point(360,0),point(0,91),
                point('0',0),point(None,0),point(True,0),{'lon':0},[0,0],None]
    rng=random.Random(20261030)
    geo_values += [point(rng.uniform(-720,720),rng.uniform(-180,180)) for _ in range(100)]
    geo_specs=[{'geo_bounding_box':{'top_left':point(-1,1),'bottom_right':point(1,-1)}},
        {'geo_bounding_box':{'top_left':point(170,10),'bottom_right':point(-170,-10)}},
        {'geo_bounding_box':{'top_left':point(1,-1),'bottom_right':point(-1,1)}}]
    geo_specs += [{'geo_radius':{'center':origin,'radius':r}} for origin in [point(0,0),point(180,0),[0,90]]
                 for r in [-1,0,1,111195.0802335329,1e7,1e9]]
    for spec in geo_specs:
        for value in geo_values:
            for payload in [{'a':value},{'a':[None,value]},{}]:
                add(payload,field(**spec))
    same = dict(kind='all',children=[field('food',match={'value':'meat'}),field('likes',match={'value':True})])
    nested = dict(kind='nested',key='diet',filter=same)
    roots=[{}, {'diet':None},{'diet':{}},{'diet':[]},
        {'diet':[{'food':'meat','likes':False},{'food':'plants','likes':True}]},
        {'diet':[{'food':'meat','likes':True}]},
        {'diet':[None,2,[{'food':'meat','likes':True}],{'food':'meat','likes':True}]},
        {'diet':{'food':'meat','likes':True}}]
    for root in roots:
        for filt in [nested,dict(nested,key='diet[]'),dict(nested,key='diet[0]'),
                     dict(kind='not',child=nested), dict(kind='all',children=[]),dict(kind='any',children=[])]:
            add(root,filt)
        for minimum in [0,1,2,3,2**64-1]:
            add(root,dict(kind='at_least',min_count=minimum,children=[nested,field('diet',is_empty=True)]))
        add({'groups':[root,{}]},dict(kind='nested',key='groups',filter=nested))
    for key in ['', 'nul\0key', 'a.b', '中文']:
        add({'diet':[{key:3}]},dict(kind='nested',key='diet',filter=field('"'+key+'"',match={'value':3})))
    for spec in [{'match':{'value':2.5}},{'match':{'any':[1,'x']}},{'match':{'except':[True]}},
                 {'range':{'gt':'invalid'}},{'range':{'gt':'1970-01-01','lt':2}},
                 {'range':{'lt':True}},{'values_count':{'lt':-1}},{'values_count':{'gt':1.5}},
                 {'geo_radius':{'center':point(181,0),'radius':1}}, {'is_null':0}]:
        add({'a':2},field(**spec))
    if cases_override is not None:
        cases = cases_override
    (build/'input.json').write_text(json.dumps(cases,ensure_ascii=True))
    lock=target/'Cargo.lock'
    if lock.exists():
        (build/'Cargo.lock').write_bytes(lock.read_bytes())
    else:
        subprocess.run(['rtk','proxy','cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    subprocess.run(['rtk','proxy','cargo','build','--offline','--locked','--release','--manifest-path',str(build/'Cargo.toml')],check=True)
    lock.write_bytes((build/'Cargo.lock').read_bytes())
    output=json.loads(subprocess.check_output([str(build/'target/release/akasha-payload-filter-reference'),str(build/'input.json')],text=True))
    meta=dict(revision=REVISION,sources=sources,units=units,
        scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),cargo_lock_sha256=hashlib.sha256(lock.read_bytes()).hexdigest())
    text=json.dumps(meta,indent=2)[:-2]+',\n  "cases": [\n'
    text+=',\n'.join('    '+json.dumps(row,ensure_ascii=True,separators=(',',':')) for row in output)+'\n  ]\n}\n'
    (target/'filters.json').write_text(text)
    print(f'{len(output)} source filter cases; {sum("error" in r for r in output)} errors; {len(units)} source units')


if __name__ == '__main__':
    main()
