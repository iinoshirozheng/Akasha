use jsonb::{Value as J, Number as N, OwnedJsonb, RawJsonb, Decimal64, Decimal128,
    Decimal256, Date, Timestamp, TimestampTz, Interval};
use serde_json::{json, Value};
use std::{borrow::Cow, io::{self, Read}};

fn hex(v: &[u8]) -> String { v.iter().map(|b|format!("{b:02x}")).collect() }
fn bytes(v: &str) -> Vec<u8> {
    v.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()
}
fn tree(v: &J<'_>) -> Value {
    match v {
        J::Null=>json!([5]), J::Bool(v)=>json!([4,v]), J::String(v)=>json!([1,v]),
        J::Number(N::Int64(v))=>json!([2,v.to_string()]),
        J::Number(N::UInt64(v))=>json!([8,v.to_string()]),
        J::Number(N::Float64(v))=>json!([3,v.to_bits().to_string()]),
        J::Number(N::Decimal64(v))=>json!([9,hex(&v.value.to_be_bytes()),v.scale]),
        J::Number(N::Decimal128(v))=>json!([9,hex(&v.value.to_be_bytes()),v.scale]),
        J::Number(N::Decimal256(v))=>json!([9,hex(&v.value.to_be_bytes()),v.scale]),
        J::Binary(v)=>json!([10,hex(v)]), J::Date(v)=>json!([11,v.value]),
        J::Timestamp(v)=>json!([12,v.value.to_string()]),
        J::TimestampTz(v)=>json!([13,v.value.to_string(),v.offset]),
        J::Interval(v)=>json!([14,v.months,v.days,v.micros.to_string()]),
        J::Array(v)=>json!([6,v.iter().map(tree).collect::<Vec<_>>()]),
        J::Object(v)=>json!([7,v.iter().map(|(k,v)|json!([k,tree(v)])).collect::<Vec<_>>()]),
    }
}
fn from_tree(v: &Value) -> J<'static> {
    let text=||v[1].as_str().unwrap();
    match v[0].as_u64().unwrap() {
        1=>J::String(Cow::Owned(text().to_string())), 2=>J::Number(N::Int64(text().parse().unwrap())),
        3=>J::Number(N::Float64(f64::from_bits(text().parse().unwrap()))),
        4=>J::Bool(v[1].as_bool().unwrap()), 5=>J::Null,
        6=>J::Array(v[1].as_array().unwrap().iter().map(from_tree).collect()),
        7=>J::Object(v[1].as_array().unwrap().iter().map(|v|(v[0].as_str().unwrap().to_string(),from_tree(&v[1]))).collect()),
        8=>J::Number(N::UInt64(text().parse().unwrap())),
        9=> {let b=bytes(text());let scale=v[2].as_u64().unwrap() as u8;
            J::Number(match b.len() {
                8=>N::Decimal64(Decimal64{value:i64::from_be_bytes(b.try_into().unwrap()),scale}),
                16=>N::Decimal128(Decimal128{value:i128::from_be_bytes(b.try_into().unwrap()),scale}),
                32=>N::Decimal256(Decimal256{value:ethnum::i256::from_be_bytes(b.try_into().unwrap()),scale}),
                _=>unreachable!(),})},
        // Reference-only process owns these small fixture buffers until exit.
        10=>J::Binary(Box::leak(bytes(text()).into_boxed_slice())),
        11=>J::Date(Date{value:v[1].as_i64().unwrap() as i32}),
        12=>J::Timestamp(Timestamp{value:text().parse().unwrap()}),
        13=>J::TimestampTz(TimestampTz{value:text().parse().unwrap(),offset:v[2].as_i64().unwrap() as i32}),
        14=>J::Interval(Interval{months:v[1].as_i64().unwrap() as i32,days:v[2].as_i64().unwrap() as i32,micros:v[3].as_str().unwrap().parse().unwrap()}),
        _=>unreachable!(),
    }
}
fn rebuilt(v: &J<'_>) -> Vec<u8> {
    match v {
        J::Array(v)=> {let owned:Vec<_>=v.iter().map(|v|OwnedJsonb::new(rebuilt(v))).collect();
            OwnedJsonb::build_array(owned.iter().map(|v|v.as_raw())).unwrap().to_vec()},
        J::Object(v)=> {let owned:Vec<_>=v.iter().map(|(k,v)|(k,OwnedJsonb::new(rebuilt(v)))).collect();
            OwnedJsonb::build_object(owned.iter().map(|(k,v)|(k.as_str(),v.as_raw()))).unwrap().to_vec()},
        _=>v.to_vec(),
    }
}
fn main() {
    let mut input=String::new();io::stdin().read_to_string(&mut input).unwrap();
    let input:Value=serde_json::from_str(&input).unwrap();let mut rows=Vec::new();
    for v in input["typed"].as_array().unwrap() {
        let value=from_tree(v);let encoded=value.to_vec();assert_eq!(rebuilt(&value),encoded);
        let decoded=RawJsonb::new(&encoded).to_value().unwrap();
        rows.push(json!({"input":v,"hex":hex(&encoded),"decoded":tree(&decoded)}));
    }
    for v in input["text"].as_array().unwrap() {
        let raw=bytes(v.as_str().unwrap());
        if let Ok(value)=jsonb::parse_value(&raw) {
            let encoded=value.to_vec();assert_eq!(rebuilt(&value),encoded);
            let decoded=RawJsonb::new(&encoded).to_value().unwrap();
            rows.push(json!({"text_hex":v,"input":tree(&value),"hex":hex(&encoded),"decoded":tree(&decoded)}));
        }
    }
    let mut legacy=Vec::new();
    for b in input["legacy"].as_array().unwrap() {
        let raw=bytes(b.as_str().unwrap());let decoded=RawJsonb::new(&raw).to_value().unwrap();
        legacy.push(json!({"hex":b,"decoded":tree(&decoded),"canonical_hex":hex(&decoded.to_vec())}));
    }
    let duplicate=OwnedJsonb::build_object([("a",RawJsonb::new(&[0x20,0,0,0,0,0,0,0])),("a",RawJsonb::new(&[0x20,0,0,0,0,0,0,0]))]).unwrap_err().to_string();
    println!("{}",serde_json::to_string_pretty(&json!({"cases":rows,"legacy":legacy,"duplicate_error":duplicate})).unwrap());
}
