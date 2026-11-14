"""Execute unchanged pinned Lance BTreeLookup/statistics bodies using real Arrow."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess
from lance_bitmap_reference import unit, block, inputs, REVISION
ROOT = Path(__file__).resolve().parents[1]

def run(*args, **kwargs):
    return subprocess.check_output(["rtk", "proxy", *args], **kwargs)

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    source = ROOT / "reference/lance/rust/lance-index/src/scalar/btree.rs"
    assert run("git", "-C", str(ROOT / "reference/lance"), "rev-parse", "HEAD", text=True).strip() == REVISION
    assert source.read_bytes() == run("git", "-C", str(ROOT / "reference/lance"), "show", f"{REVISION}:rust/lance-index/src/scalar/btree.rs")
    text = source.read_text()
    units = {name: unit(text, name) for name in ["try_new", "page_numbers", "scan_equality_pages", "pages_eq", "pages_in", "pages_between", "pages_null"]}
    units.update({name: unit(text, name, "") for name in ["partition_point", "analyze_batch"]})
    units.update({name: block(text, f"impl {name} for OrderableScalarValue") for name in ["PartialEq", "PartialOrd", "Ord"]})
    units["Matches"] = block(text, "impl Matches")
    generated = "use super::*;\n#[derive(Clone,Debug)] pub struct OrderableScalarValue(pub ScalarValue); impl Eq for OrderableScalarValue {}\n"
    generated += "\n".join(units[n] for n in ["PartialEq", "PartialOrd", "Ord", "partition_point"])
    generated += "\nstruct BatchStats {min:ScalarValue,max:ScalarValue,null_count:u32}\n" + units["analyze_batch"]
    generated += "\n#[derive(Clone,Copy)] enum Matches{Some(u32),All(u32)}\n" + units["Matches"] + "\nstruct BTreeLookup{batch:RecordBatch,null_pages:Vec<u32>,all_null_pages:Vec<u32>,search_start:usize}\nimpl BTreeLookup{\n"
    generated += "\n".join(units[n] for n in ["try_new", "page_numbers", "scan_equality_pages", "pages_eq", "pages_in", "pages_between", "pages_null"])
    generated += r"""
    // Dispatch adapter only: actual Arrow comparators feed unchanged source scanning.
    fn candidate_pages_for_values(&self, query:&dyn Array)->Result<Vec<u32>>{
      let opts=SortOptions{descending:false,nulls_first:true};
      let mins=self.batch.column(0).as_ref();let maxs=self.batch.column(1).as_ref();
      let a=make_comparator(mins,query,opts)?;let b=make_comparator(maxs,query,opts)?;let c=make_comparator(mins,mins,opts)?;
      Ok(self.scan_equality_pages(query.len(),self.page_numbers()?.values(),|i|maxs.is_null(i),a,b,c))
    }
}
pub fn stats(batch:&RecordBatch)->Result<(ScalarValue,ScalarValue,u32)>{let s=analyze_batch(batch)?;Ok((s.min,s.max,s.null_count))}
pub fn query(batch:RecordBatch,q:&Value,t:u64)->Result<Vec<(u32,bool)>>{
 let lookup=BTreeLookup::try_new(batch)?;
 let matches=match q["op"].as_str().unwrap(){
  "eq"=>lookup.pages_eq(&OrderableScalarValue(scalar(&q["value"],t)))?,
  "in"=>lookup.pages_in(q["values"].as_array().unwrap().iter().map(|v|OrderableScalarValue(scalar(v,t))))?,
  "range"=>lookup.pages_between((bound(&q["lower"],t).as_ref(),bound(&q["upper"],t).as_ref()))?,
  "null"=>lookup.pages_null(),_=>unreachable!()
 };
 Ok(matches.into_iter().map(|m|match m{Matches::Some(p)=>(p,false),Matches::All(p)=>(p,true)}).collect())
}
"""
    build=ROOT/".build/lance-btree-lookup-reference";out=ROOT/"tests/fixtures/lance-btree-lookup"
    (build/"src").mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/"src/source.rs").write_text(generated)
    shutil.copyfile(ROOT/"scripts/lance_btree_lookup_reference.rs",build/"src/main.rs")
    manifest = """[package]
name="akasha-lance-btree-lookup-reference"
version="0.1.0"
edition="2024"
[dependencies]
datafusion-common={version="=54.1.0",default-features=false}
arrow-array="=58.4.0"
arrow-schema="=58.4.0"
arrow-ord="=58.4.0"
serde_json="=1.0.151"
[workspace]
"""
    (build/"Cargo.toml").write_text(manifest)
    if (out/"Cargo.lock").exists():shutil.copyfile(out/"Cargo.lock",build/"Cargo.lock")
    else:run("cargo","generate-lockfile","--offline","--manifest-path",str(build/"Cargo.toml"))
    cases=[]
    for original in inputs():
        for page_size in [1,3,7]:
            values=[r["value"] for r in original["old"]]
            if len(values)>100:values=values[:100]
            cases.append(dict(type=original["type"],page_size=page_size,values=values,queries=[q for q in original["queries"] if q["op"] in {"eq","in","range","null"}]))
    (build/"inputs.json").write_text(json.dumps(cases,ensure_ascii=False))
    result=run("cargo","run","--release","--quiet","--locked","--offline","--manifest-path",str(build/"Cargo.toml"),"--",str(build/"inputs.json"),env={**os.environ,"CARGO_TARGET_DIR":str(ROOT/".build/lance-json-reference/target")})
    (out/"cases.json").write_bytes(result);shutil.copyfile(build/"Cargo.lock",out/"Cargo.lock")
    metadata=dict(revision=REVISION,source_sha256=sha(source),units={k:hashlib.sha256(v.encode()).hexdigest() for k,v in units.items()},generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/"scripts/lance_btree_lookup_reference.rs"),cases_sha256=sha(out/"cases.json"),lock_sha256=sha(out/"Cargo.lock"),adapter="Actual pinned lookup/statistics bodies. Real Arrow comparator dispatch replaces physical-type specialization only. No flat predicate/whole B-tree parity claim.")
    (out/"sources.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(f"{len(cases)} source lookup cases written")

if __name__=="__main__":main()
