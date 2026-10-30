"""Execute all six modes of the original, pinned jsonb Selector."""
from pathlib import Path
import hashlib,itertools,json,os,random,re,shutil,subprocess,tarfile,tomllib

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/jsonb-selector'
REGISTRY=next((Path.home()/'.cargo/registry/src').glob('*/jsonb-0.5.6')).parent
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()


def inputs():
    docs=[];doc_ids={};paths=[];path_ids={};pairs={}
    def doc(value):
        key=json.dumps(value,sort_keys=True)
        if key not in doc_ids:doc_ids[key]=len(docs);docs.append(value)
        return doc_ids[key]
    def path(value):
        raw=value.encode() if isinstance(value,str) else value
        key=raw.hex()
        if key not in path_ids:path_ids[key]=len(paths);paths.append(key)
        return path_ids[key]
    def add(d,p):pairs[(d,path(p))]=None
    source=(REGISTRY/'jsonb-0.5.6/tests/it/functions.rs').read_text()
    for name in ['test_path_exists','test_path_match']:
        block=source.split('fn '+name+'() {',1)[1].split('\n#[test]',1)[0]
        for a,b in re.findall(r'\(\s*r#"(.*?)"#,\s*r#"(.*?)"#',block,re.S):add(doc({'text':a}),b)
    for name in ['test_path_exists_expr','test_select_by_path']:
        block=source.split('fn '+name+'() {',1)[1].split('\n#[test]',1)[0]
        text=re.search(r'let source = r#"(.*?)"#;',block,re.S).group(1)
        d=doc({'text':text})
        for p in re.findall(r'\(\s*r#"(.*?)"#',block,re.S):add(d,p)
        for p in re.findall(r'\(\s*"(\$[^"\n]*)"',block):add(d,p)
    basic_docs=['null','true','false','0','-1','18446744073709551615','-0.0','NaN','Infinity','"abc"','"漢字😀"','[]','{}','[1,2,3]','[null,true,"a",1,[],{}]','[[1,2],[3],[]]','[{},1]','[1,{}]','["1",1]','[1,"1"]','{a:1,b:2}','{a:[1,2],b:[2,3]}','{a:[],b:[]}','{a:[{},1],b:[1]}','{a:[1,{}],b:[1]}','{a:null,b:false}','{a:"abc",b:"a"}','{a:{x:1},b:[{x:2},{x:null},{}]}','{items:[{x:1},{x:2},{x:null},{}],a:2}','{"":1,"a.b":2,"a\\tb":3,"漢字😀":4}']
    basic=[doc({'text':s}) for s in basic_docs]
    selectors=['','$','$.*','$[*]','$.**','$.**{0}','$.**{1}','$.**{2}','$.**{0 to 2}','$.**{2 to 1}','$.**{1 to last}','$.a','a',':a','$["a"]','$.items[*].x','$.**.x','$.items[*]?(exists(@.x))','$.items[*]?(@.x == $.a)','$?(@ == 1)','$?(@ != null)','exists($)','exists(@)','exists($.missing)','+$.a','-$.a','+$','-$','$.a + 1','$.a / 0','$.a % -1']
    for i in [-2147483648,-2,-1,0,1,2,3,2147483647]:selectors += [f'$[{i}]',f'$[last+{i}]']
    for a,b in itertools.product(['$','$.a','$.b'],repeat=2):
        for op in ['==','!=','<','<=','>','>=','starts with','+','-','*','/','%']:selectors.append(f'{a} {op} {b}')
    for op,literal in itertools.product(['==','!=','<','<=','>','>=','starts with'],['null','true','false','0','1','-1','.5','NaN','Infinity','"a"','"漢"']):
        selectors += [f'$ {op} {literal}',f'$.a {op} {literal}',f'$[*]?(@ {op} {literal})']
    for a,b in itertools.product(['$.a == 1','$.a == null','$.missing == 1','$.a starts with "a"','exists($.b)','$.a + 1'],repeat=2):
        selectors += [f'({a}) && ({b})',f'({a}) || ({b})']
    for d,p in itertools.product(basic,selectors):add(d,p)
    # Source parser corpus exercises unusual names/operators and byte grammar.
    # Exclude ranges from this cross-product: source negative range ends cast
    # to usize and can attempt a virtually unbounded HashSet allocation.
    def has_range(nodes):return any(n[0]==17 or has_range(n[5]) for n in nodes)
    corpus=json.loads((ROOT/'tests/fixtures/jsonb-path/cases.json').read_text())
    for row in corpus:
        if 'ast' in row and not has_range(row['ast']):add(basic[-3],bytes.fromhex(row['hex']))
    # Safe bounded range matrices use only flat, nonempty arrays and known
    # nonnegative converted ends. Expected results still come from Selector.
    for length in [1,2,5,10]:
        d=doc({'text':json.dumps(list(range(length)))})
        starts=['-2147483648','-1','0','1',str(length), 'last-1','last','last+1']
        ends=['0','1',str(length-1),str(length),'2147483647','last','last+1']
        for a,b in itertools.product(starts,ends):
            p=f'$[{a} to {b}]';add(d,p);add(d,p+'[*]');add(d,f'$[0,{a} to {b},last,0]')
    # All source binary scalar/extension/container and legacy bodies. Arithmetic
    # on decimals checks the selector's serde conversion, not only Number math.
    codec=json.loads((ROOT/'tests/fixtures/jsonb-codec/cases.json').read_text())
    for i,row in enumerate(codec['cases']+codec['legacy']):
        d=doc({'hex':row['hex']})
        for p in ['$','$[*]','$.*','+$','-$','$ == 0','$ != null','exists($)']:add(d,p)
        if i%23==0:
            wrapped=doc({'wrap':d})
            for p in ['$.a','$.items[*]','$.**','+$.a','-$.a','$.a == $.b','$.a != null','$.items?(@ != null)','$.items[*]?(@ == $.a)']:add(wrapped,p)
    # Malformed and source-panic syntax; no executor is invoked after rejection.
    for p in ['$[','$."abc','@','$.a == 1.0','$?(@ ==)','$.""']:
        add(basic[0],p)
    return dict(docs=docs,paths=paths,pairs=list(pairs))


def main():
    OUT.mkdir(parents=True,exist_ok=True);build=ROOT/'.build/jsonb-selector-reference';(build/'src').mkdir(parents=True,exist_ok=True)
    prior=ROOT/'tests/fixtures/jsonb-text';deps=json.loads((prior/'sources.json').read_text())['dependencies'];records=[]
    for dep in deps:
        name,version=dep['name'],dep['version'];directory=REGISTRY/f'{name}-{version}';archive=Path.home()/'.cargo/registry/cache'/REGISTRY.name/f'{name}-{version}.crate'
        assert sha(archive)==dep['checksum'];files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();files.append(dict(path=rel,sha256=sha(file)))
            if name=='jsonb':assert (directory/'tests/it/functions.rs').read_bytes()==tar.extractfile(f'{name}-{version}/tests/it/functions.rs').read()
        records.append(dict(name=name,version=version,checksum=dep['checksum'],license=dep['license'],files=files))
    manifest='[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name,version=dep['name'],dep['version'];manifest+=f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name=='jsonb' else f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n');shutil.copyfile(prior/'Cargo.lock',build/'Cargo.lock');shutil.copyfile(ROOT/'scripts/jsonb_selector_reference.rs',build/'src/main.rs')
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs()).encode(),env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/jsonb-text-reference/target')})
    (OUT/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock')
    rows=json.loads(data);counts=dict(documents=len(rows['docs']),paths=len(rows['paths']),cases=len(rows['cases']),parsed=sum('modes' in r for r in rows['cases']),parse_errors=sum('parse_error' in r for r in rows['cases']),parse_panics=sum('parse_panic' in r for r in rows['cases']),mode_errors=sum('error' in m for r in rows['cases'] for m in r.get('modes',[])),mode_panics=sum('panic' in m for r in rows['cases'] for m in r.get('modes',[])))
    counts['output_limited_modes']=sum('output_limit' in m for r in rows['cases'] for m in r.get('modes',[]))
    meta=dict(dependencies=records,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_selector_reference.rs'),input_sha256={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tests/fixtures/jsonb-path/cases.json',ROOT/'tests/fixtures/jsonb-codec/cases.json']},source_tests_sha256=sha(REGISTRY/'jsonb-0.5.6/tests/it/functions.rs'),fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),counts=counts,source_profile='jsonb databend, arbitrary_precision=false; six original Selector methods; safe finite range corpus; original output exceeding existing codec limits retained and annotated')
    (OUT/'sources.json').write_text(json.dumps(meta,indent=2)+'\n');print(counts)


if __name__=='__main__':main()
