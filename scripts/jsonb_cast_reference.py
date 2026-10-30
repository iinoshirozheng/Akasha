"""Original jsonb Number conversions, RawJsonb casts and ethnum division."""
from pathlib import Path
import hashlib,json,os,random,shutil,subprocess,tarfile

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/jsonb-cast'
REGISTRY=next((Path.home()/'.cargo/registry/src').glob('*/jsonb-0.5.6')).parent
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
INPUTS=['tests/fixtures/jsonb-display/cases.json','tests/fixtures/jsonb-codec/cases.json','tests/fixtures/fast-float/cases.json']

def inputs():
    display=json.loads((ROOT/INPUTS[0]).read_text());numbers={tuple(r['input']):None for r in display['numbers']}
    for kind,bits in [(3,64),(4,128),(5,256)]:
        for scale in range(78):
            power=10**scale
            for target in [0,1,2**63-1,2**63,2**64-1,2**64,2**127-1,2**127]:
                for delta in [-power//2-1,-power//2,-power//2+1,-1,0,1,power//2-1,power//2,power//2+1]:
                    for sign in [-1,1]:
                        value=sign*(target*power+delta)
                        if -2**(bits-1)<=value<2**(bits-1):numbers[(kind,(value%(2**bits)).to_bytes(bits//8,'big').hex(),scale)]=None
    strings={s:None for s in ['', 'true','false','yes','no','TRUE','FaLsE','YES','No','1','0','-0','+0','true ',' true','yes\n','null','NaN','-NaN','INF','infinity','+Infinity','-infinity','nan(1)','1_000','0x10','１','١','\0','漢字😀','9223372036854775807','9223372036854775808','18446744073709551615','18446744073709551616']}
    for r in json.loads((ROOT/INPUTS[2]).read_text()):
        try:strings[bytes.fromhex(r['hex']).decode('utf8')]=None
        except UnicodeDecodeError:pass
    for n in [0,1,2,-1,-2,2**63-1,-2**63,2**64-1]:
        for suffix in ['', '.0','.4999999999999999','.5','.5000000000000001','e0','e-1']:
            for prefix in ['', '+',' ','\t']:strings[prefix+str(n)+suffix]=None
    codec=json.loads((ROOT/INPUTS[1]).read_text());bodies=list(dict.fromkeys(r['hex'] for r in codec['cases']+codec['legacy']))
    divisions={};rng=random.Random(1030462);maximum=2**256-1
    def div(a,b):divisions[(a.to_bytes(32,'big').hex(),b.to_bytes(32,'big').hex())]=None
    for r in display['divisions']:div(int(r['input'][0],16),int(r['input'][1],16))
    for bit in range(128,256):
        for b in [2**bit-1,2**bit,2**bit+1]:
            for a in [0,1,b-1,b,b+1,maximum]:div(a,b)
    for _ in range(8192):div(rng.getrandbits(256),rng.getrandbits(rng.randrange(129,257)) or 1)
    return dict(numbers=list(numbers),strings=list(strings),bodies=bodies,divisions=list(divisions))

def main():
    OUT.mkdir(parents=True,exist_ok=True);build=ROOT/'.build/jsonb-cast-reference';(build/'src').mkdir(parents=True,exist_ok=True)
    rust_revision='ded5c06cf21d2b93bffd5d884aa6e96934ee4234'
    assert rust_revision in subprocess.check_output(['rustc','-vV'],text=True)
    rust_path=Path(subprocess.check_output(['rustc','--print','sysroot'],text=True).strip())/'lib/rustlib/src/rust/library/core/src/num/mod.rs'
    assert sha(rust_path)=='e10e3021435c63df4d2ae366874631e27a25a39c6cdc2227a9507a80565d5245'
    assert sha(ROOT/'docs/upstream/licenses/rust-MIT.txt')=='b71bd43a069ca0641a9ecfe585ca7b3c53b5cc1608f8b68321168698e28b5ea1'
    rust=dict(name='rust-core-num',version='1.92.0',revision=rust_revision,source='library/core/src/num/mod.rs',source_sha256=sha(rust_path),unit='from_ascii_radix radix-10 checked integer accumulation',license_file='docs/upstream/licenses/rust-MIT.txt',license_sha256=sha(ROOT/'docs/upstream/licenses/rust-MIT.txt'))
    prior=ROOT/'tests/fixtures/jsonb-text';deps=json.loads((prior/'sources.json').read_text())['dependencies'];records=[]
    for dep in deps:
        name,version=dep['name'],dep['version'];directory=REGISTRY/f'{name}-{version}';archive=Path.home()/'.cargo/registry/cache'/REGISTRY.name/f'{name}-{version}.crate';assert sha(archive)==dep['checksum'];files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read();files.append(dict(path=rel,sha256=sha(file)))
        records.append(dict(name=name,version=version,checksum=dep['checksum'],license=dep['license'],files=files))
    manifest='[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name,version=dep['name'],dep['version'];manifest+=f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name=='jsonb' else f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n');shutil.copyfile(prior/'Cargo.lock',build/'Cargo.lock');shutil.copyfile(ROOT/'scripts/jsonb_cast_reference.rs',build/'src/main.rs')
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs()).encode(),env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/jsonb-text-reference/target')})
    (OUT/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock');rows=json.loads(data)
    counts=dict(numbers=len(rows['numbers']),casts=len(rows['casts']),cast_errors=sum('error' in c for r in rows['casts'] for c in r['casts']),cast_panics=sum('panic' in c for r in rows['casts'] for c in r['casts']),divisions=len(rows['divisions']))
    meta=dict(dependencies=records,rust_core=rust,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_cast_reference.rs'),input_sha256={f:sha(ROOT/f) for f in INPUTS},fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),counts=counts,source_profile='jsonb databend; original Number and RawJsonb conversions; ethnum full U256 division; locked release')
    (OUT/'sources.json').write_text(json.dumps(meta,indent=2)+'\n');print(counts)

if __name__=='__main__':main()
