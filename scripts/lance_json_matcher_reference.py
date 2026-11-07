"""Audit original JSON-index matching against its actual indexed/UDF values."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tarfile,tomllib
from lance_bitmap_reference import unit

ROOT=Path(__file__).resolve().parents[1]
REVISION='ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def inputs():
    rows=[]
    for path in ['v','$.v','$."v"','v.x','0']:
        for function in ['json_extract','json_get','json_get_int','json_get_float','json_get_bool','json_get_string']:
            for text in ['{"v":true,"$.v":false}', '{"v":"abc"}', '{"v":1}',
                         '{"v":1.5}', '{"v":null}', '{}', '[true,false]',
                         '{"v":{"x":2},"v.x":3}', '{"0":4}',
                         '{"v":NaN}', '{"v":Infinity}', '{"v":-0.0}',
                         '{"v":9223372036854775807}', '{"v":"中文"}',
                         '[{"v":true}]', '{"v":""}']:
                rows.append(dict(path=path,function=function,text=text))
    corpus=json.loads((ROOT/'tests/fixtures/jsonb-codec/cases.json').read_text())
    for row in corpus['cases']:
        if row['input'][0] >= 9:
            for function in ['json_extract','json_get','json_get_int','json_get_float','json_get_bool','json_get_string']:
                rows.append(dict(path='v',function=function,wrapped_scalar=row['hex']))
    return rows

def main():
    source=ROOT/'reference/lance';build=ROOT/'.build/lance-json-matcher-reference';out=ROOT/'tests/fixtures/lance-json-matcher'
    assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==REVISION
    files=[source/'rust/lance-index/src/scalar/json.rs',source/'rust/lance-datafusion/src/udf/json.rs',source/'rust/lance-index/src/scalar/expression.rs',source/'rust/lance-index/src/scalar/bitmap.rs']
    for p in files:assert p.read_bytes()==subprocess.check_output(['git','-C',str(source),'show',f'{REVISION}:{p.relative_to(source)}'])
    index,udf,expression,bitmap=[p.read_text() for p in files]
    units={n:unit(index,n,'    ') for n in ['infer_type_from_batch','validate_json_types','convert_batch_by_type','is_valid_reference']}
    helpers={n:unit(udf,n,'    ') for n in ['execution_error','parse_json_path','get_json_value_by_key']}
    helpers.update({n:unit(udf,n,'') for n in ['extract_json_path','extract_json_path_with_type','json_value_to_bool','json_value_to_int','json_value_to_float','json_value_to_string']})
    enum=udf[udf.index('/// Represents the type'):udf.index('/// Common helper')]
    generated='use super::*;\n'+enum+'\nimpl JsonQueryParser {\n'+units['is_valid_reference']+'\n}\nimpl JsonIndexPlugin {\n'+'\n'.join(units[n] for n in ['infer_type_from_batch','validate_json_types','convert_batch_by_type'])+'\n}\n'
    generated+='mod consumer {use super::*;type Result<T>=std::result::Result<T,DataFusionError>;mod common {use super::*;\n'+'\n'.join(helpers[n] for n in ['execution_error','parse_json_path','get_json_value_by_key'])+'\n}\n'+'\n'.join(helpers[n] for n in ['extract_json_path','extract_json_path_with_type','json_value_to_bool','json_value_to_int','json_value_to_float','json_value_to_string'])+'''
pub fn extract(body:&[u8],path:&str)->Result<Option<(Vec<u8>,u8)>>{extract_json_path_with_type(body,path)}
pub fn run(body:&[u8],name:&str,path:&str)->Result<Value>{
 if name=="json_extract"{return extract_json_path(body,path).map(|v|json!(v))}
 let Some(value)=common::get_json_value_by_key(&jsonb::RawJsonb::new(body),path)? else{return Ok(Value::Null)};
 match name{
 "json_get"=>Ok(json!(hex(&value.to_vec()))),
 "json_get_int"=>json_value_to_int(value).map(|v|json!(v)),
 "json_get_float"=>json_value_to_float(value).map(|v|json!(v.map(|v|format!("{:016x}",v.to_bits())))),
 "json_get_bool"=>json_value_to_bool(value).map(|v|json!(v)),
 "json_get_string"=>json_value_to_string(value).map(|v|json!(v)),_=>unreachable!()}
}
}
pub fn reference(path:&str,name:&str)->Option<DataType>{
 JsonQueryParser{path:path.into()}.is_valid_reference(&Expr::ScalarFunction(Function{name:name.into(),args:vec![Expr::Column,Expr::Literal(ScalarValue::Utf8(Some(path.into())),())]}),&DataType::LargeBinary)
}
pub fn evaluate(body:&[u8],path:&str,name:&str)->Value{
 let mut out=json!({"reference_type":reference(path,name).map(|t|format!("{t:?}"))});
 out["consumer"]=match std::panic::catch_unwind(||consumer::run(body,name,path)){Ok(Ok(v))=>json!({"ok":v}),Ok(Err(DataFusionError::Execution(e)))=>json!({"error":e}),Err(_)=>json!({"panic":true})};
 let extracted=match std::panic::catch_unwind(||consumer::extract(body,path)){Ok(Ok(v))=>v,Ok(Err(DataFusionError::Execution(e)))=>{out["index_error"]=json!(e);return out},Err(_)=>{out["index_panic"]=json!(true);return out}};
 let fields=vec![Arc::new(Field::new("value",DataType::LargeBinary,true)),Arc::new(Field::new("type_tag",DataType::UInt8,true))];
 let binary=LargeBinaryArray::from_iter([extracted.as_ref().map(|v|v.0.as_slice())]);let tags=UInt8Array::from(vec![extracted.as_ref().map_or(0,|v|v.1)]);
 let array=StructArray::new(fields.into(),vec![Arc::new(binary),Arc::new(tags)],None);
 let schema=Arc::new(Schema::new(vec![Field::new("json_result",array.data_type().clone(),false)]));let batch=RecordBatch::try_new(schema,vec![Arc::new(array)]).unwrap();
 let target=JsonIndexPlugin::infer_type_from_batch(&batch,path).unwrap().unwrap_or(DataType::Utf8);
 out["index_type"]=json!(format!("{target:?}"));
 let schema=Arc::new(Schema::new(vec![Field::new("value",target.clone(),true)]));
 out["indexed_value"]=match std::panic::catch_unwind(std::panic::AssertUnwindSafe(||JsonIndexPlugin::convert_batch_by_type(batch,schema,&[],&target,path))){Ok(Ok(b))=>json!({"ok":scalar_json(&ScalarValue::try_from_array(b.column(0),0).unwrap())}),Ok(Err(e))=>json!({"error":e.0}),Err(_)=>json!({"panic":true})};out
}
'''
    (build/'src').mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/'src/source.rs').write_text(generated);shutil.copyfile(ROOT/'scripts/lance_json_matcher_reference.rs',build/'src/main.rs')
    (build/'Cargo.toml').write_text('''[package]
name="akasha-lance-json-matcher-reference"
version="0.1.0"
edition="2024"
[dependencies]
arrow-array="=58.4.0"
arrow-schema="=58.4.0"
datafusion-common={version="=54.1.0",default-features=false}
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
        archive=Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{version}.crate';assert sha(archive)==dep['checksum'];checked=[]
        if name in ['jsonb','datafusion-common'] or name.startswith('arrow-'):
            with tarfile.open(archive) as tar:
                for file in sorted((directory/'src').rglob('*.rs')):
                    rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();checked.append(dict(path=rel,sha256=sha(file)))
        deps.append(dict(name=name,version=version,checksum=dep['checksum'],files=checked))
    (build/'inputs.json').write_text(json.dumps(inputs(),ensure_ascii=False,separators=(',',':')))
    result=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml'),'--',str(build/'inputs.json')],env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/lance-json-reference/target')})
    (out/'cases.json').write_bytes(result);shutil.copyfile(build/'Cargo.lock',out/'Cargo.lock')
    metadata=dict(lance_revision=REVISION,sources=[dict(path=str(p.relative_to(source)),sha256=sha(p)) for p in files],units={n:hashlib.sha256(body.encode()).hexdigest() for n,body in {**units,**helpers}.items()},dependencies=deps,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/lance_json_matcher_reference.rs'),cases_sha256=sha(out/'cases.json'),lock_sha256=sha(out/'Cargo.lock'),rustc=subprocess.check_output(['rustc','-Vv'],text=True).strip(),adapter='Original JSON reference matching, extractor, scalar consumers and index inference/conversion. Real Arrow/DataFusion ScalarValue/jsonb; expression name/argument transport and unadorned errors replace surrounding framework. Evidence is a matching audit, not a complete planner/executor.')
    parser=expression[expression.index('impl ScalarQueryParser for SargableQueryParser {'):]
    metadata['inspected_not_executed_units']={n:hashlib.sha256(unit(parser,n,'    ').encode()).hexdigest() for n in ['visit_between','visit_in_list','visit_comparison','visit_is_null','visit_is_bool','visit_scalar_function','visit_like']}
    metadata['input_fixture_sha256']=sha(ROOT/'tests/fixtures/jsonb-codec/cases.json')
    assert '.without_like_prefix()' in bitmap
    (out/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (out/'README.md').write_text('''# Lance JSON matcher audit

Run `pixi run python scripts/lance_json_matcher_reference.py` at the repo root.
The pinned original JSON reference matcher, JSONPath extractor, typed getters,
index inference and batch converter execute against real Arrow, DataFusion
ScalarValue and jsonb crates. Function-name/argument transport and unadorned error
carriers replace framework plumbing; this is not a DataFusion SQL planner run.

1,344 scenarios compare source recognition, actual indexed values and actual UDF
results, including literal keys versus JSONPath, numeric keys/array indices,
string quoting, strict learned types versus getter coercion, missing/null values,
objects/arrays, nonfinite floats, signed zero, Int64 maximum and Unicode strings.
All 144 Decimal/extension scalars from the pinned JSONB codec fixture are wrapped
in an object by original jsonb and checked against all six functions. Extensions
can train as Utf8 while the string getter errors; native training therefore
retains whether all indexed nonnull Utf8 values originated as actual strings.
Original consumer/converter panics from extreme Decimal/date formatting are
captured without changing their implementations; native tests require bounded
errors for them and exact messages for ordinary source errors.
Recognition alone can accept non-equivalent values. Native execution therefore
requires a separate proven-equivalent reference guard and retains every rejected
predicate for ordinary evaluation. Matching the source recognition helper does
not authorize replacing a predicate with an index result.

Sargable leaf null/prefix rules and bitmap parser setup were inspected, not
executed in this oracle. Their source/method hashes are distinguished in
sources.json. Whole-expression planning, literal coercion, snapshot selection,
residual execution and durable/public integration remain separate work.
''')
    print('JSON matcher audit cases',len(json.loads(result)))

if __name__=='__main__':main()
