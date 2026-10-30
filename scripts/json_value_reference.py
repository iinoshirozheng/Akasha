"""Independent pinned serde_json reader oracle; no Akasha imports."""
from pathlib import Path
import hashlib
import json
import random
import re
import shutil
import subprocess
import tarfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74f3e85b9473c62560006c043e13737ce6b48412"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def cases():
    inputs = []
    def add(value):
        inputs.append(value.encode() if isinstance(value, str) else value)
    seeds = ["null", "true", "false", "0", "-0", "-0.0", "0e0", "1", "-1",
             "9223372036854775807", "9223372036854775808", "18446744073709551615",
             "18446744073709551616", "-9223372036854775808", "-9223372036854775809",
             "0.1", "1.23456789012345678901234567890123456789", "1e309", "-1e-400",
             '""', '"漢字😀"', r'"\u0000\b\f\n\r\t\/\\\""',
             '[]', '{}', '[null,true,-0,"x",[1,2],{}]',
             '{"z":1,"a":[1,null],"z":2,"":{},"nul\\u0000key":false}']
    for value in seeds:
        add(value); add(" \r\n\t"+value+" \r\n\t")
        encoded = value.encode()
        for end in range(len(encoded)): add(encoded[:end])
        for tail in ("x", ",", "]", "}", " null", "\0"): add(value+tail)
    for bad in ('NaN','Infinity','-Infinity','+1','01','-01','1.','1.e2','1e','1e+',
                '.1','--1','[1,]','{"a":1,}','{"a" 1}','{1:2}','[1 2]',
                '"\\x00"','"\\uD800"','"\\uDC00"','"\\uD800\\u0000"',
                '"\\uD800\\n"','"\\u12xz"','/*x*/null','\ufeffnull'):
        add(bad)
    for n in range(256):
        add(b'"'+bytes([n])+b'"'); add(bytes([n])+b'null'); add(b'null'+bytes([n]))
    for raw in (b'\xc0\x80',b'\xed\xa0\x80',b'\xf4\x90\x80\x80',b'\xf5\x80\x80\x80',b'\xe2\x82',b'\x80'):
        add(b'"'+raw+b'"')
    for cp in (0,1,0x1f,0x20,0x7f,0x80,0x7ff,0x800,0xd7ff,0xe000,0xffff):
        add('"\\u%04x"'%cp)
    for hi in (0xd800,0xd801,0xdbfe,0xdbff):
        for lo in (0xdbff,0xdc00,0xdc01,0xdffe,0xdfff,0xe000):
            add('"\\u%04x\\u%04x"'%(hi,lo))
    for digits in ('0','-0','1','-1','18446744073709551615000','0.000000000000000000000000001'):
        for exponent in ('308','309','-308','-309','-324','-325','2147483647','2147483648','-2147483648','-2147483649','9'*80,'-'+'9'*80):
            add(digits+'e'+exponent)
    rng=random.Random(20261030)
    for _ in range(3000):
        value=('-' if rng.randrange(2) else '')+str(rng.randrange(10))
        if not value.endswith('0'):value+=''.join(str(rng.randrange(10)) for _ in range(rng.randrange(70)))
        if rng.randrange(2):value+='.'+''.join(str(rng.randrange(10)) for _ in range(1+rng.randrange(90)))
        if rng.randrange(2):value+='e'+str(rng.randrange(-500,501))
        add(value)
    for seed in (b'[1,true,null]',b'{"x":"\\uD834\\uDD1E","x":2}',b'-12.345e-67'):
        for i in range(len(seed)):
            for replacement in b'\x00\x09\x20"\\/bfnrtu01eE+-.,:[]{}x\x80\xff':
                add(seed[:i]+bytes([replacement])+seed[i+1:])
    return list(dict.fromkeys(v.hex() for v in inputs))


def main():
    reference=ROOT/'reference/qdrant'
    assert subprocess.check_output(['git','-C',str(reference),'rev-parse','HEAD'],text=True).strip()==REVISION
    expected=next(p for p in tomllib.loads((reference/'Cargo.lock').read_text())['package'] if p['name']=='serde_json')
    build=ROOT/'.build/json-value-reference';out=ROOT/'tests/fixtures/json-value'
    (build/'src').mkdir(parents=True,exist_ok=True);out.mkdir(parents=True,exist_ok=True)
    (build/'Cargo.toml').write_text('[package]\nname="akasha-json-value-reference"\nversion="0.1.0"\nedition="2024"\n[dependencies]\nserde_json={version="=1.0.151",features=["preserve_order"]}\n[workspace]\n')
    shutil.copyfile(ROOT/'scripts/json_value_reference.rs',build/'src/main.rs')
    if (out/'Cargo.lock').exists():shutil.copyfile(out/'Cargo.lock',build/'Cargo.lock')
    flags=['--locked'] if (build/'Cargo.lock').exists() else []
    subprocess.run(['cargo','fetch',*flags,'--manifest-path',str(build/'Cargo.toml')],check=True)
    selected=next(p for p in tomllib.loads((build/'Cargo.lock').read_text())['package'] if p['name']=='serde_json')
    assert selected['checksum']==expected['checksum']
    source=next((Path.home()/'.cargo/registry/src').glob('*/serde_json-1.0.151'))
    archive=Path.home()/'.cargo/registry/cache'/source.parent.name/'serde_json-1.0.151.crate'
    assert digest(archive.read_bytes())==expected['checksum']
    files=[]
    with tarfile.open(archive) as tar:
        for p in sorted((source/'src').rglob('*.rs')):
            relative=str(p.relative_to(source));content=p.read_bytes()
            assert content==tar.extractfile('serde_json-1.0.151/'+relative).read()
            files.append(dict(path=relative,sha256=digest(content)))
    inputs=cases()
    result=subprocess.check_output(['cargo','run','--quiet','--locked','--manifest-path',str(build/'Cargo.toml')],input=json.dumps(inputs).encode())
    (out/'cases.json').write_bytes(result);shutil.copyfile(build/'Cargo.lock',out/'Cargo.lock')
    metadata=dict(qdrant_revision=REVISION,name='serde_json',version='1.0.151',checksum=expected['checksum'],features=['std','preserve_order'],float_roundtrip=False,files=files,generator_sha256=digest(Path(__file__).read_bytes()),scaffold_sha256=digest((ROOT/'scripts/json_value_reference.rs').read_bytes()),fixture_sha256=digest(result),lock_sha256=digest((out/'Cargo.lock').read_bytes()))
    (out/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    parsed=json.loads(result);print(len(parsed),'cases;',sum('value' in p for p in parsed),'valid;',sum('error' in p for p in parsed),'rejected')
    # Preserve the source table's exact decimal literals, not a computed pow().
    block=(source/'src/de.rs').read_text().split('static POW10: [f64; 309] = [',1)[1].split('];',1)[0]
    literals=re.findall(r'1e\d{3}',block);assert len(literals)==309
    target=ROOT/'src/akasha/document/json_number_tables.mojo'
    text='"""serde_json 1.0.151 de.rs POW10 (MIT OR Apache-2.0); generated by scripts/json_value_reference.py."""\n\n\ndef json_powers_of_ten() -> Array[Float64, 309]:\n    var result = Array[Float64, 309](fill=0.0)\n'
    for i,literal in enumerate(literals):text+=f'    result[{i}] = {literal}\n'
    target.write_text(text+'    return result^\n')


if __name__=='__main__':main()
