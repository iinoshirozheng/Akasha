"""Run pinned jsonb text profiles; expected binary bodies come from Rust."""
from pathlib import Path
import hashlib
import itertools
import json
import random
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'tests/fixtures/jsonb-text'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inputs():
    cases = dict.fromkeys(bytes.fromhex(row['hex']) for row in json.loads((ROOT/'tests/fixtures/fast-float/cases.json').read_text()))
    def add(value):
        cases[value.encode() if isinstance(value, str) else value] = None
    for word in ('null', 'true', 'false', 'nan', 'infinity'):
        for chars in itertools.product(*[(c, c.upper()) for c in word]):
            for sign in ('', '+', '-'):
                add(sign+''.join(chars))
    escapes = [r'\u0000', r'\u007f', r'\u0080', r'\u07ff', r'\u0800', r'\uffff', r'\uD800', r'\uDFFF', r'\uD834\uDD1E', r'\uD800\u0001', r'\uD800\uD800\uDC00', r'\u{D800}\u{DC00}', r'\u{1234}', r'\u{1}', r'\u{1f600}', r'\u{00000}', r'\uGGGG', r'\x41', r"\'", r'\"', r'\/', r'\\', r'\b', r'\f', r'\n', r'\r', r'\t']
    for text in escapes + ['', '漢字😀', 'a\0b', '\n\r\t\f\v']:
        for quote in ('"', "'"):
            add(quote+text+quote)
            add('{'+quote+text+quote+':0}')
            add(quote+'prefix'+text+'suffix'+quote)
    for byte in range(256):
        add(b'"a'+bytes([byte])+b'b"')
        add(b'"\\'+bytes([byte])+b'"')
        add(b'{'+bytes([byte])+b':1}')
    for white in (' ', '\t', '\n', '\r', '\f', '\v', '\u00a0', '\u2003', '\ufeff', r'\n', r'\r', r'\t', r'\x0C', r'\x0c'):
        for text in ('', 'null', '[1,,2,]', '{"a":1}', '"a"'):
            add(white+text+white)
            add('['+white+text+white+']')
    for text in ('[]', '[,]', '[,,]', '[1,]', '[1,,]', '[,1]', '{a:1,$:2,_:3,漢字:4,😀:5}', '{1a:1}', '{"a":1,}', '{"a":1,"\\u0061":2}', "{'a':1,a:2}", '{"":null,"a\\u0000b":[-0.,+0.0]}'):
        add(text)
    for n in (0, 1, 2**63-1, 2**63, 2**64-1, 2**64, 2**127-1, 2**127, 2**128-1, 2**128):
        for prefix in ('0x', '-0x', '+0X', '00x'):
            add(prefix+format(n,'x'))
            for fraction in ('', '0', 'f', 'ff', '0'*32+'1', 'f'*32, 'f'*33):
                add(prefix+format(n,'x')+'.'+fraction)
    for n in range(1, 280):
        for digit in ('0', '1', 'f'):
            add('0x0.'+'0'*n+digit)
            add('-0x1.'+'0'*n+digit)
    for n in (18, 19, 20, 37, 38, 39, 75, 76, 77, 128):
        for text in ('9'*n, '0'*n, '0'*n+'1'):
            for sign in ('', '-', '+'):
                for suffix in ('', '.', '.0', '.e0', 'e0', 'e999999999'):
                    add(sign+text+suffix)
    # Every truncation around string escapes, containers, identifiers and hex.
    for text in ('{"a":[1,"\\uD834\\uDD1E",false]}', "{a:[1,,],b:'\\u{1234}'}", '"\\uD800\\u{DC00}"', '-Infinity', '-0x123.abcdef'):
        raw = text.encode()
        for n in range(len(raw)+1):
            add(raw[:n])
    rng = random.Random(1030317)
    atoms = ['null', 'NaN', '-Infinity', 'True', '+0001.', '0x1.abc', '"\\uD800"', "'漢字'", '.05', '-0.0']
    for _ in range(512):
        add('['+','.join(rng.choice(atoms+['']) for _ in range(rng.randrange(1,10)))+']')
        add('{'+','.join(f'key{i}:'+rng.choice(atoms) for i in range(rng.randrange(1,10)))+'}')
    for n in (1, 31, 63, 64):
        add('['*n+'null'+']'*n)
        add('{"a":'*n+'null'+'}'*n)
    return list(cases)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    build = ROOT/'.build/jsonb-text-reference'
    (build/'src').mkdir(parents=True, exist_ok=True)
    deps = json.loads((ROOT/'tests/fixtures/jsonb-codec/sources.json').read_text())['dependencies']
    manifest = '[package]\nname="akasha-jsonb-text-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\n'
    for dep in deps:
        name, version = dep['name'], dep['version']
        if name == 'jsonb':
            manifest += f'{name}={{version="={version}",default-features=false,features=["databend"]}}\n'
        else:
            manifest += f'{name}="={version}"\n'
    (build/'Cargo.toml').write_text(manifest+'[workspace]\n')
    shutil.copyfile(ROOT/'scripts/jsonb_text_reference.rs', build/'src/main.rs')
    if (OUT/'Cargo.lock').exists():
        shutil.copyfile(OUT/'Cargo.lock', build/'Cargo.lock')
    subprocess.run(['cargo', 'fetch', *(['--locked'] if (OUT/'Cargo.lock').exists() else []), '--manifest-path', str(build/'Cargo.toml')], check=True)
    locked = tomllib.loads((build/'Cargo.lock').read_text())['package']
    for dep in deps:
        name, version = dep['name'], dep['version']
        assert next(p for p in locked if p['name'] == name)['checksum'] == dep['checksum']
        source = next((Path.home()/'.cargo/registry/src').glob(f'*/{name}-{version}'))
        archive = Path.home()/'.cargo/registry/cache'/source.parent.name/f'{name}-{version}.crate'
        assert sha(archive) == dep['checksum']
        with tarfile.open(archive) as tar:
            for file in dep['files']:
                path = source/file['path']
                assert sha(path) == file['sha256']
                assert path.read_bytes() == tar.extractfile(f'{name}-{version}/{file["path"]}').read()
    values = inputs()
    data = subprocess.check_output(['cargo', 'run', '--quiet', '--release', '--locked', '--manifest-path', str(build/'Cargo.toml')], input=json.dumps([v.hex() for v in values]).encode())
    (OUT/'cases.json').write_bytes(data)
    shutil.copyfile(build/'Cargo.lock', OUT/'Cargo.lock')
    rows = json.loads(data)
    counts = {mode:{key:sum(key in r[mode] for r in rows) for key in ('hex', 'error', 'panic')} for mode in ('standard','extended')}
    metadata = dict(dependencies=deps, source_profile={'jsonb_default_features':False,'jsonb_features':['databend'],'arbitrary_precision':False}, generator_sha256=sha(__file__), scaffold_sha256=sha(ROOT/'scripts/jsonb_text_reference.rs'), input_fixture_sha256=sha(ROOT/'tests/fixtures/fast-float/cases.json'), fixture_sha256=sha(OUT/'cases.json'), lock_sha256=sha(OUT/'Cargo.lock'), counts=counts)
    (OUT/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(len(rows),counts)


if __name__ == '__main__':
    main()
