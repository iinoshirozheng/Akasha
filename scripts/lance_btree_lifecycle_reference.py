"""Execute unchanged Lance remap_batch/merge_segments with real DataFusion merge."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tarfile, tomllib
from lance_bitmap_reference import unit, REVISION
ROOT=Path(__file__).resolve().parents[1]
def run(*args, **kw): return subprocess.check_output(["rtk","proxy",*args], **kw)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    source=ROOT/"reference/lance"
    paths=["rust/lance-index/src/scalar/btree.rs","rust/lance-index/src/scalar/btree/flat.rs","rust/lance-index-core/src/scalar.rs","rust/lance-datafusion/src/exec.rs"]
    texts=[]
    for path in paths:
        data=(source/path).read_bytes()
        assert data==run("git","-C",str(source),"show",f"{REVISION}:{path}")
        texts.append(data.decode())
    units={"merge_segments":unit(texts[0],"merge_segments"),"filter_row_ids":unit(texts[0],"filter_row_ids",""),"filter_keeps_nothing":unit(texts[0],"filter_keeps_nothing",""),"remap_row_ids":unit(texts[0],"remap_row_ids",""),"remap_batch":unit(texts[1],"remap_batch"),"filter_mask":unit(texts[2],"filter_row_ids")}
    oneshot=texts[3][texts[3].index("pub struct OneShotExec {"):texts[3].index("struct TracedExec {")]
    build=ROOT/".build/lance-btree-lifecycle-reference";out=ROOT/"tests/fixtures/lance-btree-lifecycle"
    (build/"src").mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    generated="use super::*;\n"+oneshot+"\nimpl BTreeIndex {"+units["merge_segments"]+"}\nimpl FlatIndex {"+units["remap_batch"]+"}\nimpl OldIndexDataFilter {"+units["filter_mask"]+"}\n"+"\n".join(units[k] for k in ["filter_row_ids","filter_keeps_nothing","remap_row_ids"])
    (build/"src/source.rs").write_text(generated)
    shutil.copyfile(ROOT/"scripts/lance_btree_lifecycle_reference.rs",build/"src/main.rs")
    (build/"Cargo.toml").write_text('''[package]
name="akasha-lance-btree-lifecycle-reference"
version="0.1.0"
edition="2024"
[dependencies]
datafusion-common={version="=54.1.0",default-features=false}
datafusion-physical-expr="=54.1.0"
datafusion-physical-plan="=54.1.0"
datafusion-execution="=54.1.0"
arrow-array="=58.4.0"
arrow-schema="=58.4.0"
arrow-select="=58.4.0"
arrow-ord="=58.4.0"
futures="=0.3.32"
serde_json="=1.0.151"
tokio={version="=1.52.1",features=["rt-multi-thread","macros"]}
[workspace]
''')
    lock=out/"Cargo.lock"
    if lock.exists(): shutil.copyfile(lock,build/"Cargo.lock")
    else: run("cargo","generate-lockfile","--manifest-path",str(build/"Cargo.toml"))
    domains=[[None,False,True],[None,-7,0,7],[None,"fff0000000000000","8000000000000000","0000000000000000","7ff0000000000000","7ff8000000000001"],[None,"","雪","z"],[None,"","00","ff"]]
    cases=[]
    for t,domain in enumerate(domains,1):
        for n in [0,1,3,17,65]:
            for shift in range(len(domain)):
                old=[dict(id=i,value=domain[(i+shift)%len(domain)]) for i in range(n)]
                new=[dict(id=1000+i,value=domain[(i+1)%len(domain)]) for i in range(4)]
                removed=[i for i in range(n) if i%3==0]
                mapping=[[i,None if i%5==0 else 10000+i] for i in range(n) if i%2==0]
                cases.append(dict(type=t,old=old,new=new,removed=removed,mapping=mapping))
    (build/"inputs.json").write_text(json.dumps(cases,ensure_ascii=False))
    run("cargo","fetch","--locked","--manifest-path",str(build/"Cargo.toml"))
    result=run("cargo","run","--release","--quiet","--locked","--manifest-path",str(build/"Cargo.toml"),"--",str(build/"inputs.json"),env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(result);shutil.copyfile(build/"Cargo.lock",lock)
    dependencies=[]
    for dep in tomllib.loads(lock.read_text())["package"]:
        if "checksum" not in dep: continue
        archives=list((Path.home()/".cargo/registry/cache").glob(f"*/{dep['name']}-{dep['version']}.crate"))
        assert any(sha(p)==dep["checksum"] for p in archives)
        item={k:dep[k] for k in ["name","version","checksum"]}
        if dep["name"].startswith(("arrow-", "datafusion-")):
            archive=next(p for p in archives if sha(p)==dep["checksum"])
            directory=Path.home()/".cargo/registry/src"/archive.parent.name/f"{dep['name']}-{dep['version']}"
            files=[]
            with tarfile.open(archive) as tar:
                for file in sorted((directory/"src").rglob("*.rs")):
                    relative=str(file.relative_to(directory))
                    assert file.read_bytes()==tar.extractfile(f"{directory.name}/{relative}").read()
                    files.append([relative,sha(file)])
            item["verified_source_files"]=files
        dependencies.append(item)
    metadata=dict(revision=REVISION,sources={p:sha(source/p) for p in paths},units={k:hashlib.sha256(v.encode()).hexdigest() for k,v in units.items()},oneshot_sha256=hashlib.sha256(oneshot.encode()).hexdigest(),generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/"scripts/lance_btree_lifecycle_reference.rs"),cases_sha256=sha(out/"cases.json"),lock_sha256=sha(lock),dependencies=dependencies,adapter="Unchanged merge_segments, filter_row_ids, filter mask, remap_batch and OneShotExec. Real DataFusion UnionExec/SortPreservingMergeExec. In-memory data_stream and output collector replace file IO/training; chunking is identity. Exact set/map row-ID adapters. No file format or partitioned index parity claim.")
    (out/"sources.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(f"{len(cases)} upstream lifecycle cases written")
if __name__=="__main__":main()
