"""Original Lance prefix inference and lazy per-batch conversion oracle."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tarfile,tomllib
from lance_bitmap_reference import unit

ROOT=Path(__file__).resolve().parents[1]
REVISION='ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def inputs():
    values=[None,'null','true','false','1','-2','1.5','NaN','Infinity','-0.0',"'x'",'[]','{}','{v:1}','{v:[1,2]}']
    cases=[]
    for path in ['$', '$.v', '$.*']:
        for a in values:
            for b in values:
                cases.append(dict(path=path,batches=[[],[None],['null'],[a],[b]],target=None))
    for target in range(1,6):
        for value in values:
            cases.append(dict(path='$',batches=[[],[None],[value],['1']],target=target))
    for batches in [[],[[]],[[None]],[[None],[None]],[[None,'null'],[],[None]],
                    [['1','1.5']],[['1.5','1']],[['[]','{}']],
                    [['{a:[1,2]}'],['{a:[3,4]}']]]:
        for path in ['$','$[','$.*','$.a[*]']:
            cases.append(dict(path=path,batches=batches,target=None))
    return cases

def main():
    source=ROOT/'reference/lance';build=ROOT/'.build/lance-json-stream-reference';out=ROOT/'tests/fixtures/lance-json-stream'
    assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==REVISION
    files=[source/'rust/lance-index/src/scalar/json.rs',source/'rust/lance-datafusion/src/udf/json.rs']
    for p in files:assert p.read_bytes()==subprocess.check_output(['git','-C',str(source),'show',f'{REVISION}:{p.relative_to(source)}'])
    index,udf=[p.read_text() for p in files]
    names=['infer_type_from_batch','extract_json_with_type_info','validate_json_types','convert_batch_by_type','convert_stream_by_type']
    units={n:unit(index,n,'    ') for n in names}
    helpers={n:unit(udf,n,'    ') for n in ['execution_error','parse_json_path']}
    helpers['extract_json_path_with_type']=unit(udf,'extract_json_path_with_type','')
    enum=udf[udf.index('/// Represents the type'):udf.index('/// Common helper')]
    generated='use super::*;\n'+enum+'\npub mod udf {use super::*;type Result<T>=std::result::Result<T,DataFusionError>;mod common {use super::*;\n'
    generated+='\n'.join(helpers[n] for n in ['execution_error','parse_json_path'])+'\n}\n'+helpers['extract_json_path_with_type']+'\npub fn extract(b:&[u8],p:&str)->Result<Option<(Vec<u8>,u8)>>{extract_json_path_with_type(b,p)}\n}\n'
    generated+='pub struct JsonIndexPlugin;\nimpl JsonIndexPlugin {\n'+ '\n'.join(units.values())+'''
fn extract_json(data:SendableRecordBatchStream,path:String)->Result<SendableRecordBatchStream>{extract_stream(data,path)}
}
pub async fn infer(data:SendableRecordBatchStream,path:String)->Result<(SendableRecordBatchStream,DataType)>{JsonIndexPlugin::extract_json_with_type_info(data,path).await}
pub fn convert(data:SendableRecordBatchStream,target:DataType,path:String)->Result<SendableRecordBatchStream>{JsonIndexPlugin::convert_stream_by_type(data,target,path)}
'''
    (build/'src').mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/'src/source.rs').write_text(generated);shutil.copyfile(ROOT/'scripts/lance_json_stream_reference.rs',build/'src/main.rs')
    (build/'Cargo.toml').write_text('''[package]
name="akasha-lance-json-stream-reference"
version="0.1.0"
edition="2024"
[dependencies]
arrow-array="=58.4.0"
arrow-schema="=58.4.0"
futures="=0.3.32"
jsonb={version="=0.5.6",default-features=false,features=["databend"]}
serde_json={version="=1.0.151",features=["preserve_order"]}
[workspace]
''')
    if (out/'Cargo.lock').exists():shutil.copyfile(out/'Cargo.lock',build/'Cargo.lock')
    else:subprocess.run(['cargo','generate-lockfile','--offline','--manifest-path',str(build/'Cargo.toml')],check=True)
    deps=[]
    for dep in tomllib.loads((build/'Cargo.lock').read_text())['package']:
        if 'checksum' not in dep:continue
        name,version=dep['name'],dep['version'];directory=next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{version}'))
        archive=Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{version}.crate';assert sha(archive)==dep['checksum']
        checked=[]
        if name=='jsonb' or name.startswith('arrow-') or name.startswith('futures'):
            with tarfile.open(archive) as tar:
                for file in sorted((directory/'src').rglob('*.rs')):
                    rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();checked.append(dict(path=rel,sha256=sha(file)))
        deps.append(dict(name=name,version=version,checksum=dep['checksum'],files=checked))
    (build/'inputs.json').write_text(json.dumps(inputs(),ensure_ascii=False,separators=(',',':')))
    result=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml'),'--',str(build/'inputs.json')],env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/lance-json-reference/target')})
    (out/'cases.json').write_bytes(result);shutil.copyfile(build/'Cargo.lock',out/'Cargo.lock')
    metadata=dict(lance_revision=REVISION,sources=[dict(path=str(p.relative_to(source)),sha256=sha(p)) for p in files],units={n:hashlib.sha256(body.encode()).hexdigest() for n,body in {**units,**helpers}.items()},dependencies=deps,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/lance_json_stream_reference.rs'),cases_sha256=sha(out/'cases.json'),lock_sha256=sha(out/'Cargo.lock'),rustc=subprocess.check_output(['rustc','-Vv'],text=True).strip(),adapter='Original prefix inference, per-batch conversion and lazy converted stream methods. Real Arrow/jsonb/futures; source UDF extraction in a lazy projection adapter, schema-preserving stream adapters and unadorned error carriers. No DataFusion executor, external sort/spill or durable index claim.')
    (out/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (out/'README.md').write_text('''# Lance JSON stream oracle

Run `pixi run python scripts/lance_json_stream_reference.py` at the repo root.
Original pinned Lance methods execute prefix-only inference, default Utf8,
whole-batch validation, conversion and the lazy reconstructed/converted streams.
The projection adapter calls the original JSON UDF extractor; Arrow/jsonb/futures
are actual frozen crates. Error carriers preserve inner messages without upstream
transport/location decoration. No DataFusion executor or external sort is claimed.

786 scenarios cover null/empty prefixes, batch/type order, fixed rebuild/update
types, mixed values, nonfinite floats, arrays/objects, paths and delayed errors.
Polled-batch counters show that inference stops at its first useful prefix;
the remainder is consumed lazily by conversion. The fixture also records original
row IDs and row addresses. Native bitmap tests verify ID/value correspondence;
arbitrary Arrow passthrough columns are not a native stream API in this slice.

Native construction/update finishes only after the complete input succeeds.
Partial reference conversion outputs preceding errors remain in the fixture;
the native trainer discards staged keys on errors, as no index may be published.
Source hashes, original method hashes, crates, compiler and lock are recorded
in sources.json. This does not prove planner, spilling or durable lifecycle.
''')
    print('Original JSON stream scenarios',len(json.loads(result)))

if __name__=='__main__':main()
