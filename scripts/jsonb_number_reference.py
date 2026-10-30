"""Original jsonb Number/ethnum oracle; no replacement numeric implementation."""
from pathlib import Path
import hashlib, itertools, json, os, random, shutil, subprocess, tarfile, tomllib

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'tests/fixtures/jsonb-number'
REGISTRY=next((Path.home()/'.cargo/registry/src').glob('*/jsonb-0.5.6')).parent
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()


def inputs():
    values=[]; ids={}; pairs={}; wide={}
    def add(kind,value,scale=0):
        width=8 if kind<4 else 16 if kind==4 else 32
        raw=(value % (1 << (width*8))).to_bytes(width,'big').hex()
        key=(kind,raw,scale)
        if key not in ids: ids[key]=len(values);values.append(key)
        return ids[key]
    def pair(a,b): pairs[(a,b)]=None
    ints=[-2**63,-2**63+1,-2**53-1,-2**32,-3,-2,-1,0,1,2,3,2**32,2**53-1,2**53,2**53+1,2**63-1]
    basics=[]
    for n in ints: basics.append(add(0,n))
    for n in [0,1,2,3,2**32,2**53-1,2**53,2**53+1,2**63-1,2**63,2**63+1,2**64-2,2**64-1]: basics.append(add(1,n))
    for n in [0,1,2,0x8000000000000000,0x8000000000000001,0x0010000000000000,0x3ff0000000000000,0xbff0000000000000,0x4008000000000000,0xc008000000000000,0x7fefffffffffffff,0xffefffffffffffff,0x7ff0000000000000,0xfff0000000000000,0x7ff8000000000000,0xfff8000000000000,0x7ff0000000000001,0x7ff8000000001234]: basics.append(add(2,n))
    for k,bits in [(3,64),(4,128),(5,256)]:
        for n in [-(2**(bits-1)),-1,0,1,2**(bits-1)-1]:
            for scale in [0,1,2,38,39,77,78,127,128,254,255]: basics.append(add(k,n,scale))
    for a,b in itertools.product(basics,repeat=2): pair(a,b)
    # Every scale byte, all widths, exact/overflowing adjustment on either side.
    for k,bits in [(3,64),(4,128),(5,256)]:
        for scale in range(256):
            for n in [-(2**(bits-1)),-2**53-1,-1,0,1,2**53+1,2**(bits-1)-1]:
                a=add(k,n,scale)
                for b in [add(k,n),add(k,1,255-scale),add(0,1),add(1,2**64-1)]:pair(a,b);pair(b,a)
    rng=random.Random(1030442)
    randoms=[]
    for k in range(6):
        for _ in range(512):
            bits=64 if k<4 else 128 if k==4 else 256
            randoms.append(add(k,rng.getrandbits(bits),rng.randrange(256) if k>=3 else 0))
    for _ in range(8192): pair(rng.choice(randoms),rng.choice(randoms+basics))
    # ethnum primitive oracle independent of Number's comparison reachability.
    bounds=[-2**255,-2**255+1,-2**128,-2**127,-2,-1,0,1,2,2**64-1,2**127-1,2**128-1,2**254,2**255-1]
    def wide_pair(a,b):wide[((a%(2**256)).to_bytes(32,'big').hex(),(b%(2**256)).to_bytes(32,'big').hex())]=None
    for a,b in itertools.product(bounds,repeat=2):wide_pair(a,b)
    for b in [3,7,10,2**32-1,2**64+1,2**127-1,2**128+1]:
        for a in [2**255//b-1,2**255//b,2**255//b+1]:
            for x,y in itertools.product([-1,1],repeat=2):wide_pair(x*a,y*b);wide_pair(y*b,x*a)
    for _ in range(2048):
        a=rng.getrandbits(rng.choice([64,128,192,256]));b=rng.getrandbits(rng.choice([8,64,128,256]))
        wide_pair(-a if rng.randrange(2) else a,-b if rng.randrange(2) else b)
    codec=json.loads((ROOT/'tests/fixtures/jsonb-codec/cases.json').read_text())
    return dict(values=values,pairs=list(pairs),wide=list(wide),bodies=list(dict.fromkeys(r['hex'] for r in codec['cases']+codec['legacy'])))


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    build=ROOT/'.build/jsonb-number-reference';(build/'src').mkdir(parents=True,exist_ok=True)
    prior=ROOT/'tests/fixtures/jsonb-text'
    deps=json.loads((prior/'sources.json').read_text())['dependencies']
    arrow=next(d for d in json.loads((ROOT/'tests/fixtures/arrow-json/sources.json').read_text())['dependencies'] if d['name']=='arrow-buffer')
    records=[]
    for dep in deps+[arrow]:
        name,version=dep['name'],dep['version'];directory=REGISTRY/f'{name}-{version}'
        archive=Path.home()/'.cargo/registry/cache'/REGISTRY.name/f'{name}-{version}.crate'
        assert sha(archive)==dep['checksum']
        files=[]
        with tarfile.open(archive) as tar:
            for file in sorted((directory/'src').rglob('*.rs')):
                rel=str(file.relative_to(directory));assert file.read_bytes()==tar.extractfile(f'{name}-{version}/{rel}').read()
                files.append(dict(path=rel,sha256=sha(file)))
            if name=='ordered-float':
                assert (directory/'LICENSE-MIT').read_bytes()==tar.extractfile(f'{name}-{version}/LICENSE-MIT').read()
                shutil.copyfile(directory/'LICENSE-MIT',ROOT/'docs/upstream/licenses/ordered-float-MIT.txt')
        records.append(dict(name=name,version=version,checksum=dep['checksum'],license=dep['license'],files=files))
    manifest='[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name,version=dep['name'],dep['version']
        manifest+=f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name=='jsonb' else f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n');shutil.copyfile(prior/'Cargo.lock',build/'Cargo.lock')
    shutil.copyfile(ROOT/'scripts/jsonb_number_reference.rs',build/'src/main.rs')
    data=subprocess.check_output(['cargo','run','--quiet','--release','--locked','--offline','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs()).encode(),env={**os.environ,'CARGO_TARGET_DIR':str(ROOT/'.build/jsonb-text-reference/target')})
    (OUT/'cases.json').write_bytes(data);shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock')
    rows=json.loads(data)
    counts=dict(unary=len(rows['unary']),pairs=len(rows['pairs']),wide=len(rows['wide']),powers=len(rows['powers']),numeric_bodies=len(rows['bodies']),arithmetic_errors=sum('error' in x for r in rows['pairs'] for x in r['ops']))
    metadata=dict(dependencies=records,generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_number_reference.rs'),input_codec_sha256=sha(ROOT/'tests/fixtures/jsonb-codec/cases.json'),fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),ordered_float_license_sha256=sha(ROOT/'docs/upstream/licenses/ordered-float-MIT.txt'),counts=counts,source_profile='jsonb databend, arbitrary_precision=false, Rust release overflow checks off; original Number and ethnum operations')
    (OUT/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(counts)


if __name__=='__main__':main()
