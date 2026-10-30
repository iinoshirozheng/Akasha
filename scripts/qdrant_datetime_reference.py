"""Original Qdrant datetime/scorer oracle and source-derived chrono tables."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
import tarfile

from qdrant_dbsf_reference import extract
import qdrant_formula_payload_reference as payload_reference

ROOT = Path(__file__).resolve().parents[1]
CHRONO_REVISION = "170338250e836976a211e64728ec956e45e78a39"
CHRONO_CHECKSUM = "1aa79e62e7697b8e29b513a68abacf485adcd1fe8284a4316c5ae868e6633327"
RUST_WHITESPACE_SHA256 = "293f2b689c275703ee9716f8a3479e9a9acbc2e712cdf1916cb3d823a1d08926"
RUST_UNICODE_SOURCE_SHA256 = "7bd5d5196f6ae054231e731b3bc99a9b82626c25ccf0fec5fbf3134202fa819b"
RUST_SOURCE_REVISION = "5680fa18feaa87f3ff04063800aec256c3d4b4be"
CHRONO_FILES = ["src/format/parse.rs", "src/format/scan.rs", "src/format/parsed.rs",
    "src/naive/internals.rs", "src/naive/date/mod.rs", "src/naive/time/mod.rs",
    "src/naive/datetime/mod.rs", "src/datetime/mod.rs", "src/offset/fixed.rs",
    "src/offset/mod.rs", "LICENSE.txt"]


def array_source(name, values):
    lines = [f"def {name}() -> Array[Int, {len(values)}]:",
             f"    var result = Array[Int, {len(values)}](fill=0)"]
    lines += [f"    result[{i}] = {value}" for i, value in enumerate(values)]
    return "\n".join(lines + ["    return result^", "", ""])


def source_tables(internals, whitespace, bounds):
    # Decode the literal upstream tables; no calendar algorithm is run in Python.
    constants = {name: int(value) for name, value in re.findall(
        r"const (YEAR_STARTS_AFTER_\w+): u8 = (\d+);", internals)}
    assert "const COMMON_YEAR: u8 = 1 << 3;" in internals
    assert "const LEAP_YEAR: u8 = 0 << 3;" in internals
    constants.update(COMMON_YEAR=8, LEAP_YEAR=0)
    flags = {name: constants[a] | constants[b] for name, a, b in re.findall(
        r"const (\w+): YearFlags = YearFlags\((\w+) \| (\w+)\);", internals)}
    def table(text, name):
        raw = text.split(name, 1)[1].split("=", 1)[1].split("[", 1)[1].split("]", 1)[0]
        return [v.strip() for v in re.sub(r"//[^\n]*", "", raw).split(",") if v.strip()]
    year_flags = [flags[v] for v in table(internals, "const YEAR_TO_FLAGS:")]
    ordinal_adjust = [0 if v == "XX" else int(v) for v in table(internals, "const MDL_TO_OL:")]
    white_map = [int(v) for v in table(whitespace, "static WHITESPACE_MAP:")]
    assert (len(year_flags), len(ordinal_adjust), len(white_map)) == (400, 832, 256)
    code = '"""Generated chrono 0.4.45 calendar / Rust whitespace tables (MIT/Apache-2.0).\n'
    code += 'Regenerate with scripts/qdrant_datetime_reference.py; see THIRD_PARTY_NOTICES.md.\n"""\n'
    code += f"comptime MIN_SECONDS = {bounds['min_seconds']}\ncomptime MAX_SECONDS = {bounds['max_seconds']}\n\n"
    code += array_source("year_flags", year_flags)
    code += array_source("ordinal_adjustments", ordinal_adjust)
    code += array_source("whitespace_map", white_map)
    code += '''def is_whitespace(cp: Int) -> Bool:
    var group = cp >> 8
    if group == 0:
        return whitespace_map()[cp & 255] & 1 != 0
    if group == 22:
        return cp == 0x1680
    if group == 32:
        return whitespace_map()[cp & 255] & 2 != 0
    if group == 48:
        return cp == 0x3000
    return False
'''
    (ROOT / "src/akasha/document/chrono_tables.mojo").write_text(code)


def main():
    payload_reference.main()
    base = ROOT / ".build/qdrant-formula-payload-reference/src/main.rs"
    build = ROOT / ".build/qdrant-datetime-reference"
    target = ROOT / "tests/fixtures/qdrant-datetime"
    (build / "src").mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    prior = json.loads((ROOT / "tests/fixtures/qdrant-formula-payload/formula.json").read_text())
    sources, units = prior["sources"].copy(), prior["units"].copy()
    def source(path):
        text = subprocess.check_output(["rtk", "proxy", "git", "-C", str(ROOT / "reference/qdrant"),
            "show", f"{payload_reference.REVISION}:{path}"], text=True)
        sources[path] = hashlib.sha256(text.encode()).hexdigest()
        return text
    def unit(text, signature):
        body = extract(text, signature)
        units[signature] = hashlib.sha256(body.encode()).hexdigest()
        return body
    types = source("lib/segment/src/types.rs")
    for path in ("Cargo.lock", "lib/shard/src/query/formula.rs", "lib/api/src/rest/schema.rs"):
        source(path)
    cache = Path.home() / ".cargo/registry"
    crate = next(cache.glob("cache/*/chrono-0.4.45.crate"))
    assert hashlib.sha256(crate.read_bytes()).hexdigest() == CHRONO_CHECKSUM
    chrono = next(cache.glob("src/*/chrono-0.4.45"))
    chrono_sources = {}
    with tarfile.open(crate) as archive:
        assert json.load(archive.extractfile("chrono-0.4.45/.cargo_vcs_info.json"))["git"]["sha1"] == CHRONO_REVISION
        for path in CHRONO_FILES:
            data = archive.extractfile("chrono-0.4.45/" + path).read()
            assert (chrono / path).read_bytes() == data
            chrono_sources[path] = hashlib.sha256(data).hexdigest()
    license_path = ROOT / "docs/upstream/licenses/chrono-LICENSE.txt"
    license_path.write_bytes((chrono / "LICENSE.txt").read_bytes())
    rust_source = next((Path.home() / ".rustup/toolchains").glob(
        "*/lib/rustlib/src/rust/library/core/src/unicode/unicode_data.rs"))
    rust_text = rust_source.read_text()
    assert hashlib.sha256(rust_text.encode()).hexdigest() == RUST_UNICODE_SOURCE_SHA256
    whitespace = extract(rust_text, "pub mod white_space {")
    assert hashlib.sha256(whitespace.encode()).hexdigest() == RUST_WHITESPACE_SHA256
    rust_version = subprocess.check_output(["rtk", "proxy", "rustc", "--version"], text=True).strip()
    source_toolchain = next(p for p in rust_source.parents if (p / "bin/rustc").exists())
    source_version = subprocess.check_output(["rtk", "proxy", str(source_toolchain / "bin/rustc"), "--version"], text=True).strip()

    code = base.read_text()
    start = code.index("#[derive(Clone,Copy,Debug)] struct DateTimePayloadType;")
    end = code.index("struct Haversine;", start)
    wrapper = "#[derive(Clone,Copy,Debug)] pub struct DateTimeWrapper(pub chrono::DateTime<chrono::Utc>);\n"
    wrapper += "type DateTimePayloadType = DateTimeWrapper;\nuse std::borrow::Cow;\nuse serde::{Deserialize,Deserializer};\n"
    for signature in ("impl DateTimeWrapper {", "impl<'de> Deserialize<'de> for DateTimePayloadType {",
                      "impl FromStr for DateTimePayloadType {", "impl From<chrono::DateTime<chrono::Utc>> for DateTimePayloadType {"):
        wrapper += unit(types, signature) + "\n"
    code = code[:start] + wrapper + code[end:]
    code = code.replace("match kind.as_str() {", '''match kind.as_str() {
        "datetime"=>ParsedExpression::Datetime(DatetimeExpression::Constant(arg.as_str().unwrap().parse().unwrap())),
        "datetime_key"=>{
            let key:JsonPath=arg.as_str().unwrap().parse().unwrap();
            vars.push(key.clone());
            ParsedExpression::Datetime(DatetimeExpression::PayloadVariable(key))
        },
        "exp_decay"=>ParsedExpression::Decay{kind:DecayKind::Exp,x:Box::new(expression(&arg["x"],vars)),
            target:arg.get("target").map(|v|Box::new(expression(v,vars))),
            lambda:OrderedFloat(0.5f64.ln()/arg["scale"].as_f64().unwrap())},''')
    code = code.replace("fn main() {", "fn formula_main(input:&Value)->Vec<Value> {")
    read_input = '    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();\n'
    assert read_input in code
    code = code.replace(read_input, "").replace('    println!("{}",json!(output));', "    output")
    code += whitespace + '\n'
    code += r'''
fn main() {
    for cp in (0..=0x10ffff).filter_map(char::from_u32) {
        assert_eq!(white_space::lookup(cp), cp.is_whitespace());
    }
    let input:Value=serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
    let dates:Vec<_>=input["dates"].as_array().unwrap().iter().map(|v| {
        match serde_json::from_value::<DateTimePayloadType>(v.clone()) {
            Ok(dt)=>json!({"input":v,"micros":dt.timestamp(),"seconds":dt.0.timestamp(),"nanos":dt.0.timestamp_subsec_nanos()}),
            Err(e)=>json!({"input":v,"error":e.to_string()})
        }
    }).collect();
    let lo=chrono::DateTime::<chrono::Utc>::MIN_UTC.timestamp()*1_000_000;
    let hi=chrono::DateTime::<chrono::Utc>::MAX_UTC.timestamp()*1_000_000+999_999;
    let timestamps:Vec<_>=input["timestamps"].as_array().unwrap().iter().map(|v|v.as_i64().unwrap())
        .chain([lo-1,lo,lo+1,hi-1,hi,hi+1]).map(|ts| {
        match DateTimeWrapper::from_timestamp(ts) {
            Some(dt)=>json!({"input":ts,"micros":dt.timestamp(),"seconds":dt.0.timestamp(),"nanos":dt.0.timestamp_subsec_nanos()}),
            None=>json!({"input":ts,"error":"out of range"})
        }
    }).collect();
    let bounds=json!({"min_seconds":chrono::DateTime::<chrono::Utc>::MIN_UTC.timestamp(),
                      "max_seconds":chrono::DateTime::<chrono::Utc>::MAX_UTC.timestamp()});
    println!("{}",json!({"dates":dates,"timestamps":timestamps,"bounds":bounds,"formulas":formula_main(&input["formulas"])}));
}
'''
    (build / "src/main.rs").write_text(code)
    (build / "src/parse.rs").write_bytes((base.parent / "parse.rs").read_bytes())
    (build / "Cargo.toml").write_text('[package]\nname="akasha-datetime-reference"\nversion="0.1.0"\nedition="2024"\n'
        '[dependencies]\nnom="=8.0.0"\nserde={version="=1.0.228",features=["derive"]}\n'
        'serde_json={version="=1.0.151",features=["preserve_order"]}\n'
        'chrono={version="=0.4.45",default-features=false,features=["std"]}\n[workspace]\n')
    dates = [None, False, 0, 1.25, [], {}, "", "1970-01-01", "1969-12-31T23:59:59.999999999Z"]
    def year_text(y):
        return f"{y:04}" if 0 <= y <= 9999 else ("-" if y < 0 else "+") + f"{abs(y):04}"
    for y in list(range(-200, 201)) + [-262144, -262143, 1582, 1600, 1700, 1900, 2000, 2100, 2400, 9999, 10000, 262142, 262143]:
        for month in [0, 1, 2, 4, 12, 13]:
            for day in [0, 1, 28, 29, 30, 31, 32]:
                dates.append(f"{year_text(y)}-{month:02}-{day:02}")
    for day in ["2024-02-29", "2023-02-29", "0000-01-01", "-0001-01-01", "+262142-12-31", "-262143-01-01", "1-2-3", "2024- 2-29", "2024 -2-29"]:
        for sep in ["T", "t", " ", "", "\t", " T"]:
            for time in ["12:34", "1:2:3", "23:59:60.123456789123", "24:00:00", "12:34:56.0000009"]:
                for zone in ["", "Z", "z", "UTC", "+08", "-0800", "+08:30", "−00:30", "+24:00", "+00:60"]:
                    dates.append(day + sep + time + zone)
    white = [chr(cp) for cp in [9,10,11,12,13,32,0x85,0xa0,0x1680,*range(0x2000,0x200b),0x2028,0x2029,0x202f,0x205f,0x3000,0x200b,0xfeff]]
    for space in white:
        for template in ["{}2024-01-01", "2024{}-01-01T01:02:03Z", "2024-01-01T01{}:02:03Z", "2024-01-01T01:02:03{}UTC", "2024-01-01T01:02:03+01{}30", "2024-01-01T01:02:03Z{}", "2024-01-01{}01:02"]:
            dates.append(template.format(space))
    for tail in [".", ".0", ".123456", ".123456789", ".123456789999999999", ",5", ".１２", ".0000000001"]:
        for sec in [0, 58, 59, 60, 61]:
            dates.append(f"1969-12-31T23:59:{sec:02}{tail}Z")
    for year in ["+"+"0"*100+"2024", "-"+"9"*100, "20240", "+2147483647", "-2147483648"]:
        dates.append(year+"-01-01T00:00:00Z")
    for date in ["-262143-01-01", "+262142-12-31"]:
        for time in ["00:00:00", "23:59:59.999999999", "23:59:60.999999999"]:
            for zone in ["Z", "+00:01", "-00:01", "+23:59", "-23:59"]:
                dates.append(date+"T"+time+zone)
    rng = random.Random(20261030)
    for _ in range(500):
        y=rng.randint(-262145,262144)
        dates.append(f"{year_text(y)}-{rng.randint(0,13):02}-{rng.randint(0,32):02}T{rng.randint(0,24):02}:{rng.randint(0,60):02}:{rng.randint(0,61):02}.{rng.randrange(10**12):012}+{rng.randint(0,24):02}:{rng.randint(0,60):02}")
    timestamps = [-(1<<63),(1<<63)-1,-1,0,1,-1000001,-1000000,999999,1000000]
    timestamps += [rng.randint(-(1<<63),(1<<63)-1) for _ in range(300)]
    formulas = []
    # Keep calendar coverage in the type oracle, and exercise every grammar value
    # plus representative extreme dates through the actual formula evaluator.
    for value in dates[:9] + dates[-3500:]:
        formulas.append(dict(expression={"datetime_key":"time"},payload={"time":value},defaults={}))
    values = [None,False,0,"2025-03-18",["2025-03-18"],["2025-03-18","2025-03-19"],[],{},"invalid",[["2025-03-18"]]]
    for value in values:
        for path,payload in [("time",{"time":value}),("meta[].time",{"meta":[{"time":value}]}),("time[]",{"time":value})]:
            for defaults in [{},{path:"2025-03-19"}]:
                formulas.append(dict(expression={"datetime_key":path},payload=payload,defaults=defaults))
        formulas.append(dict(expression={"datetime_key":"time"},payload={},defaults={"time":value}))
    for constant in ["1970-01-01","1969-12-31T23:59:59.999999Z","2025-03-18","-262143-01-01","+262142-12-31T23:59:60.9Z"]:
        formulas.append(dict(expression={"datetime":constant},payload={},defaults={}))
    for expr in [{"mult":[0,{"datetime_key":"time"}]},{"mult":[{"datetime_key":"time"},0]},
                 {"div":{"left":0,"right":{"datetime_key":"time"}}},
                 {"exp_decay":{"x":{"datetime_key":"time"},"target":{"datetime":"2025-03-19"},"scale":86400}}]:
        for value in values:
            formulas.append(dict(expression=expr,payload={"time":value},defaults={}))
    (build / "input.json").write_text(json.dumps(dict(dates=dates,timestamps=timestamps,formulas=formulas)))
    lock = target / "Cargo.lock"
    if lock.exists():
        (build / "Cargo.lock").write_bytes(lock.read_bytes())
    else:
        subprocess.run(["rtk","proxy","cargo","generate-lockfile","--offline","--manifest-path",str(build/"Cargo.toml")],check=True)
    subprocess.run(["rtk","proxy","cargo","build","--offline","--locked","--release","--manifest-path",str(build/"Cargo.toml")],check=True)
    lock.write_bytes((build / "Cargo.lock").read_bytes())
    output = json.loads(subprocess.check_output([str(build/"target/release/akasha-datetime-reference"),str(build/"input.json")],text=True))
    source_tables((chrono/"src/naive/internals.rs").read_text(),whitespace,output["bounds"])
    metadata = dict(revision=payload_reference.REVISION,sources=sources,units=units,
        chrono=dict(version="0.4.45",revision=CHRONO_REVISION,crate_sha256=CHRONO_CHECKSUM,sources=chrono_sources),
        rust=dict(compiler_version=rust_version,source_version=source_version,source_revision=RUST_SOURCE_REVISION,unicode_source_sha256=hashlib.sha256(rust_text.encode()).hexdigest(),whitespace_unit_sha256=hashlib.sha256(whitespace.encode()).hexdigest(),all_scalar_values_verified=True),
        scaffold_sha256=hashlib.sha256(code.encode()).hexdigest(),cargo_lock_sha256=hashlib.sha256(lock.read_bytes()).hexdigest(),bounds=output.pop("bounds"))
    text = json.dumps(metadata,indent=2)[:-2]
    for key,rows in output.items():
        text += ',\n  '+json.dumps(key)+': [\n'+',\n'.join('    '+json.dumps(row,separators=(',',':')) for row in rows)+'\n  ]'
    (target/"datetime.json").write_text(text+'\n}\n')
    print({key:len(rows) for key,rows in output.items()},"original datetime cases")


if __name__ == "__main__":
    main()
