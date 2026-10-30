use jsonb::{Number, Decimal64, Decimal128, Decimal256};
use ethnum::{I256, U256};
use serde_json::{Value,json};
use std::io::{self,Read};

fn bytes(s:&str)->Vec<u8>{s.as_bytes().chunks_exact(2).map(|b|u8::from_str_radix(std::str::from_utf8(b).unwrap(),16).unwrap()).collect()}
fn hex(b:&[u8])->String{b.iter().map(|v|format!("{v:02x}")).collect()}
fn number(v:&Value)->Number{
    let b=bytes(v[1].as_str().unwrap());let scale=v[2].as_u64().unwrap() as u8;
    match v[0].as_u64().unwrap(){
        0=>Number::Int64(i64::from_be_bytes(b.try_into().unwrap())),
        1=>Number::UInt64(u64::from_be_bytes(b.try_into().unwrap())),
        2=>Number::Float64(f64::from_bits(u64::from_be_bytes(b.try_into().unwrap()))),
        3=>Number::Decimal64(Decimal64{value:i64::from_be_bytes(b.try_into().unwrap()),scale}),
        4=>Number::Decimal128(Decimal128{value:i128::from_be_bytes(b.try_into().unwrap()),scale}),
        5=>Number::Decimal256(Decimal256{value:I256::from_be_bytes(b.try_into().unwrap()),scale}),
        _=>unreachable!()
    }
}
fn attempt<T>(f:impl FnOnce()->Result<T,jsonb::Error>, encode:impl FnOnce(T)->Value)->Value{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)){
        Ok(Ok(v))=>json!({"ok":encode(v)}),Ok(Err(e))=>json!({"error":e.to_string()}),Err(_)=>json!({"panic":true})
    }
}
fn main(){
    std::panic::set_hook(Box::new(|_|{}));
    let mut text=String::new();io::stdin().read_to_string(&mut text).unwrap();let input:Value=serde_json::from_str(&text).unwrap();
    let numbers:Vec<_>=input["numbers"].as_array().unwrap().iter().map(|v|{
        let n=number(v);json!({"input":v,"as_i64":n.as_i64().map(|v|v.to_string()),"as_u64":n.as_u64().map(|v|v.to_string()),"to_i128":n.to_i128().map(|v|v.to_string()),"to_i64":n.to_i64().map(|v|v.to_string()),"to_u64":n.to_u64().map(|v|v.to_string())})
    }).collect();
    let mut bodies:Vec<Vec<u8>>=input["bodies"].as_array().unwrap().iter().map(|v|bytes(v.as_str().unwrap())).collect();
    for text in input["strings"].as_array().unwrap(){bodies.push(jsonb::Value::String(text.as_str().unwrap().into()).to_vec());}
    let mut seen=std::collections::HashSet::new();bodies.retain(|v|seen.insert(v.clone()));
    let casts:Vec<_>=bodies.iter().map(|body|{
        let raw=jsonb::RawJsonb::new(body);
        json!({"hex":hex(body),"casts":[
            attempt(||raw.to_bool(),|v|json!(v)),attempt(||raw.to_i64(),|v|json!(v.to_string())),
            attempt(||raw.to_u64(),|v|json!(v.to_string())),attempt(||raw.to_f64(),|v|json!(v.to_bits().to_string())),
            attempt(||raw.to_str(),|v|json!(v))
        ]})
    }).collect();
    let divisions:Vec<_>=input["divisions"].as_array().unwrap().iter().map(|v|{
        let a=U256::from_be_bytes(bytes(v[0].as_str().unwrap()).try_into().unwrap());let b=U256::from_be_bytes(bytes(v[1].as_str().unwrap()).try_into().unwrap());
        json!({"input":v,"quotient":hex(&(a/b).to_be_bytes()),"remainder":hex(&(a%b).to_be_bytes())})
    }).collect();
    println!("{}",json!({"numbers":numbers,"casts":casts,"divisions":divisions}));
}
