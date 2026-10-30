"""Pinned jsonb value encoder/decoder and container builders; no runtime Rust."""
from pathlib import Path
import hashlib
import json
import random
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inputs():
    rows = [[5], [4, False], [4, True]]
    rows += [[1, v] for v in ["", "ascii", "漢字😀", "a\0b", "x" * 8192]]
    signed = {0, -1, 1, -(2**63), 2**63 - 1}
    unsigned = {0, 1, 2**64 - 1}
    for n in (7, 15, 31, 63):
        signed.update(v for v in (-(2**n)-1, -(2**n), -(2**n)+1, 2**n-1, 2**n) if -(2**63) <= v < 2**63)
    for n in (8, 16, 32):
        unsigned.update((2**n-1, 2**n, 2**n+1))
    rng = random.Random(103031)
    signed.update(rng.randrange(-(2**63), 2**63) for _ in range(512))
    unsigned.update(rng.getrandbits(64) for _ in range(512))
    rows += [[2, str(v)] for v in sorted(signed)]
    rows += [[8, str(v)] for v in sorted(unsigned)]
    bits = {0, 1, (1 << 63), (1 << 63) + 1, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0xfff123456789abcd, 0x7fefffffffffffff}
    bits.update(rng.getrandbits(64) for _ in range(1024))
    rows += [[3, str(v)] for v in sorted(bits)]
    legacy = []
    for width in (8, 16, 32):
        for value in (0, 1, -1, -(1 << (width*8-1)), (1 << (width*8-1))-1):
            for scale in (0, 2, 18, 38, 76, 255):
                raw = value.to_bytes(width, 'big', signed=True)
                rows.append([9, raw.hex(), scale])
                if width != 8:
                    payload = b'\x70' + raw + b'\x26' + bytes([scale])
                    legacy.append((b'\x20\0\0\0' + (0x20000000 | len(payload)).to_bytes(4, 'big') + payload).hex())
    rows += [[10, v.hex()] for v in (b'', b'\0', bytes(range(256)), b'\xff\xfe\x80')]
    rows += [[11, v] for v in (-(2**31), -1, 0, 1, 2**31-1)]
    for value in (-(2**63), -1, 0, 1, 2**63-1):
        rows.append([12, str(value)])
        for offset in (-2**31, -3600, 0, 28800, 2**31-1):
            rows.append([13, str(value), offset])
        for hours in (-128, -1, 0, 8, 127):
            payload = b'\x30' + value.to_bytes(8, 'big', signed=True) + hours.to_bytes(1, 'big', signed=True)
            legacy.append((b'\x20\0\0\0' + (0x60000000 | len(payload)).to_bytes(4, 'big') + payload).hex())
        for months, days in ((0, 0), (1, -1), (-2**31, 2**31-1)):
            rows.append([14, months, days, str(value)])
    scalars = rows.copy()
    rows += [[6, []], [7, []]]
    for _ in range(256):
        members = [rng.choice(scalars) for _ in range(rng.randrange(0, 10))]
        rows.append([6, members])
        rows.append([7, [[k, rng.choice(scalars)] for k in ["😀", "", "nul\0key", "漢字", "a", "[0]"]]])
    # Send deep values as source JSON bytes so the tagged fixture wrapper does
    # not exhaust serde_json's unrelated input-envelope recursion limit.
    nested = 'null'
    nested_text = []
    for i in range(64):
        nested = '[' + nested + ']' if i % 2 else '{"inner":' + nested + '}'
        nested_text.append(nested.encode().hex())
    source = json.loads((ROOT/'tests/fixtures/lance-json/contracts.json').read_text())
    return dict(typed=rows, text=[v['hex'] for v in source['cases']] + nested_text, legacy=legacy)


def main():
    out = ROOT/'tests/fixtures/jsonb-codec'
    build = ROOT/'.build/jsonb-codec-reference'
    out.mkdir(parents=True, exist_ok=True)
    (build/'src').mkdir(parents=True, exist_ok=True)
    source = json.loads((ROOT/'tests/fixtures/lance-json/sources.json').read_text())
    names = {'jsonb', 'serde_json', 'ethnum', 'fast-float2', 'jiff', 'ordered-float', 'zmij'}
    deps = [v for v in source['dependencies'] if v['name'] in names]
    manifest = '[package]\nname="akasha-jsonb-codec-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for d in deps:
        name, version = d['name'], d['version']
        if name == 'jsonb':
            manifest += f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n'
        else:
            manifest += f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n')
    shutil.copyfile(ROOT/'scripts/jsonb_codec_reference.rs', build/'src/main.rs')
    if (out/'Cargo.lock').exists():
        shutil.copyfile(out/'Cargo.lock', build/'Cargo.lock')
    subprocess.run(['cargo', 'fetch', *(['--locked'] if (out/'Cargo.lock').exists() else []), '--manifest-path', str(build/'Cargo.toml')], check=True)
    resolved = tomllib.loads((build/'Cargo.lock').read_text())['package']
    for d in deps:
        name, version = d['name'], d['version']
        assert next(v for v in resolved if v['name'] == name)['checksum'] == d['checksum']
        directory = next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{version}'))
        archive = Path.home()/'.cargo/registry/cache'/directory.parent.name/f'{name}-{version}.crate'
        assert sha(archive) == d['checksum']
        with tarfile.open(archive) as tar:
            for file in d['files']:
                path = directory/file['path']
                assert sha(path) == file['sha256']
                assert path.read_bytes() == tar.extractfile(f'{name}-{version}/{file["path"]}').read()
    result = subprocess.check_output(['cargo', 'run', '--quiet', '--release', '--locked', '--manifest-path', str(build/'Cargo.toml')], input=json.dumps(inputs()).encode())
    (out/'cases.json').write_bytes(result)
    shutil.copyfile(build/'Cargo.lock', out/'Cargo.lock')
    metadata = dict(dependencies=deps, source_profile=dict(jsonb_default_features=False, jsonb_features=['databend']), generator_sha256=sha(__file__), scaffold_sha256=sha(ROOT/'scripts/jsonb_codec_reference.rs'), input_fixture_sha256=sha(ROOT/'tests/fixtures/lance-json/contracts.json'), input_sources_sha256=sha(ROOT/'tests/fixtures/lance-json/sources.json'), fixture_sha256=sha(out/'cases.json'), lock_sha256=sha(out/'Cargo.lock'))
    (out/'sources.json').write_text(json.dumps(metadata, indent=2)+'\n')
    data = json.loads(result)
    print('codec cases', len(data['cases']), 'legacy', len(data['legacy']), 'duplicate', data['duplicate_error'])


if __name__ == '__main__':
    main()
