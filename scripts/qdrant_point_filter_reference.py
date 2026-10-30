"""Original Qdrant point/path checker and pinned SipHash oracle.

Python supplies inputs only. Storage adapters expose existing IDs and vector
presence; source condition arms, nested isolation, Boolean combinators, whole
path predicates, Slice::check/validation/hash and siphasher execute in Rust.
"""
from __future__ import annotations

import random
import re
import uuid
import hashlib
import json

from qdrant_dbsf_reference import extract
from qdrant_payload_filter_reference import ROOT, main as generate


def extend(code, types, paths, query, source, unit):
    utils = source("lib/segment/src/common/utils.rs")
    extra = '''
use std::{collections::{HashMap,HashSet},hash::Hasher,num::NonZeroU32,cell::RefCell};
use uuid::Uuid;
type PointIdType=ExtendedPointId;
type VectorNameBuf=String;
type MaybeArc<T>=T;
type AHashSet<T>=HashSet<T>;
type ValidationError=OperationError;
impl OperationError {fn new(s:&str)->Self {Self(s.into())}}
struct IdTrackerEnum(Option<PointIdType>);
impl IdTrackerEnum {fn external_id(&self,_offset:u32)->Option<PointIdType>{self.0}}
struct VectorStorage {deleted:bool}
impl VectorStorage {fn is_deleted_vector(&self,_offset:u32)->bool{self.deleted}}
trait PayloadContainer {fn get_value(&self,key:&JsonPath)->Vec<&Value>;}
impl PayloadContainer for serde_json::Map<String,Value> {
    fn get_value(&self,key:&JsonPath)->Vec<&Value>{key.value_get(self)}
}
'''
    for name in ("ExtendedPointId", "PayloadField", "IsEmptyCondition", "IsNullCondition",
                 "HasIdCondition", "HasVectorCondition", "Slice", "SliceCondition"):
        kind = "enum" if name == "ExtendedPointId" else "struct"
        body = unit(types, f"pub {kind} {name} {{")
        body = re.sub(r"\s*#\[schemars\([^\n]*\)\]", "", body)
        extra += ("#[derive(Clone,Copy,Debug,PartialEq,Eq,Hash,Deserialize)]\n#[serde(untagged)]\n"
                  if name == "ExtendedPointId" else "#[derive(Deserialize)]\n") + body + "\n"
    for sig in ("impl Slice {", "pub fn slice_point_id_hash(", "pub fn validate_slice_condition("):
        extra += unit(types, sig) + "\n"
    extra += "mod path_checks { use super::*;\n"
    for sig in ("pub fn check_is_empty<'a>", "pub fn check_is_null<'a>"):
        extra += unit(utils, sig) + "\n"
    for sig in ("pub fn check_is_empty_condition(", "pub fn check_is_null_condition("):
        extra += unit(query, sig) + "\n"
    extra += "}\nuse path_checks::{check_is_empty_condition,check_is_null_condition};\n"

    code = code.replace("IsEmpty(()),IsNull(()),HasId(()),HasVector(()),Slice(())",
                        "IsEmpty(IsEmptyCondition),IsNull(IsNullCondition),HasId(HasIdCondition),HasVector(HasVectorCondition),Slice(SliceCondition)")
    branches = '''
        "is_empty"=>Condition::IsEmpty(serde_json::from_value(json!({"is_empty":{"key":v["key"]}})).map_err(|e|e.to_string())?),
        "is_null"=>Condition::IsNull(serde_json::from_value(json!({"is_null":{"key":v["key"]}})).map_err(|e|e.to_string())?),
        "has_id"=>Condition::HasId(serde_json::from_value(json!({"has_id":v["ids"]})).map_err(|e|e.to_string())?),
        "has_vector"=>Condition::HasVector(serde_json::from_value(json!({"has_vector":v["name"]})).map_err(|e|e.to_string())?),
        "slice"=>{
            let c:SliceCondition=serde_json::from_value(json!({"slice":{"total":v["total"],"index":v["index"]}})).map_err(|e|e.to_string())?;
            validate_slice_condition(&c).map_err(|e|e.to_string())?;
            Condition::Slice(c)
        },
'''
    code = code.replace('        "field"=>Condition::Field', branches + '        "field"=>Condition::Field')
    original = unit(query, "pub fn check_payload<'a, R, FI>")
    body = original[original.index("    let checker ="):]
    field_start = body.index("        Condition::Field(")
    field_end = body.index("        Condition::IsEmpty(", field_start)
    # The unchanged plain field path already captured by the base oracle.
    prior = extract(code, "fn matches(")
    plain_start = prior.index("        Condition::Field(")
    plain_end = prior.index("Condition::Nested(", plain_start)
    body = body[:field_start] + prior[plain_start:plain_end] + body[field_end:]
    body = body.replace("get_payload().deref()", "payload")
    body = body.replace("get_payload()\n                .get_value", "payload.get_value")
    body = body.replace("            let nested_indexes = select_nested_indexes(&nested_path, field_indexes);\n", "")
    nested_start = body.index("                    check_payload(")
    nested_end = body.index("\n                })", nested_start)
    body = (body[:nested_start] + "                    matches(object, &nested.filter, None, &HashMap::new())" + body[nested_end:])
    start = body.index("        Condition::CustomIdChecker(")
    end = body.index("        Condition::Filter(", start)
    body = body[:start] + "        Condition::CustomIdChecker(_) => unreachable!(),\n\n" + body[end:]
    adapted = '''fn matches(payload:&serde_json::Map<String,Value>,query:&Filter,
    id:Option<PointIdType>,vector_storages:&HashMap<String,RefCell<VectorStorage>>)->bool {
    let tracker=IdTrackerEnum(id);
    let id_tracker=Some(&tracker);
    let point_id=0;
''' + body
    code = code.replace(prior, adapted)
    old = 'matches(row["payload"].as_object().unwrap(),&Filter{must:Some(vec![c]),..Default::default()})'
    new = '''matches(row["payload"].as_object().unwrap(),&Filter{must:Some(vec![c]),..Default::default()},
        serde_json::from_value(row["id"].clone()).ok(),&row["vectors"].as_array().unwrap().iter().map(|v|
            (v.as_str().unwrap().to_owned(),RefCell::new(VectorStorage{deleted:false}))).collect())'''
    assert old in code
    code = code.replace(old, new)
    prefix, main = code.split("fn main() {", 1)
    assert main.count("        result\n") == 1
    main = main.replace("        result\n", '''
        if let Some(bytes)=row["hash_bytes"].as_array() {
            let bytes:Vec<u8>=bytes.iter().map(|v|v.as_u64().unwrap() as u8).collect();
            let mut hasher=siphasher::sip::SipHasher24::new();
            hasher.write(&bytes);
            result["hash"]=json!(hasher.finish());
        }
        if !row["hash_id"].is_null() {
            let id:ExtendedPointId=serde_json::from_value(row["hash_id"].clone()).unwrap();
            result["id_hash"]=json!(slice_point_id_hash(id));
        }
        result
''')
    return extra + prefix + "fn main() {" + main


def cases():
    rows = []
    def add(filt, payload=None, id=42, vectors=(), **extra):
        rows.append(dict(filter=filt, payload=payload or {}, id=id, vectors=list(vectors), **extra))
    leaves = [dict(kind="has_id",ids=ids) for ids in ([],[42],[0,1],[42,42],[0,42,2**63-1])]
    leaves += [dict(kind="has_vector",name=name) for name in ("","sparse","v","absent","中文")]
    leaves += [dict(kind="slice",total=t,index=i) for t in (1,2,3,4,7,32,2**32-1) for i in sorted({0,t//2,t-1})]
    for id in (None,0,1,41,42,43,2**63-1):
        for vectors in ([],[""],["v"],["","sparse","v","中文"]):
            for leaf in leaves:
                add(leaf,id=id,vectors=vectors)
                add(dict(kind="not",child=leaf),id=id,vectors=vectors)
                for payload in ({"items":[{},{}]}, {"items":[None,3]}, {}):
                    add(dict(kind="nested",key="items",filter=leaf),payload,id,vectors)
                    add(dict(kind="nested",key="items",filter=dict(kind="not",child=leaf)),payload,id,vectors)
    values = [None,[],[None],[None,1],{},0,False,"",[[]],[{},None],[[None]],1]
    payloads = [{}, *[{"a":v} for v in values]]
    payloads += [{"items":[{"a":a},{"a":b},{}]} for a in values for b in values]
    for payload in payloads:
        for key in ("a","a[]","items[].a","items[].a[]","items[0].a","missing"):
            for kind in ("is_empty","is_null"):
                add(dict(kind=kind,key=key),payload)
                add(dict(kind="field",key=key,**{kind:True}),payload)
    rng = random.Random(20261030)
    for _ in range(400):
        children = rng.sample(leaves,3)
        filt = dict(kind="at_least",min_count=rng.randrange(5),children=children)
        add(filt, {"items":[{}]}, rng.choice([0,42,2**63-1]),rng.choice([[],["v"],["","sparse"]]))
    for total,index in [(0,0),(1,1),(3,3),(-1,0),(2,-1),(2**32,0),(True,0),(2,False),(2.0,0),(2,0.5)]:
        add(dict(kind="slice",total=total,index=index))
    for kind in ("is_empty","is_null"):
        for key in (None,1,False,"bad.","[]"):
            add(dict(kind=kind,key=key))
    for ids in (None,True,[True],[1.0],["not-id"]):
        add(dict(kind="has_id",ids=ids))
    for name in (None,1,True,[]):
        add(dict(kind="has_vector",name=name))
    all_filter = dict(kind="all",children=[])
    for length in range(513):
        for data in ([0]*length,[255]*length,[rng.randrange(256) for _ in range(length)]):
            add(all_filter,hash_bytes=data)
    for id in [0,1,42,2**63-1,2**63,2**64-1,*[rng.getrandbits(64) for _ in range(512)]]:
        add(all_filter,hash_id=id,hash_bytes=list(id.to_bytes(8,"little")))
    for id in [uuid.UUID(int=0),uuid.UUID(int=2**128-1),*[uuid.UUID(int=rng.getrandbits(128)) for _ in range(128)]]:
        add(all_filter,hash_id=str(id),hash_bytes=list(id.bytes))
    return rows


def dependency_provenance():
    from qdrant_polygon_reference import dependency
    directory, record = dependency("siphasher", "1.0.3", [
        "src/sip.rs", "src/common.rs", "COPYING", "Cargo.toml.orig", ".cargo_vcs_info.json"])
    record["units"] = {}
    for path, signatures in {
        "src/sip.rs": ["fn reset(&mut self)", "fn hash(&self, msg:",
                       "fn finish_with_state(", "impl Sip for Sip24Rounds {"],
        "src/common.rs": ["macro_rules! compress {", "pub unsafe fn u8to64_le("],
    }.items():
        for signature in signatures:
            record["units"][path + ":" + signature] = hashlib.sha256(
                extract((directory/path).read_text(), signature).encode()).hexdigest()
    _, uuid_record = dependency("uuid", "1.24.0", ["src/lib.rs", "Cargo.toml.orig", ".cargo_vcs_info.json"])
    target=ROOT/"tests/fixtures/qdrant-point-filter"
    (target/"dependencies.json").write_text(json.dumps(dict(siphasher=record,uuid=uuid_record),indent=2)+"\n")
    (ROOT/"docs/upstream/licenses/siphasher-COPYING.txt").write_bytes((directory/"COPYING").read_bytes())


if __name__ == "__main__":
    generate(cases_override=cases(),fixture_name="qdrant-point-filter",source_adapter=extend,
             extra_dependencies='siphasher="=1.0.3"\nuuid={version="=1.24.0",features=["serde"]}\n')
    dependency_provenance()
