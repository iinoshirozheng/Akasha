"""Reproduce zmij F64 fixtures/tables by executing the pinned original Rust."""
from collections import Counter
from pathlib import Path
import hashlib
import json
import random
import re
import shutil
import struct
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'tests/fixtures/zmij'
TABLES = ROOT / 'src/akasha/document/zmij_tables.mojo'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inputs(source):
    cases = {}
    def add(bits):
        if not 0 <= bits < (1 << 64):
            return
        cases[bits] = None
        cases[bits ^ (1 << 63)] = None
    # Every IEEE exponent: irregular significands, rounding-boundary neighbors,
    # leading/trailing bits; both signs, including NaNs and infinities.
    for exponent in range(2048):
        for fraction in (0, 1, 2, 3, (1 << 51)-1, 1 << 51, (1 << 52)-3, (1 << 52)-2, (1 << 52)-1):
            add((exponent << 52) | fraction)
    for fraction in range(1, 1025):
        add(fraction)
    for row in json.loads((ROOT/'tests/fixtures/fast-float/cases.json').read_text()):
        if row['full'] != '-':
            add(int(row['full']))
    texts = ['5.0507837461e-27', '5.0507837461000010e-27', '5.444310685350916e14']
    for path in sorted((source/'tests').glob('*.rs')):
        texts += re.findall(r'dtoa\((-?[0-9]+\.[0-9]+(?:e[+\-]?[0-9]+)?)\)', path.read_text())
    texts += [f'1e{exponent}' for exponent in range(-323, 309)]
    for text in texts:
        bits = struct.unpack('>Q', struct.pack('>d', float(text)))[0]
        for delta in (-2, -1, 0, 1, 2):
            add(bits + delta)
    rng = random.Random(1030317)
    for _ in range(8192):
        add(rng.getrandbits(64))
    return list(cases)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    build = ROOT/'.build/zmij-reference'
    (build/'src').mkdir(parents=True, exist_ok=True)
    metadata = json.loads((ROOT/'tests/fixtures/lance-json/sources.json').read_text())
    dependency = next(d for d in metadata['dependencies'] if d['name'] == 'zmij')
    source = next((Path.home()/'.cargo/registry/src').glob('*/zmij-1.0.21'))
    archive = Path.home()/'.cargo/registry/cache'/source.parent.name/'zmij-1.0.21.crate'
    assert sha(archive) == dependency['checksum']
    files = []
    with tarfile.open(archive) as tar:
        for path in sorted(source.rglob('*')):
            if path.is_file() and (path.suffix == '.rs' or path.name in ('LICENSE-MIT', 'Cargo.toml')):
                relative = str(path.relative_to(source))
                assert path.read_bytes() == tar.extractfile('zmij-1.0.21/'+relative).read()
                files.append(dict(path=relative, sha256=sha(path)))
    dependency = dict(dependency, files=files)
    adapter = build/'adapter'
    shutil.copytree(source/'src', adapter/'src', dirs_exist_ok=True)
    shutil.copyfile(source/'build.rs', adapter/'build.rs')
    (adapter/'src/lib.rs').write_bytes((source/'src/lib.rs').read_bytes() + (ROOT/'scripts/zmij_reference_adapter.rs').read_bytes())
    (adapter/'Cargo.toml').write_text('[package]\nname="zmij-adapter"\nversion="0.0.0"\nedition="2021"\n[features]\nno-panic=[]\n')
    (build/'Cargo.toml').write_text('[package]\nname="akasha-zmij-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\nzmij="=1.0.21"\nzmij-adapter={path="adapter"}\n[workspace]\n')
    shutil.copyfile(ROOT/'scripts/zmij_reference.rs', build/'src/main.rs')
    if (OUT/'Cargo.lock').exists():
        shutil.copyfile(OUT/'Cargo.lock', build/'Cargo.lock')
    subprocess.run(['cargo', 'fetch', *(['--locked'] if (OUT/'Cargo.lock').exists() else []), '--manifest-path', str(build/'Cargo.toml')], check=True)
    lock = tomllib.loads((build/'Cargo.lock').read_text())
    assert next(p for p in lock['package'] if p['name'] == 'zmij')['checksum'] == dependency['checksum']
    command = ['cargo', 'run', '--quiet', '--release', '--locked', '--manifest-path', str(build/'Cargo.toml')]
    values = inputs(source)
    output = subprocess.check_output(command, input=('\n'.join(f'{bits:016x}' for bits in values)+'\n').encode()).decode().splitlines()
    assert len(values) == len(output)
    rows = []
    for bits, line in zip(values, output):
        text, sig, exp, slow_sig, slow_exp = line.split('\t')
        rows.append(dict(bits=str(bits), text=text, sig=str(sig), exp=int(exp), slow_sig=str(slow_sig), slow_exp=int(slow_exp)))
    (OUT/'cases.json').write_text(json.dumps(rows, separators=(',', ':'))+'\n')
    # The actual Rust const functions generate the tables. Python only copies
    # their observed entries into Mojo source, without recomputing any powers.
    table_output = subprocess.check_output(command + ['--', '--tables']).decode().splitlines()
    powers, shifts = [], []
    for line in table_output:
        kind, *parts = line.split('\t')
        (powers if kind == 'p' else shifts).extend(parts)
    assert len(powers) == 1234 and len(shifts) == 2048
    lines = ['"""zmij 1.0.21 tables (MIT), emitted by its original Rust const functions."""', '']
    for name, dtype, entries in [('powers_of_ten', 'UInt64', powers), ('exponent_shifts', 'UInt8', shifts)]:
        lines += ['', f'def {name}() -> Array[{dtype}, {len(entries)}]:', f'    var result = Array[{dtype}, {len(entries)}](fill=0)']
        lines += [f'    result[{i}] = {v}' for i, v in enumerate(entries)]
        lines += ['    return result^']
    TABLES.write_text('\n'.join(lines)+'\n')
    shutil.copyfile(build/'Cargo.lock', OUT/'Cargo.lock')
    shutil.copyfile(source/'LICENSE-MIT', ROOT/'docs/upstream/licenses/zmij-MIT.txt')
    counts = Counter('special' if (b >> 52) & 2047 == 2047 else 'zero' if b & ((1 << 63)-1) == 0 else 'subnormal' if (b >> 52) & 2047 == 0 else 'irregular' if b & ((1 << 52)-1) == 0 else 'regular' for b in values)
    metadata = dict(dependencies=[dependency], profile='F64; original public crate cross-checked with unchanged source prefix plus appended test adapter', generator_sha256=sha(__file__), scaffold_sha256=sha(ROOT/'scripts/zmij_reference.rs'), adapter_sha256=sha(ROOT/'scripts/zmij_reference_adapter.rs'), input_fixture_sha256=sha(ROOT/'tests/fixtures/fast-float/cases.json'), fixture_sha256=sha(OUT/'cases.json'), lock_sha256=sha(OUT/'Cargo.lock'), tables_sha256=sha(TABLES), counts=dict(counts))
    (OUT/'sources.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(len(rows), dict(counts))


if __name__ == '__main__':
    main()
