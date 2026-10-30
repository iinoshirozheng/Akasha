"""Run unchanged pinned Lance JSON consumers; adapt only DataFusion error/registration types."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
OPS = ["json_path", "json_extract", "json_extract_with_type", "json_exists", "json_get", "json_get_string", "json_get_int", "json_get_float", "json_get_bool", "json_array_contains", "json_array_length"]


def unit(text, name, indent=""):
    match = re.search(r"(?m)^"+indent+r"(?:pub )?fn "+name+r"\(", text)
    assert match, name
    end = text.index("\n"+indent+"}", match.start()) + len(indent) + 2
    return text[match.start():end]


def inputs():
    selector = json.loads((ROOT/"tests/fixtures/jsonb-selector/cases.json").read_text())
    writer = json.loads((ROOT/"tests/fixtures/jsonb-writer/cases.json").read_text())
    cases = []
    def add(ops, bodies, args, values=None, **extra):
        cases.append(dict(ops=ops, bodies=bodies, args=args, values=values, **extra))
    # Reuse complete dependency oracles; consumer corpus samples every path family
    # and includes all initial explicit scenarios, errors and repeated matches.
    for i, row in enumerate(selector["cases"]):
        if i >= 500 and i % 13:
            continue
        body, path = row["pair"]
        try:
            text = bytes.fromhex(selector["paths"][path]).decode("utf-8")
        except UnicodeDecodeError:
            continue
        add([0, 1, 2, 3, 9, 10], [selector["docs"][body]], [text], [str(i%4)], selector_case=i)
    # Type tags and rendered values: all scalar/container/extension/legacy bodies.
    for row in writer:
        add([0, 1, 2, 3, 10], [row["hex"]], ["$"])
    codec = json.loads((ROOT/"tests/fixtures/jsonb-codec/cases.json").read_text())
    # Original builders wrap inputs, avoiding hand-built expected JSONB results.
    for row in codec["cases"] + codec["legacy"]:
        add([4,5,6,7,8], [row["hex"]], ["v"], wrap="object")
        add([4], [row["hex"]], ["+0"], wrap="array")
    # Public Arrow row semantics: broadcast, null masks, slicing, batch failure.
    texts = ["{v:null}", "{v:2.5}", "{v:'YES'}", "{v:[1,'a','a\\b','a\"b',null]}", "{v:{x:1}}", "[10,20]", "null", "true", "{}"]
    encoded = [dict(text=x) for x in texts]
    keys = ["v", "0", "+0", "00", "-0", "-1", "1", "2", "18446744073709551615", "18446744073709551616", " 0", "0 ", "", "V", "１"]
    for key in keys:
        add([4,5,6,7,8], encoded+[None], [key])
    for path in ["$", "$.v", "$.missing", "$.*", "$[*]", "$.v[*]", "$[0,0]", "$[", "$.v / 0", "$ "]:
        for needle in ["1", "a", "a\\b", "a\"b", "null", "[1]", "{\"x\":1}"]:
            add([0,1,2,3,9,10], encoded+[None], [path], [needle], sliced=True)
    add(list(range(11)), [None,None], ["$["] , ["x"])
    add(list(range(11)), [dict(text="{v:1}"),None,dict(text="[2]")], [None], [None])
    add(list(range(11)), [None,dict(text="{v:1}"),dict(text="[2]")], ["$[",None,"$"], ["a","b","2"], sliced=True)
    # A malformed body in a null-path row is never decoded by the source.
    add(list(range(11)), ["00"], [None], [None])
    add([9], [dict(text="[1]")], ["$["], [None])
    keyed = {"": None, "0": 10, "+0": 20, "00": 30, "a": 1, "A": 2, "a.b": "quoted", "a\nb": "line", "漢字😀": True, "Z": [1,2], "v": {"inner": 3}}
    for key in list(keyed)+["missing", "漢字", "a.b.c", "$.a", "-0", "z"]:
        add([4,5,6,7,8], [dict(text=json.dumps(keyed,ensure_ascii=False))], [key])
    add(list(range(11)), [], [], [])
    return cases


def main():
    prior = ROOT/"tests/fixtures/lance-json"
    evidence = json.loads((prior/"sources.json").read_text())
    source = ROOT/"reference/lance"
    revision = subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
    assert revision == evidence["lance_revision"]
    build = ROOT/".build/lance-json-functions-reference"
    out = ROOT/"tests/fixtures/lance-json-functions"
    (build/"src").mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    arrow = source/evidence["lance_source"]["path"]
    assert sha(arrow) == evidence["lance_source"]["sha256"]
    udf = source/"rust/lance-datafusion/src/udf/json.rs"
    original = udf.read_text()
    assert udf.read_bytes() == subprocess.check_output(["git","-C",str(source),"show",f"{revision}:rust/lance-datafusion/src/udf/json.rs"])
    common_names = ["execution_error","validate_arg_count","extract_jsonb_array","extract_string_array","get_string_value_at","get_json_value_by_key","parse_json_path"]
    names = ["json_value_to_string","json_value_to_int","json_value_to_float","json_value_to_bool","extract_json_path_with_type","extract_json_path","check_json_path_exists","check_array_contains","get_array_length"] + [name+"_impl" for name in OPS[1:]]
    units = {name:unit(original,name,"    " if name in common_names else "") for name in common_names+names}
    header = original[original.index("use arrow_array::builder"):original.index("use datafusion::error")]
    enum = original[original.index("/// Represents the type"):original.index("/// Common helper")]
    # Error variant carries source messages unchanged; no DataFusion optimizer,
    # ColumnarValue scheduling or SQL UDF registration is claimed by this oracle.
    adapter = "use std::sync::Arc;\n#[derive(Debug)] enum DataFusionError { Execution(String) }\ntype Result<T> = std::result::Result<T,DataFusionError>;\n"
    module = header+adapter+enum+"mod common { use super::*;\n"+"\n".join(units[n] for n in common_names)+"\n}\n"+"\n".join(units[n] for n in names)
    module += "\npub fn run(op: usize, args: &[ArrayRef]) -> std::result::Result<ArrayRef,String> { let result = match op {\n"
    module += "\n".join(f"{i} => {op}_impl(args)," for i,op in enumerate(OPS) if i)
    module += '_ => unreachable!(), }; result.map_err(|DataFusionError::Execution(s)|s) }\n'
    (build/"src/lance_udf.rs").write_text(module)
    (build/"src/lance_json.rs").write_text(arrow.read_text()+"\n// Oracle-only constructor adapter; original methods above are unchanged.\npub fn oracle_raw_path(array: LargeBinaryArray, i: usize, path: &str) -> Result<Option<String>, ArrowError> { JsonArray { inner: array }.json_path(i, path) }\n")
    manifest = '[package]\nname="akasha-lance-json-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in evidence["dependencies"]:
        name,version=dep["name"],dep["version"]
        if name == "jsonb":manifest += f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n'
        elif name == "serde_json":manifest += f'{name}={{version="={version}",features=["preserve_order"]}}\n'
        else:manifest += f'{name}="={version}"\n'
        directory=next((Path.home()/".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive=Path.home()/".cargo/registry/cache"/directory.parent.name/f"{name}-{version}.crate"
        assert sha(archive)==dep["checksum"]
        with tarfile.open(archive) as tar:
            for item in dep["files"]:
                file=directory/item["path"]
                assert sha(file)==item["sha256"]
                assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{item["path"]}').read()
    (build/"Cargo.toml").write_text(manifest+'[workspace]\n')
    shutil.copyfile(prior/"Cargo.lock",build/"Cargo.lock")
    shutil.copyfile(ROOT/"scripts/lance_json_functions_reference.rs",build/"src/main.rs")
    (build/"inputs.json").write_text(json.dumps(inputs(),ensure_ascii=False,separators=(",",":")))
    data=subprocess.check_output(["cargo","run","--quiet","--release","--locked","--offline","--manifest-path",str(build/"Cargo.toml"),"--",str(build/"inputs.json")],env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(data);shutil.copyfile(build/"Cargo.lock",out/"Cargo.lock")
    metadata=dict(lance_revision=revision,sources=[dict(path=str(p.relative_to(source)),sha256=sha(p)) for p in [arrow,udf]],units={n:hashlib.sha256(s.encode()).hexdigest() for n,s in units.items()},dependencies=evidence["dependencies"],generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/"scripts/lance_json_functions_reference.rs"),cases_sha256=sha(out/"cases.json"),lock_sha256=sha(out/"Cargo.lock"),adapter="DataFusion Execution error enum and dispatch; all ten original UDF Arrow row function bodies unchanged. Full original Lance Arrow module plus raw constructor; json_path vectorization/null-path broadcast is outer transport around original per-row JsonArray::json_path, not a Lance SQL UDF")
    metadata["input_fixture_sha256"] = {f"tests/fixtures/{name}/cases.json": sha(ROOT/f"tests/fixtures/{name}/cases.json") for name in ["jsonb-selector","jsonb-writer","jsonb-codec"]}
    metadata["rustc"] = subprocess.check_output(["rustc","-Vv"],text=True).strip()
    (out/"sources.json").write_text(json.dumps(metadata,indent=2)+"\n")
    rows=json.loads(data);print('Lance consumer scenarios',len(rows),'operation results',sum(len(r['results']) for r in rows))

if __name__ == "__main__":main()
