"""Full JSONB path AST oracle: original jsonb 0.5.6 / nom 8.0.0."""
from pathlib import Path
import hashlib,itertools,json,os,random,re,shutil,subprocess,tarfile,tomllib
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/jsonb-path'
REGISTRY=next((Path.home()/'.cargo/registry/src').glob('*/jsonb-0.5.6')).parent
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()


def inputs():
    result={}
    def add(s): result[s.encode() if isinstance(s,str) else s]=None
    source=(REGISTRY/'jsonb-0.5.6/tests/it/jsonpath_parser.rs').read_text()
    for s in re.findall(r'r#"(.*?)"#',source,re.S)+re.findall(r'(?<![\w#])r"(.*?)"',source): add(s)
    base=['',' ','$','@','.*','.**','[*]','?(@ > 1)','? ( @ != null )','exists($)','exists(@)','null','true','false','1.0','NaN','Infinity','"a"', '""']
    for s in base: add(s)
    names=['a','a_b','a-b','漢字😀','a\tb','a\nb','a&b','a&&b','null','true','001','a\0b','a b','',r'a\u0062',r'a\uD800',r'a\u{D800}\u{DC00}',r'a\uD834\uDD1E',r'a\"b',r'a\nb',r'a\qb',r'a\u{123}',r'a\u{12345}',r'a\uGGGG']
    for name in names:
        for prefix in ('','$.','$:', '.','$["'):
            add(prefix+name+('"]' if prefix=='$["' else ''))
        for prefix in ('$."','$:"','$["'):
            add(prefix+name+('"]' if prefix=='$["' else '"'))
    numbers=['-2147483649','-2147483648','-1','-0','0','+0','1','+1','001','2147483647','2147483648','255','256','18446744073709551615','18446744073709551616','-9223372036854775808','-9223372036854775809','9223372036854775807','9223372036854775808','1.0','.5','-.5','+1.5','1e0','1e','1e+','NaN','Infinity','inf','nan','-inf','infinity','0x1', '9'*80, '9'*80+'e-90']
    indexes=numbers[:14]+['last','LAST','Last-1','last - -1','last+1','last+-1','last--2147483648','last-2147483648','last+2147483647','last- -2147483648','last+ 2147483648']
    for i in indexes:
        add('$['+i+']');add('$[ '+i+' ]');add('$[0,'+i+',last]')
        for j in indexes[:14]+['last','last-1']:
            add('$['+i+' to '+j+']')
    for a in ('0','1','2','255','256','+1','-1','001'):
        add('$.**{'+a+'}')
        for b in ('0','1','255','256','last','LAST','+1','-1'):
            add('$.**{'+a+' to '+b+'}')
    ops=['==','!=','<>','<','<=','>','>=','starts with','+','-','*','/','%','&&','||']
    vals=['$','$.a','$.a[*]','@','@.x','null','true','false','"abc"','""']+numbers
    for op,v in itertools.product(ops,vals):
        for expr in (f'$.a {op} {v}',f'{v} {op} $.b'):
            add(expr);add('$?('+expr+')')
    for v in vals:
        for op in ('+','-'):
            add(op+v);add('$?('+op+v+')')
    for white in ('',' ','\t','\n','\r','\r\n','\f','\v',' ',' '):
        for text in ('$.a','$.a == 1','$[0 to last]','exists(@.x)','$.**{1 to last}'):
            add(white+text+white)
        add('$.a'+white+'&&'+white+'$.b == 1')
        add('$['+white+'*'+white+']')
    for byte in range(256):
        for pre,post in ((b'$.a',b'b'),(b'$."a',b'b"'),(b'$["',b'"]'),(b'$?(@ == "',b'")'),(b'$."\\',b'"')):
            add(pre+bytes([byte])+post)
    templates=['$.book[0,last-1 to last]."x\\uD834\\uDD1E"','$.a?(exists(@.b?(@ == "a")) && @.c >= -1)','exists(@.a?(exists(@.b?(@.c > 2))))','$.**{2 to last}["key"]','$.a == 184467440737095516160e-2']
    for text in templates:
        raw=text.encode()
        for i in range(len(raw)+1): add(raw[:i]);add(raw[i:])
    rng=random.Random(1030431)
    atoms=['$.a == 1','@.b != null','$.x starts with "a"','exists(@.a)','exists($.z)','+$.a','-1','$.a / 2']
    paths=['$','a','.a',':b','[0]','[last-1 to last]','.*','.**{0 to 2}','[*]','["a"]']
    for _ in range(1024):
        add(''.join(rng.choice(paths) for _ in range(rng.randrange(1,8))))
        add('$?('+rng.choice(atoms)+' '+rng.choice(['&&','||'])+' ('+rng.choice(atoms)+'))')
    # Independent numeric corpus supplies rounding/tokenization boundaries;
    # leading-dot forms actually reach nom::double before integer prefixes.
    numeric=json.loads((ROOT/'tests/fixtures/fast-float/cases.json').read_text())
    for row in numeric[::7]:
        raw=bytes.fromhex(row['hex'])
        add(b'$ == '+raw)
        if raw.startswith(b'0.'):
            add(b'$ == '+raw[1:])
        elif raw.startswith(b'-0.') or raw.startswith(b'+0.'):
            add(b'$ == '+raw[:1]+raw[2:])
    for token in (b'.5e', b'.5e+', b'.5e-', b'.5ex', b'18446744073709551616e', b'18446744073709551616e+', b'1e+', b'1e-', b'Infinityx'):
        add(b'$ == '+token);add(token)
    return list(result)


def main():
    OUT.mkdir(parents=True,exist_ok=True); build=ROOT/'.build/jsonb-path-reference';(build/'src').mkdir(parents=True,exist_ok=True)
    prior=ROOT/'tests/fixtures/jsonb-text'
    deps=json.loads((prior/'sources.json').read_text())['dependencies']
    locked=tomllib.loads((prior/'Cargo.lock').read_text())['package']
    nom=next(p for p in locked if p['name']=='nom')
    records=[]
    for dep in deps+[nom]:
        name,version=dep['name'],dep['version'];directory=REGISTRY/f'{name}-{version}';archive=Path.home()/'.cargo/registry/cache'/REGISTRY.name/f'{name}-{version}.crate'
        assert sha(archive)==dep['checksum']
        files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();files.append(dict(path=rel,sha256=sha(file)))
            if name=='nom':
                assert (directory/'LICENSE').read_bytes()==tar.extractfile(f'{name}-{version}/LICENSE').read()
            if name=='jsonb':
                assert (directory/'tests/it/jsonpath_parser.rs').read_bytes()==tar.extractfile(f'{name}-{version}/tests/it/jsonpath_parser.rs').read()
        package=tomllib.loads((directory/'Cargo.toml').read_text())['package']
        records.append(dict(name=name,version=version,checksum=dep['checksum'],license=package['license'],files=files))
    manifest='[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name,version=dep['name'],dep['version']
        manifest+=f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name=='jsonb' else f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n');shutil.copyfile(prior/'Cargo.lock',build/'Cargo.lock');shutil.copyfile(ROOT/'scripts/jsonb_path_reference.rs',build/'src/main.rs')
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml')],input=json.dumps([x.hex() for x in inputs()]).encode(),env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/jsonb-text-reference/target')})
    (OUT/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock')
    license_file=REGISTRY/f'nom-{nom["version"]}'/'LICENSE'
    license_target=ROOT/'docs/upstream/licenses/nom-MIT.txt';shutil.copyfile(license_file,license_target)
    metadata=dict(dependencies=records,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_path_reference.rs'),numeric_input_sha256=sha(ROOT/'tests/fixtures/fast-float/cases.json'),source_test_sha256=sha(REGISTRY/'jsonb-0.5.6/tests/it/jsonpath_parser.rs'),fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),nom_license_sha256=sha(license_target))
    (OUT/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    rows=json.loads(data);print('cases',len(rows),{k:sum(k in r for r in rows) for k in ('ast','error','panic')})


if __name__=='__main__':main()
