"""Run pinned Lance JSON code, jsonb profiles and Arrow StringView fixture."""
from pathlib import Path
import hashlib,json,shutil,subprocess,tarfile,tomllib
from json_value_reference import cases

ROOT=Path(__file__).resolve().parents[1]
LANCE_REVISION='ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    source=ROOT/'reference/lance';out=ROOT/'tests/fixtures/lance-json';build=ROOT/'.build/lance-json-reference'
    assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==LANCE_REVISION
    out.mkdir(parents=True,exist_ok=True);(build/'src').mkdir(parents=True,exist_ok=True)
    lock=tomllib.loads((source/'Cargo.lock').read_text())['package']
    names=['jsonb','fast-float2','ethnum','zmij','jiff','ordered-float','arrow-array','arrow-schema','arrow-buffer','arrow-data','arrow-ipc','arrow-select','arrow-cast','arrow-ord','serde_json']
    selected={name:next(p for p in lock if p['name']==name and (name!='ordered-float' or p['version']=='5.3.0')) for name in names}
    manifest='[package]\nname="akasha-lance-json-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for name,p in selected.items():
        if name=='jsonb':manifest+=f'{name}={{version="={p["version"]}",default-features=false,features=["databend"]}}\n'
        elif name=='serde_json':manifest+=f'{name}={{version="={p["version"]}",features=["preserve_order"]}}\n'
        else:manifest+=f'{name}="={p["version"]}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n')
    shutil.copyfile(ROOT/'scripts/lance_json_reference.rs',build/'src/main.rs')
    lance_file=source/'rust/lance-arrow/src/json.rs';shutil.copyfile(lance_file,build/'src/lance_json.rs')
    if (out/'Cargo.lock').exists():shutil.copyfile(out/'Cargo.lock',build/'Cargo.lock')
    flags=['--locked'] if (out/'Cargo.lock').exists() else []
    subprocess.run(['cargo','fetch',*flags,'--manifest-path',str(build/'Cargo.toml')],check=True)
    resolved=tomllib.loads((build/'Cargo.lock').read_text())['package'];provenance=[]
    for name,p in selected.items():
        actual=next(a for a in resolved if a['name']==name);assert actual['checksum']==p['checksum'],name
        directory=next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{p["version"]}'))
        archive=Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{p["version"]}.crate'
        assert sha(archive)==p['checksum'];files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{p["version"]}/{rel}').read()
                files.append(dict(path=rel,sha256=sha(file)))
        package=tomllib.loads((directory/'Cargo.toml').read_text())['package']
        provenance.append(dict(name=name,version=p['version'],checksum=p['checksum'],license=package['license'],upstream=package.get('repository'),files=files))
    extra=['', '   ', '+1', '001', '.5', '1.', '0x1a.b', '[1,,3]', '[1,2,]', "{'a':1}",'{a:1}', 'NULL', 'NaN', '-Infinity', '{"b":1,"a":2}', '{"a":1,"a":2}', '0.1', '-0', '-0.0']
    inputs=list(dict.fromkeys(cases()+[s.encode().hex() for s in extra]))
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--manifest-path',str(build/'Cargo.toml'),'--',str(out/'stringview.arrow')],input=json.dumps(inputs).encode())
    (out/'contracts.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',out/'Cargo.lock')
    metadata=dict(lance_revision=LANCE_REVISION,lance_source=dict(path='rust/lance-arrow/src/json.rs',sha256=sha(lance_file)),jsonb_features=['databend'],jsonb_default_features=False,dependencies=provenance,generator_sha256=sha(Path(__file__)),input_generator_sha256=sha(ROOT/'scripts/json_value_reference.py'),scaffold_sha256=sha(ROOT/'scripts/lance_json_reference.rs'),fixture_sha256=sha(out/'contracts.json'),ipc_sha256=sha(out/'stringview.arrow'),lock_sha256=sha(out/'Cargo.lock'))
    (out/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    rows=json.loads(data);print('cases',len(rows['cases']),'nulls',rows['arrow_nulls'],'storage',rows['recognized_storage'])
    for mode in ('extended','standard'):print(mode,{key:sum(key in r[mode] for r in rows['cases']) for key in ('value','error','panic')})


if __name__=='__main__':main()
