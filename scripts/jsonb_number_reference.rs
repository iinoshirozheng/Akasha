use jsonb::{Number, Decimal64, Decimal128, Decimal256, Value as JsonbValue};
use ethnum::I256;
use serde_json::{Value, json};
use std::io::{self, Read};

fn bytes(s: &str) -> Vec<u8> {
    s.as_bytes().chunks_exact(2).map(|v|u8::from_str_radix(std::str::from_utf8(v).unwrap(),16).unwrap()).collect()
}
fn hex(b: &[u8]) -> String { b.iter().map(|v|format!("{v:02x}")).collect() }
fn number(v: &Value) -> Number {
    let b=bytes(v[1].as_str().unwrap());let scale=v[2].as_u64().unwrap() as u8;
    match v[0].as_u64().unwrap() {
        0=>Number::Int64(i64::from_be_bytes(b.try_into().unwrap())),
        1=>Number::UInt64(u64::from_be_bytes(b.try_into().unwrap())),
        2=>Number::Float64(f64::from_bits(u64::from_be_bytes(b.try_into().unwrap()))),
        3=>Number::Decimal64(Decimal64{value:i64::from_be_bytes(b.try_into().unwrap()),scale}),
        4=>Number::Decimal128(Decimal128{value:i128::from_be_bytes(b.try_into().unwrap()),scale}),
        5=>Number::Decimal256(Decimal256{value:I256::from_be_bytes(b.try_into().unwrap()),scale}),
        _=>unreachable!()
    }
}
fn encode(v: &Number) -> Value {
    match v {
        Number::Int64(v)=>json!([0,hex(&v.to_be_bytes()),0]),
        Number::UInt64(v)=>json!([1,hex(&v.to_be_bytes()),0]),
        Number::Float64(v)=>json!([2,hex(&v.to_bits().to_be_bytes()),0]),
        Number::Decimal64(v)=>json!([3,hex(&v.value.to_be_bytes()),v.scale]),
        Number::Decimal128(v)=>json!([4,hex(&v.value.to_be_bytes()),v.scale]),
        Number::Decimal256(v)=>json!([5,hex(&v.value.to_be_bytes()),v.scale]),
    }
}
fn result(v: Result<Number,jsonb::Error>) -> Value {match v {Ok(n)=>json!({"number":encode(&n)}),Err(e)=>json!({"error":e.to_string()})}}
fn main() {
    let mut s=String::new();io::stdin().read_to_string(&mut s).unwrap();let input:Value=serde_json::from_str(&s).unwrap();
    let values:Vec<Number>=input["values"].as_array().unwrap().iter().map(number).collect();
    let unary:Vec<_>=values.iter().map(|n|{
        let value=JsonbValue::Number(n.clone());let body=value.to_vec();
        let decoded=jsonb::from_slice(&body).unwrap();
        let JsonbValue::Number(decoded)=decoded else {panic!("number expected")};
        json!({"input":encode(n),"neg":result(n.neg()),"float":n.as_f64().to_bits().to_string(),"hex":hex(&body),"decoded":encode(&decoded)})
    }).collect();
    let pairs:Vec<_>=input["pairs"].as_array().unwrap().iter().map(|p|{
        let a=&values[p[0].as_u64().unwrap() as usize];let b=&values[p[1].as_u64().unwrap() as usize];
        json!({"pair":p,"cmp":a.cmp(b) as i8,"ops":[result(a.add(b.clone())),result(a.sub(b.clone())),result(a.mul(b.clone())),result(a.div(b.clone())),result(a.rem(b.clone()))]})
    }).collect();
    let wide:Vec<_>=input["wide"].as_array().unwrap().iter().map(|p|{
        let a=I256::from_be_bytes(bytes(p[0].as_str().unwrap()).try_into().unwrap());
        let b=I256::from_be_bytes(bytes(p[1].as_str().unwrap()).try_into().unwrap());
        json!({"pair":p,"mul":hex(&a.wrapping_mul(b).to_be_bytes()),"checked":a.checked_mul(b).map(|v|hex(&v.to_be_bytes())),"cmp":a.cmp(&b) as i8})
    }).collect();
    let powers:Vec<_>=(0..=255).map(|e|json!([e,hex(&I256::from(10).pow(e).to_be_bytes()),hex(&10i128.wrapping_pow(e).to_be_bytes())])).collect();
    let bodies:Vec<_>=input["bodies"].as_array().unwrap().iter().filter_map(|h| {
        let body=bytes(h.as_str().unwrap());
        match jsonb::from_slice(&body).unwrap() {
            JsonbValue::Number(n)=>Some(json!({"hex":h,"number":encode(&n),"canonical":hex(&JsonbValue::Number(n).to_vec())})),
            _=>None
        }
    }).collect();
    println!("{}",json!({"unary":unary,"pairs":pairs,"wide":wide,"powers":powers,"bodies":bodies}));
}
