"""Run original Lance bitmap train/merge/search/remap over an in-memory store."""
from pathlib import Path
from urllib.request import urlopen
import hashlib,json,os,random,re,shutil,subprocess,tarfile,tomllib

ROOT=Path(__file__).resolve().parents[1]
REVISION="ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e"
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def unit(text,name,indent="    "):
    start=re.search(r"(?m)^"+indent+r"(?:pub(?:\([^)]*\))? )?(?:async )?fn "+name+r"\(",text).start()
    return text[start:text.index("\n"+indent+"}",start)+len(indent)+2]

def block(text,start):
    i=text.index(start);return text[i:text.index("\n}",i)+2]

def inputs():
    rng=random.Random(318603)
    values={1:[None,False,True],2:[None,-9223372036854775808,-1,0,1,9223372036854775807],
            3:[None,"fff8000000000001","fff0000000000000","bff0000000000000","8000000000000000","0000000000000000","0000000000000001","3ff0000000000000","7ff0000000000000","7ff8000000000000","7ff8000000000001","7ff0000000000001"],
            4:[None,"","a","a\u0000b","é","漢字","😀"],5:[None,"","00","00ff","01","ff","ff00"]}
    cases=[]
    for typ,domain in values.items():
        queries=[dict(op="null"),dict(op="text"),dict(op="prefix",value=None)]
        queries += [dict(op="eq",value=v) for v in domain]
        queries += [dict(op="in",values=v) for v in [[],domain[:2],domain[1:3],domain+domain]]
        bounds=[None]+[dict(value=v,included=inc) for v in domain for inc in [False,True]]
        queries += [dict(op="range",lower=lo,upper=hi) for lo in bounds for hi in bounds]
        for i in range(12):
            old=[] if i==0 else [dict(value=v,id=j) for j,v in enumerate(domain+domain)]
            if i>1:old += [dict(value=rng.choice(domain),id=(rng.randrange(3)<<32)+rng.randrange(20)) for _ in range(i*3)]
            if i==11:old += [dict(value=v,id=(1<<64)-1-j) for j,v in enumerate(domain)]
            new=[] if i==0 else [dict(value=rng.choice(domain),id=(rng.randrange(3)<<32)+rng.randrange(30)) for _ in range(i+2)]
            filter=None if i%3==0 else dict(rows=[r['id'] for r in old[::2]]) if i%3==1 else dict(fragments=[0,2])
            mapping={str(r['id']):(None if j%3==0 else (1<<63)+j%4) for j,r in enumerate(old[:6])}
            cases.append(dict(type=typ,old=old,new=new,filter=filter,mapping=mapping,queries=queries,values=domain))
    cases.append(dict(type=2,old=[dict(value=1,id=i) for i in range(4097)]+[dict(value=None,id=(1<<64)-1)],
        new=[dict(value=1,id=4097),dict(value=2,id=65536)],filter=dict(rows=list(range(1,4097))),
        mapping={'1':None,'2':(1<<64)-1,'3':(1<<64)-1},values=[None,1,2],
        queries=[dict(op='eq',value=1),dict(op='null'),dict(op='in',values=[None,1,2]),dict(op='range',lower=None,upper=None)]))
    return cases

def main():
    lance=ROOT/'reference/lance';build=ROOT/'.build/lance-bitmap-reference';out=ROOT/'tests/fixtures/lance-bitmap'
    assert subprocess.check_output(['git','-C',str(lance),'rev-parse','HEAD'],text=True).strip()==REVISION
    paths=['rust/lance-index/src/scalar/bitmap.rs','rust/lance-index/src/scalar/btree.rs','rust/lance-index-core/src/scalar.rs']
    texts=[]
    for path in paths:
        file=lance/path;assert file.read_bytes()==subprocess.check_output(['git','-C',str(lance),'show',f'{REVISION}:{path}']);texts.append(file.read_text())
    bitmap,btree,core=texts
    units={n:unit(bitmap,n) for n in ['search_with_options','streaming_build_and_write','finish_run','remap_bitmap_state']}
    units['retain_valid']=unit(bitmap,'retain_valid','')
    for name in ['PartialEq','PartialOrd','Ord']:
        units[name]=block(btree,f'impl {name} for OrderableScalarValue')
    units['filter']=block(core,'pub enum OldIndexDataFilter')+'\n'+block(core,'impl OldIndexDataFilter')
    units['options']=block(core,'pub struct SearchOptions')+'\n'+block(core,'impl Default for SearchOptions')+'\n'+block(core,'impl SearchOptions')
    generated='use super::*;\n#[derive(Clone,Debug)] pub struct OrderableScalarValue(pub ScalarValue);\nimpl Eq for OrderableScalarValue {}\n'
    generated+='\n'.join(units[n] for n in ['PartialEq','PartialOrd','Ord','filter','options','retain_valid'])
    generated+='\nimpl BitmapIndex {\n'+units['search_with_options']+'\n}\nimpl BitmapIndexPlugin {\n'+'\n'.join(units[n] for n in ['streaming_build_and_write','finish_run','remap_bitmap_state'])+'\n}\n'
    # Visibility-only dispatch adapters inside the module containing private methods.
    generated+='''pub async fn run_search(index:&BitmapIndex,q:&SargableQuery,track:bool)->Result<SearchResult>{index.search_with_options(q,SearchOptions::default().with_track_nulls(track),&Metrics).await}
pub async fn run_build(data:SendableRecordBatchStream,old:Option<&BitmapIndex>,store:&dyn IndexStore,filter:Option<&OldIndexDataFilter>)->Result<IndexFile>{BitmapIndexPlugin::streaming_build_and_write(data,old,store,"memory",filter).await}
pub fn run_remap(state:HashMap<ScalarValue,RowAddrTreeMap>,mapping:&RowAddrRemap)->HashMap<ScalarValue,RowAddrTreeMap>{BitmapIndexPlugin::remap_bitmap_state(state,mapping)}
'''
    (build/'src').mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    rust_revision='ded5c06cf21d2b93bffd5d884aa6e96934ee4234'
    rust_url=f'https://raw.githubusercontent.com/rust-lang/rust/{rust_revision}/library/core/src/num/f64.rs'
    rust_file=build/'rust-f64.rs'
    if not rust_file.exists():rust_file.write_bytes(urlopen(rust_url,timeout=30).read())
    assert sha(rust_file)=='12809be343b49295f9f3479495d20b0dd09964539f42412b0cedee26bf49e544'
    (build/'src/source.rs').write_text(generated);shutil.copyfile(ROOT/'scripts/lance_bitmap_reference.rs',build/'src/main.rs')
    (build/'Cargo.toml').write_text('[package]\nname="akasha-lance-bitmap-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\ndatafusion-common={version="=54.1.0",default-features=false}\narrow-array="=58.4.0"\narrow-schema="=58.4.0"\narrow-ord="=58.4.0"\nroaring="=0.11.4"\nfutures="=0.3.32"\nserde_json="=1.0.151"\n[workspace]\n')
    if (out/'Cargo.lock').exists():shutil.copyfile(out/'Cargo.lock',build/'Cargo.lock')
    else:subprocess.run(['cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    (build/'inputs.json').write_text(json.dumps(inputs(),ensure_ascii=False,separators=(',',':')))
    deps=[]
    for dep in tomllib.loads((build/'Cargo.lock').read_text())['package']:
        if 'checksum' not in dep:continue
        name,version=dep['name'],dep['version'];directory=next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{version}'))
        archive=Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{version}.crate';assert sha(archive)==dep['checksum']
        files=[]
        if name=='datafusion-common' or name.startswith('arrow-') or name=='roaring':
            if name=='datafusion-common':assert dep['checksum']=='ca43b263cdff57042cfa8fb817fb3469f4878933380dccff25f5e793580abbf9'
            with tarfile.open(archive) as tar:
                for file in sorted((directory/'src').rglob('*.rs')):
                    rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();files.append(dict(path=rel,sha256=sha(file)))
                if name=='datafusion-common':
                    for license in ['LICENSE.txt','NOTICE.txt']:
                        assert (directory/license).read_bytes()==tar.extractfile(f'{name}-{version}/{license}').read()
                        shutil.copyfile(directory/license,ROOT/f'docs/upstream/licenses/datafusion-{license}')
        deps.append(dict(name=name,version=version,checksum=dep['checksum'],files=files))
    data=subprocess.check_output(['cargo','run','--release','--quiet','--locked','--offline','--manifest-path',str(build/'Cargo.toml'),'--',str(build/'inputs.json')],env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/lance-json-reference/target')})
    (out/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',out/'Cargo.lock')
    metadata=dict(lance_revision=REVISION,sources=[dict(path=p,sha256=sha(lance/p)) for p in paths],units={n:hashlib.sha256(s.encode()).hexdigest() for n,s in units.items()},dependencies=deps,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/lance_bitmap_reference.rs'),cases_sha256=sha(out/'cases.json'),lock_sha256=sha(out/'Cargo.lock'),rustc=subprocess.check_output(['rustc','-Vv'],text=True).strip(),adapter='Real Arrow/DataFusion ScalarValue/roaring. Original ordering, old-row filters, bitmap search, streaming merge and remap bodies. In-memory IndexStore/stream and materialized row set; no Lance file codec/cache or DataFusion planner/executor claim.')
    metadata['rust_total_cmp']=dict(revision=rust_revision,url=rust_url,sha256=sha(rust_file))
    (out/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (out/'README.md').write_text('''# Lance materialized bitmap target oracle

Run `pixi run python scripts/lance_bitmap_reference.py` from the project root.
The generator executes unchanged pinned Lance ordering, old-row filters,
bitmap search, streaming training/update merge and remap methods. Actual
DataFusion ScalarValue, Arrow sorting and roaring crates provide typed values,
sorting and sets. In-memory store/stream/error adapters replace transport only.
The first generation needs locked crates and the pinned Rust total_cmp source;
subsequent runs reuse the source under `.build/lance-bitmap-reference`.

Fixtures include Boolean/Int64/Float64/Utf8/LargeBinary, typed nulls, signed
zero, distinct NaNs, byte ordering, all range endpoints, IN duplicates, empty
and dense postings, cross-batch equal runs, old-ID/fragment filters and UInt64
remapping/deletion/collisions. Unknown/null results are retained separately.
Unsupported full-text/prefix queries preserve original errors.

This does not execute Lance file encoding, caches, shard merge, SQL planning
or collection publication. Native tests compare every recorded state/search
and comparison. Bounds/type errors and cancellation are native adaptations.
Source, dependency, compiler, adapter and output hashes are in sources.json.
''')
    print('Original bitmap scenarios',len(json.loads(data)))

if __name__=='__main__':main()
