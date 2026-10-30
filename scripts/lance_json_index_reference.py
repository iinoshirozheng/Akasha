"""Execute unchanged pinned Lance JSON-index batch methods with real Arrow/jsonb."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tarfile

from lance_json_functions_reference import unit

ROOT = Path(__file__).resolve().parents[1]
REVISION = "ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inputs():
    corpus = json.loads((ROOT / "tests/fixtures/jsonb-codec/cases.json").read_text())
    rows = [dict(bodies=[row["hex"]], path="$") for row in corpus["cases"] + corpus["legacy"]]
    # Ordering, nulls, exact matching, multi-select, and batch validation before
    # conversion. Expected values are always supplied by original source.
    for texts in [[], [None], ["null", None], ["1", "1.5"], ["1.5", "1"],
                  ["true", "false"], ['"a"', '"漢字😀"'], ["[]", "{}"],
                  ["NaN", "Infinity", "-Infinity", "-0.0", "1"],
                  ["{a:1}", "{a:2.5}", "{}", None],
                  ["{a:[1,2],b:null}", "{a:[3],b:4}"]]:
        for path in ["$", "$.a", "$.a[*]", "$.*", "$[0,0]"]:
            rows.append(dict(texts=texts, path=path))
    for tag in [None, *range(9), 255]:
        for text in [None, "null", "true", "1", "1.5", '"a"', "[]", "{}"]:
            rows.append(dict(texts=[text], path="$", tags=[tag]))
    for texts, tags in [(["true", "1"], [2, 4]), (["1", "true"], [2, 255]),
                        ([None, "1"], [255, 2]), (["1", None], [2, 255]),
                        (["1", "true"], [2, None]), ([None, "1"], [None, 2]),
                        (["true", "1"], [0, 2])]:
        rows.append(dict(texts=texts, path="$.a'b", tags=tags))
    return rows


def main():
    source = ROOT / "reference/lance"
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == REVISION
    index = source / "rust/lance-index/src/scalar/json.rs"
    udf = source / "rust/lance-datafusion/src/udf/json.rs"
    for file in [index, udf]:
        assert file.read_bytes() == subprocess.check_output(["git", "-C", str(source), "show", f"{REVISION}:{file.relative_to(source)}"])
    build = ROOT / ".build/lance-json-index-reference"
    output = ROOT / "tests/fixtures/lance-json-index"
    (build / "src").mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    names = ["infer_type_from_batch", "validate_json_types", "convert_batch_by_type"]
    units = {name: unit(index.read_text(), name, "    ") for name in names}
    original = udf.read_text()
    enum = original[original.index("/// Represents the type"):original.index("/// Common helper")]
    common_names = ["execution_error", "parse_json_path"]
    helpers = {n: unit(original, n, "    ") for n in common_names}
    helpers["extract_json_path_with_type"] = unit(original, "extract_json_path_with_type")
    adapter = '''use arrow_array::{Array,LargeBinaryArray,RecordBatch,StructArray,UInt8Array};
use arrow_schema::{DataType,Schema};
use std::sync::Arc;
#[derive(Debug)] pub struct Error(String);
impl Error { fn invalid_input_source(e: Box<dyn std::error::Error + Send + Sync>) -> Self { Self(e.to_string()) } }
impl From<arrow_schema::ArrowError> for Error { fn from(e: arrow_schema::ArrowError)->Self { Self(e.to_string()) } }
type Result<T> = std::result::Result<T,Error>;
#[derive(Debug)] enum DataFusionError { Execution(String) }
'''
    # UDF error alias is scoped separately from the Lance-index error adapter.
    udf_module = "pub mod udf { use super::JsonbType; use super::DataFusionError; type Result<T> = std::result::Result<T,DataFusionError>; mod common { use super::*;\n"
    udf_module += "\n".join(helpers[n] for n in common_names) + "\n}\n"
    udf_module += helpers["extract_json_path_with_type"] + '''
pub fn extract(b: &[u8], path: &str) -> std::result::Result<Option<(Vec<u8>,u8)>,String> {
    extract_json_path_with_type(b,path).map_err(|DataFusionError::Execution(s)|s)
}
}\n'''
    module = adapter + enum + udf_module + "pub struct JsonIndexPlugin;\nimpl JsonIndexPlugin {\n" + "\n".join(units.values()) + "\n}\n"
    # Make only visibility adapters; unchanged bodies remain hashed separately.
    module += '''pub fn infer(batch: &RecordBatch,path: &str)->std::result::Result<Option<DataType>,String> {JsonIndexPlugin::infer_type_from_batch(batch,path).map_err(|e|e.0)}
pub fn convert(batch:RecordBatch,schema:Arc<Schema>,pass:&[usize],target:&DataType,path:&str)->std::result::Result<RecordBatch,String> {JsonIndexPlugin::convert_batch_by_type(batch,schema,pass,target,path).map_err(|e|e.0)}
'''
    (build / "src/source.rs").write_text(module)
    prior = ROOT / "tests/fixtures/lance-json"
    evidence = json.loads((prior / "sources.json").read_text())
    manifest = '[package]\nname="akasha-lance-json-index-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    dependencies = []
    for dep in evidence["dependencies"]:
        name, version = dep["name"], dep["version"]
        config = f'"={version}"'
        if name == "jsonb":
            config = f'{{version="={version}",default-features=false,features=["databend"]}}'
        elif name == "serde_json":
            config = f'{{version="={version}",features=["preserve_order"]}}'
        manifest += f'{name}={config}\n'
        directory = next((Path.home()/".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive = Path.home()/".cargo/registry/cache"/directory.parent.name/f"{name}-{version}.crate"
        assert sha(archive) == dep["checksum"]
        files = list(dep["files"])
        if name == "jsonb" and not any(f["path"] == "src/core/databend/de.rs" for f in files):
            files.append(dict(path="src/core/databend/de.rs", sha256=sha(directory/"src/core/databend/de.rs")))
        with tarfile.open(archive) as tar:
            for file in files:
                assert sha(directory/file["path"]) == file["sha256"]
                assert (directory/file["path"]).read_bytes() == tar.extractfile(f'{name}-{version}/{file["path"]}').read()
        dependencies.append({**dep, "files": files})
    (build / "Cargo.toml").write_text(manifest + "[workspace]\n")
    shutil.copyfile(prior / "Cargo.lock", build / "Cargo.lock")
    # Reuse exact locked dependencies; the package name is the only lock change.
    lock = (build / "Cargo.lock").read_text().replace('name = "akasha-lance-json-reference"', 'name = "akasha-lance-json-index-reference"')
    (build / "Cargo.lock").write_text(lock)
    shutil.copyfile(ROOT / "scripts/lance_json_index_reference.rs", build / "src/main.rs")
    (build / "inputs.json").write_text(json.dumps(inputs(), ensure_ascii=False, separators=(",", ":")))
    data = subprocess.check_output(["cargo", "run", "--quiet", "--release", "--locked", "--offline", "--manifest-path", str(build/"Cargo.toml"), "--", str(build/"inputs.json")], env={**os.environ, "CARGO_TARGET_DIR": str(ROOT/".build/lance-json-reference/target")})
    (output / "cases.json").write_bytes(data)
    shutil.copyfile(build/"Cargo.lock", output/"Cargo.lock")
    metadata = dict(lance_revision=REVISION,
        sources=[dict(path=str(p.relative_to(source)), sha256=sha(p)) for p in [index, udf]],
        units={n: hashlib.sha256(body.encode()).hexdigest() for n, body in {**units, **helpers}.items()},
        dependencies=dependencies, generator_sha256=sha(__file__),
        scaffold_sha256=sha(ROOT/"scripts/lance_json_index_reference.rs"),
        input_fixture_sha256=sha(ROOT/"tests/fixtures/jsonb-codec/cases.json"),
        cases_sha256=sha(output/"cases.json"), lock_sha256=sha(output/"Cargo.lock"),
        adapter="Lance/Error and DataFusion/Execution carriers; Arrow transport, visibility and panic capture. Three original index methods, original UDF extractor and jsonb Serde deserializer execute unchanged. No target index/planner/stream/sort implementation is claimed.",
        rustc=subprocess.check_output(["rustc", "-Vv"], text=True).strip())
    (output/"sources.json").write_text(json.dumps(metadata, indent=2)+"\n")
    print("Lance JSON-index input scenarios:", len(json.loads(data)))


if __name__ == "__main__":
    main()
