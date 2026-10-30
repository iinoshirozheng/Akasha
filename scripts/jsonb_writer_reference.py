"""Pinned RawJsonb text writer oracle, including source extension dependencies."""
from pathlib import Path
import hashlib
import json
import random
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'tests/fixtures/jsonb-writer'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inputs():
    cases = {}
    def add(body):
        cases[body.hex() if isinstance(body, bytes) else body] = None
    def scalar(tag, body):
        add(bytes.fromhex('20000000') + (tag | len(body)).to_bytes(4, 'big') + body)
    def extension(tag, body):
        scalar(0x60000000, bytes([tag])+body)
    def date(day):
        extension(0x10, day.to_bytes(4, 'big', signed=True))
    def timestamp(micros, offset=None):
        data = micros.to_bytes(8, 'big', signed=True)
        extension(0x20 if offset is None else 0x30, data if offset is None else data+offset.to_bytes(4, 'big', signed=True))
    def interval(months, days, micros):
        extension(0x40, months.to_bytes(4, 'big', signed=True)+days.to_bytes(4, 'big', signed=True)+micros.to_bytes(8, 'big', signed=True))
    codec = json.loads((ROOT/'tests/fixtures/jsonb-codec/cases.json').read_text())
    for row in codec['cases'] + codec['legacy']:
        add(row['hex'])
    for row in json.loads((ROOT/'tests/fixtures/jsonb-text/cases.json').read_text()):
        for mode in ('standard', 'extended'):
            if 'hex' in row[mode]:
                add(row[mode]['hex'])
    rng = random.Random(1030318)
    # Every scale byte; integer extrema, casts near F64 rounding boundaries,
    # and high/low-word rounding in ethnum's actual conversion.
    for width in (8, 16, 32):
        values = [0, 1, -1, -(1 << (width*8-1)), (1 << (width*8-1))-1]
        values += [v for v in (2**53-1, 2**53+1, 2**127+2**74-1, -(2**127+2**74+1), 2**254+2**201+2**127) if -(1 << (width*8-1)) <= v < 1 << (width*8-1)]
        for scale in range(256):
            for value in values:
                scalar(0x20000000, b'\x70'+value.to_bytes(width, 'big', signed=True)+bytes([scale]))
        for _ in range(512):
            value = rng.randrange(-(1 << (width*8-1)), 1 << (width*8-1))
            scalar(0x20000000, b'\x70'+value.to_bytes(width, 'big', signed=True)+bytes([rng.randrange(256)]))
    # Gregorian leap/century cycles, epoch/range edges, BCE and year zero.
    for start in (-719528, -25567, 10957):
        for day in range(start-2, start+1463):
            date(day)
    for day in (-2**31, -4371588, -4371587, -4371586, -1, 0, 1, 2932895, 2932896, 2932897, 2**31-1):
        date(day)
    for _ in range(2048):
        date(rng.randrange(-4371587, 2932897))
    offsets = (-93599,-86400,-3601,-3600,-3599,-61,-60,-59,-1,0,1,59,60,61,3599,3600,3601,86400,93599,-93600,93600,-2**31,2**31-1)
    times = (-2**63, -377705023201000001, -377705023201000000, -377705023200999999, -62167219200000000, -62198755200000000, -86400000001, -1000001, -1000000, -999999, -1, 0, 1, 999999, 1000000, 253402207200000000, 253402207200999999, 253402207201000000, 2**63-1)
    for micros in times:
        timestamp(micros)
        for offset in offsets:
            timestamp(micros, offset)
    for _ in range(1024):
        timestamp(rng.randrange(-2**63, 2**63), rng.randrange(-93599, 93600))
    for months in (-2**31,-25,-24,-13,-12,-11,-1,0,1,11,12,13,24,25,2**31-1):
        for days in (-2**31,-2,-1,0,1,2,2**31-1):
            for micros in (-2**63,-360000000001,-3600000000,-1000001,-1000000,-1,0,1,1000000,1000001,3600000000,360000000001,2**63-1):
                interval(months, days, micros)
    # Unique unsorted raw keys retain wire order; both key/value escaping paths.
    keys = [b'z', b'a', b'quote"slash\\', b'\0', '漢字😀'.encode()]
    vals = [b'\0', b'\x60'+bytes.fromhex('8000000000000000'), b'\x10', b'\x20', b'\x30']
    body = (0x40000000|len(keys)).to_bytes(4,'big')
    body += b''.join((0x10000000|len(v)).to_bytes(4,'big') for v in keys)
    body += b''.join((0x20000000|len(v)).to_bytes(4,'big') for v in vals)
    add(body+b''.join(keys)+b''.join(vals))
    for char in list(range(128))+[0x80,0x2028,0x2029,0x1f600,0x10ffff]:
        scalar(0x10000000, chr(char).encode())
    return list(cases)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    build = ROOT/'.build/jsonb-writer-reference'
    (build/'src').mkdir(parents=True, exist_ok=True)
    deps = json.loads((ROOT/'tests/fixtures/jsonb-codec/sources.json').read_text())['dependencies']
    manifest = '[package]\nname="akasha-jsonb-writer-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name, version = dep['name'], dep['version']
        manifest += f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n' if name == 'jsonb' else f'{name}="={version}"\n'
        directory = next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{version}'))
        archive = Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{version}.crate'
        assert sha(archive) == dep['checksum']
        with tarfile.open(archive) as tar:
            for file in dep['files']:
                path = directory/file['path']
                assert sha(path) == file['sha256']
                assert path.read_bytes() == tar.extractfile(f'{name}-{version}/{file["path"]}').read()
            if name in ('ethnum', 'jiff'):
                assert (directory/'LICENSE-MIT').read_bytes() == tar.extractfile(f'{name}-{version}/LICENSE-MIT').read()
        if name in ('ethnum', 'jiff'):
            shutil.copyfile(directory/'LICENSE-MIT', ROOT/f'docs/upstream/licenses/{name}-MIT.txt')
            dep['license_file'] = f'docs/upstream/licenses/{name}-MIT.txt'
            dep['license_sha256'] = sha(directory/'LICENSE-MIT')
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n')
    shutil.copyfile(ROOT/'scripts/jsonb_writer_reference.rs', build/'src/main.rs')
    if (OUT/'Cargo.lock').exists():
        shutil.copyfile(OUT/'Cargo.lock', build/'Cargo.lock')
    subprocess.run(['cargo','fetch',*(['--locked'] if (OUT/'Cargo.lock').exists() else []),'--manifest-path',str(build/'Cargo.toml')],check=True)
    resolved = tomllib.loads((build/'Cargo.lock').read_text())['package']
    for dep in deps:
        assert next(p for p in resolved if p['name']==dep['name'])['checksum']==dep['checksum']
    result = subprocess.check_output(['cargo','run','--quiet','--release','--locked','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs()).encode())
    (OUT/'cases.json').write_bytes(result)
    shutil.copyfile(build/'Cargo.lock',OUT/'Cargo.lock')
    rows=json.loads(result)
    counts={'total':len(rows),'output':sum('compact' in row for row in rows),'source_panic':sum('panic' in row for row in rows)}
    metadata=dict(dependencies=deps,source_profile=dict(jsonb_default_features=False,jsonb_features=['databend'],arbitrary_precision=False,writer='RawJsonb serde compact/pretty; Value::Display is not used'),generator_sha256=sha(__file__),scaffold_sha256=sha(ROOT/'scripts/jsonb_writer_reference.rs'),input_fixtures_sha256={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tests/fixtures/jsonb-codec/cases.json',ROOT/'tests/fixtures/jsonb-text/cases.json']},fixture_sha256=sha(OUT/'cases.json'),lock_sha256=sha(OUT/'Cargo.lock'),counts=counts)
    (OUT/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(counts)


if __name__ == '__main__':
    main()
