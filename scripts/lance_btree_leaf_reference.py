"""Execute pinned Lance FlatIndex search/eval and SargableQuery::to_expr."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tarfile, tomllib
from lance_bitmap_reference import unit, inputs, REVISION
from lance_btree_lookup_reference import main as build_lookup_reference
ROOT = Path(__file__).resolve().parents[1]
def run(*args, **kwargs):
    return subprocess.check_output(["rtk", "proxy", *args], **kwargs)
def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def main():
    build_lookup_reference()
    lance=ROOT/"reference/lance"
    assert run("git","-C",str(lance),"rev-parse","HEAD",text=True).strip()==REVISION
    paths=["rust/lance-index/src/scalar.rs","rust/lance-index/src/scalar/btree/flat.rs", "rust/lance-index/src/scalar/btree.rs"]
    texts=[]
    for path in paths:
        data=(lance/path).read_bytes()
        assert data==run("git","-C",str(lance),"show",f"{REVISION}:{path}")
        texts.append(data.decode())
    units={"to_expr":unit(texts[0],"to_expr"),"escape_like_pattern":unit(texts[0],"escape_like_pattern","")}
    units.update({name:unit(texts[1],name) for name in ["search","eval_expr","ids","search_prebuilt","all","all_ignore_nulls","all_non_null"]})
    units.update({name:unit(texts[2],name) for name in ["search_page","search_with_options","compile_predicate"]})
    units["wrap_bound"]=unit(texts[2],"wrap_bound","")
    units["compute_next_prefix"]=unit(texts[0],"compute_next_prefix","")
    units["next_unicode_char"]=unit(texts[0],"next_unicode_char","")
    generated="use super::*;\n"+units["escape_like_pattern"]+"\nimpl SargableQuery {\n"+units["to_expr"]+"\n}\nimpl FlatIndex {\n"+"\n".join(units[n] for n in ["search","eval_expr","ids","search_prebuilt","all","all_ignore_nulls","all_non_null"])+"\n}\n"
    lookup=(ROOT/".build/lance-btree-lookup-reference/src/source.rs").read_text().split("pub fn query(")[0]
    generated=lookup+generated.removeprefix("use super::*;\n")+units["wrap_bound"]+units["compute_next_prefix"]+units["next_unicode_char"]+"\n"
    generated+="struct BTreeIndex{page_lookup:BTreeLookup,store:Arc<Vec<Arc<FlatIndex>>>,ranges_to_files:(),data_type:DataType}\nimpl BTreeIndex{\n"+"\n".join(units[n] for n in ["search_page","search_with_options","compile_predicate"])+"\n async fn lookup_page(&self,p:u32,r:LazyIndexReader,_:&dyn MetricsCollector)->Result<Arc<FlatIndex>>{Ok(r.0[p as usize].clone())}\n}\n"
    generated+=(ROOT/"scripts/lance_btree_paged_reference.rs").read_text()
    build=ROOT/".build/lance-btree-leaf-reference";out=ROOT/"tests/fixtures/lance-btree-leaf"
    (build/"src").mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/"src/source.rs").write_text(generated)
    shutil.copyfile(ROOT/"scripts/lance_btree_leaf_reference.rs",build/"src/main.rs")
    (build/"Cargo.toml").write_text("""[package]
name="akasha-lance-btree-leaf-reference"
version="0.1.0"
edition="2024"
[dependencies]
datafusion-common={version="=54.1.0",default-features=false}
datafusion-expr="=54.1.0"
datafusion-physical-expr="=54.1.0"
arrow-array="=58.4.0"
arrow-schema="=58.4.0"
arrow-select="=58.4.0"
arrow-arith="=58.4.0"
arrow-ord="=58.4.0"
futures="=0.3.32"
serde_json="=1.0.151"
[workspace]
""")
    if (out/"Cargo.lock").exists():
        shutil.copyfile(out/"Cargo.lock",build/"Cargo.lock")
    else:
        run("cargo","generate-lockfile","--manifest-path",str(build/"Cargo.toml"))
    cases=[]
    for i,original in enumerate(inputs()):
        if i%12 not in [0,1,11] and i!=60:continue
        cases.append(dict(type=original["type"],values=[r["value"] for r in original["old"]][:100],queries=[q for q in original["queries"] if q["op"] in {"eq","in","range","null"}]))
    (build/"inputs.json").write_text(json.dumps(cases,ensure_ascii=False))
    run("cargo","fetch","--locked","--manifest-path",str(build/"Cargo.toml"))
    result=run("cargo","run","--release","--quiet","--locked","--manifest-path",str(build/"Cargo.toml"),"--",str(build/"inputs.json"),env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(result);shutil.copyfile(build/"Cargo.lock",out/"Cargo.lock")
    dependencies=[]
    for dep in tomllib.loads((build/"Cargo.lock").read_text())["package"]:
        if "checksum" not in dep:continue
        name,version=dep["name"],dep["version"]
        directory=next((Path.home()/".cargo/registry/src").glob(f"*/{name}-{version}"))
        archive=Path.home()/".cargo/registry/cache"/directory.parent.name/f"{name}-{version}.crate"
        assert sha(archive)==dep["checksum"]
        item=dict(name=name,version=version,checksum=dep["checksum"])
        if name.startswith(("datafusion-","arrow-")):
            files=[]
            with tarfile.open(archive) as tar:
                for file in sorted((directory/"src").rglob("*.rs")):
                    rel=str(file.relative_to(directory))
                    assert file.read_bytes()==tar.extractfile(f"{name}-{version}/{rel}").read()
                    files.append([rel,sha(file)])
            item["verified_source_files"]=files
        dependencies.append(item)
    metadata=dict(revision=REVISION,dependencies=dependencies,input_generator_sha256=sha(ROOT/"scripts/lance_bitmap_reference.py"),lookup_generator_sha256=sha(ROOT/"scripts/lance_btree_lookup_reference.py"),sources={p:sha(lance/p) for p in paths},units={k:hashlib.sha256(v.encode()).hexdigest() for k,v in units.items()},generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/"scripts/lance_btree_leaf_reference.rs"),paged_scaffold_sha256=sha(ROOT/"scripts/lance_btree_paged_reference.rs"),lookup_source_sha256=sha(ROOT/".build/lance-btree-lookup-reference/src/source.rs"),cases_sha256=sha(out/"cases.json"),lock_sha256=sha(out/"Cargo.lock"),adapter="Original FlatIndex search/eval_expr and SargableQuery to_expr; actual DataFusion physical expressions and Arrow kernels. Original BTreeIndex search_with_options/search_page/compile_predicate with pinned lookup. Materialized BTreeSet row-address adapter, no-op metrics and in-memory leaf reader; constructor directly computes immutable all/null sets. No Lance file codec or concurrent IO claim.")
    (out/"sources.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(f"{len(cases)} original-source leaf cases written")
if __name__=="__main__":main()
