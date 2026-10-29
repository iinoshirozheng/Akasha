"""Compile pinned Qdrant lookup/reference-selection functions without edits."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

from qdrant_dbsf_reference import extract

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"
PATHS = ["lib/collection/src/common/fetch_vectors.rs",
         "lib/collection/src/operations/universal_query/collection_query.rs",
         "lib/collection/src/common/retrieve_request_trait.rs"]


def main() -> None:
    sources = [subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
                                       "show", f"{REVISION}:{path}"], text=True) for path in PATHS]
    fetch, query, traits = sources
    request = query[query.index("impl CollectionQueryRequest {"):]
    functions = [extract(fetch, "pub fn get("), extract(fetch, "pub fn resolve_reference<'a>("),
                 extract(query, "pub fn as_id("), extract(traits, "pub fn get_referenced_ids("),
                 extract(request, "fn get_lookup_collection("), extract(request, "fn get_lookup_vector_name("),
                 extract(request, "fn get_referenced_point_ids_on_collection(")]
    scaffold = r"""
use std::collections::{HashMap, BTreeSet};
type CollectionName = String;
type PointIdType = i64;
type VectorName = str;
type VectorNameBuf = String;
type VectorInternal = Vec<f32>;
#[derive(Clone)]
struct RecordInternal { vectors: HashMap<String, VectorInternal> }
impl RecordInternal {
    fn get_vector_by_name(&self, name: &str) -> Option<&VectorInternal> { self.vectors.get(name) }
}
struct ReferencedVectors {
    collection_mapping: HashMap<CollectionName, HashMap<PointIdType, RecordInternal>>,
    default_mapping: HashMap<PointIdType, RecordInternal>,
}
impl ReferencedVectors { __GET__ __RESOLVE__ }
enum VectorInputInternal { Id(PointIdType), Vector(VectorInternal) }
impl VectorInputInternal { __AS_ID__ }
enum VectorQuery<T> { Nearest(T) }
impl<T> VectorQuery<T> {
    // Nearest-only representation shim for the one-element upstream flat_iter.
    fn flat_iter(&self) -> Box<dyn Iterator<Item=&T> + '_> {
        match self { Self::Nearest(input) => Box::new(std::iter::once(input)) }
    }
}
impl VectorQuery<VectorInputInternal> { __REFERENCES__ }
enum Query { Vector(VectorQuery<VectorInputInternal>) }
struct LookupLocation { collection: String, vector: Option<String> }
struct CollectionQueryRequest {
    lookup_from: Option<LookupLocation>, using: String,
    query: Option<Query>, prefetch: Vec<CollectionQueryRequest>,
}
impl CollectionQueryRequest { __COLLECTION__ __VECTOR_NAME__ __EXCLUDE__ }
fn point(v: &[f32], alternate: &[f32]) -> RecordInternal {
    let mut vectors = HashMap::new();
    if !v.is_empty() { vectors.insert("v".into(), v.to_vec()); }
    if !alternate.is_empty() { vectors.insert("alternate".into(), alternate.to_vec()); }
    RecordInternal { vectors }
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let target: HashMap<_, _> = [(1, point(&[1.,2.], &[2.,1.])), (2, point(&[-1.,3.], &[])),
                               (3, point(&[], &[]))].into_iter().collect();
    let other: HashMap<_, _> = [(1, point(&[9.,8.], &[8.,9.])), (2, point(&[4.,5.], &[]))].into_iter().collect();
    let records = ReferencedVectors { default_mapping: target.clone(),
        collection_mapping: [("target".to_owned(), target), ("other".to_owned(), other)].into_iter().collect() };
    let lookup_from = if args[0] == "none" { None } else {
        Some(LookupLocation { collection: args[0].clone(),
            vector: if args[1] == "none" { None } else { Some(args[1].clone()) } })
    };
    let request = CollectionQueryRequest { lookup_from, using: "v".into(), prefetch: vec![],
        query: Some(Query::Vector(VectorQuery::Nearest(VectorInputInternal::Id(args[2].parse().unwrap())))) };
    let resolved = records.resolve_reference(request.get_lookup_collection(),
        &request.get_lookup_vector_name(), VectorInputInternal::Id(args[2].parse().unwrap()));
    match resolved {
        Some(vector) => println!("{:?}", vector),
        None => println!("null"),
    }
    let excluded: BTreeSet<_> = request.get_referenced_point_ids_on_collection("target").into_iter().collect();
    println!("{:?}", excluded.into_iter().collect::<Vec<_>>());
}
"""
    for key, function in zip(["GET", "RESOLVE", "AS_ID", "REFERENCES", "COLLECTION", "VECTOR_NAME", "EXCLUDE"], functions):
        scaffold = scaffold.replace(f"__{key}__", function)
    build = ROOT / ".build/qdrant-point-lookup-reference"
    build.mkdir(parents=True, exist_ok=True)
    rust, binary = build / "reference.rs", build / "reference"
    rust.write_text(scaffold)
    subprocess.run(["rtk", "proxy", "rustc", "--edition=2024", "-A", "dead_code", str(rust), "-o", str(binary)], check=True)
    cases = []
    for collection in (None, "target", "other", "missing"):
        for field in (None, "v", "alternate", "missing") if collection else (None,):
            for id in (1, 2, 3, 99):
                output = subprocess.check_output([str(binary), collection or "none", field or "none", str(id)], text=True).splitlines()
                cases.append(dict(lookup_collection=collection, lookup_field=field, id=id,
                                  resolved=json.loads(output[0]), excluded=json.loads(output[1])))
    fixture = dict(upstream="https://github.com/qdrant/qdrant", revision=REVISION,
                   sources=[dict(path=p, sha256=hashlib.sha256(s.encode()).hexdigest()) for p, s in zip(PATHS, sources)],
                   functions=["ReferencedVectors::get", "ReferencedVectors::resolve_reference", "VectorInputInternal::as_id",
                              "VectorQuery::get_referenced_ids", "get_lookup_collection", "get_lookup_vector_name",
                              "get_referenced_point_ids_on_collection"],
                   extracted_sha256=hashlib.sha256("\n\n".join(functions).encode()).hexdigest(),
                   scaffold_sha256=hashlib.sha256(scaffold.encode()).hexdigest(),
                   adapter="Verbatim functions; HashMap, numeric IDs, dense vector/record types and nearest-only flat_iter; canonicalized excluded-ID set",
                   cases=cases)
    target = ROOT / "tests/fixtures/qdrant-point-lookup"
    target.mkdir(parents=True, exist_ok=True)
    (target / "lookup.json").write_text(json.dumps(fixture, indent=2) + "\n")
    print(json.dumps(dict(cases=len(cases), extracted_sha256=fixture["extracted_sha256"])))


if __name__ == "__main__":
    main()
