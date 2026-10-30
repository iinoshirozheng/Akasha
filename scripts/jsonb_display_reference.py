"""Run original jsonb Display and ethnum division; no replacement formatter."""
from pathlib import Path
import hashlib,json,os,random,shutil,subprocess,tarfile

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/jsonb-display'
REGISTRY=next((Path.home()/'.cargo/registry/src').glob('*/jsonb-0.5.6')).parent
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
INPUTS=['tests/fixtures/jsonb-number/cases.json','tests/fixtures/jsonb-path/cases.json','tests/fixtures/zmij/cases.json']

def inputs():
    numbers={tuple(r['input']):None for r in json.loads((ROOT/INPUTS[0]).read_text())['unary']}
    for r in json.loads((ROOT/INPUTS[2]).read_text()):numbers[(2,int(r['bits']).to_bytes(8,'big').hex(),0)]=None
    for kind,bits in [(3,64),(4,128),(5,256)]:
        limit=2**(bits-1)
        for power in range(0,78):
            for value in [10**power-1,10**power,10**power+1]:
                for sign in [-1,1]:
                    n=sign*value
                    if -limit<=n<limit:
                        for scale in [0,1,18,19,37,38,39,75,76,77,78,255]:
                            numbers[(kind,(n%(2**bits)).to_bytes(bits//8,'big').hex(),scale)]=None
    paths=[r['hex'] for r in json.loads((ROOT/INPUTS[1]).read_text())]
    divisions={};rng=random.Random(1030451)
    def div(a,b):divisions[(a.to_bytes(32,'big').hex(),b.to_bytes(16,'big').hex())]=None
    for bit in range(128):
        for b in [max(1,2**bit-1),2**bit,min(2**128-1,2**bit+1)]:
            for high in [0,b-1,b,min(2**128-1,b+1),2**128-1]:
                for low in [0,1,2**64-1,2**128-1]:div(high*2**128+low,b)
    for _ in range(4096):div(rng.getrandbits(256),rng.getrandbits(128) or 1)
    return dict(numbers=list(numbers),paths=paths,divisions=list(divisions))

def main():
    OUT.mkdir(parents=True,exist_ok=True);build=ROOT/'.build/jsonb-display-reference';(build/'src').mkdir(parents=True,exist_ok=True)
    prior=ROOT/'tests/fixtures/jsonb-text';deps=json.loads((prior/'sources.json').read_text())['dependencies'];records=[]
    for dep in deps:
        name,version=dep['name'],dep['version'];directory=REGISTRY/f'{name}-{version}';archive=Path.home()/'.cargo/registry/cache'/REGISTRY.name/f'{name}-{version}.crate'
        assert sha(archive)==dep['checksum'];files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();files.append(dict(path=rel,sha256=sha(file)))
        records.append(dict(name=name,version=version,checksum=dep['checksum'],license=dep['license'],files=files))
    manifest='[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name,version=dep['name'],dep['version'];manifest+=f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name=='jsonb' else f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n');shutil.copyfile(prior/'Cargo.lock',build/'Cargo.lock');shutil.copyfile(ROOT/'scripts/jsonb_display_reference.rs',build/'src/main.rs')
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs()).encode(),env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/jsonb-text-reference/target')})
    (OUT/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock');rows=json.loads(data)
    counts=dict(numbers=len(rows['numbers']),number_panics=sum('panic' in r for r in rows['numbers']),paths=len(rows['paths']),formatted_paths=sum('text' in r for r in rows['paths']),path_parse_errors=sum('parse_error' in r for r in rows['paths']),path_panics=sum('panic' in r for r in rows['paths']),divisions=len(rows['divisions']))
    meta=dict(dependencies=records,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_display_reference.rs'),input_sha256={f:sha(ROOT/f) for f in INPUTS},fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),counts=counts,source_profile='jsonb databend; original Number/JsonPath Display and ethnum U256 division; locked release overflow behavior')
    (OUT/'sources.json').write_text(json.dumps(meta,indent=2)+'\n');print(counts)

if __name__=='__main__':main()
