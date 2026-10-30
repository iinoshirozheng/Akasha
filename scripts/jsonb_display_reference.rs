use jsonb::{Number, Decimal64, Decimal128, Decimal256};
use jsonb::jsonpath::parse_json_path;
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
fn main(){
    std::panic::set_hook(Box::new(|_|{}));
    let mut text=String::new();io::stdin().read_to_string(&mut text).unwrap();let input:Value=serde_json::from_str(&text).unwrap();
    let numbers:Vec<_>=input["numbers"].as_array().unwrap().iter().map(|v|{
        let result=std::panic::catch_unwind(||number(v).to_string());
        match result{Ok(s)=>json!({"input":v,"text":s}),Err(_)=>json!({"input":v,"panic":true})}
    }).collect();
    let paths:Vec<_>=input["paths"].as_array().unwrap().iter().map(|v|{
        let raw=bytes(v.as_str().unwrap());
        match std::panic::catch_unwind(||parse_json_path(&raw).map(|p|p.to_string())){
            Ok(Ok(s))=>json!({"hex":v,"text":s}),Ok(Err(_))=>json!({"hex":v,"parse_error":true}),Err(_)=>json!({"hex":v,"panic":true})
        }
    }).collect();
    let divisions:Vec<_>=input["divisions"].as_array().unwrap().iter().map(|v|{
        let a=U256::from_be_bytes(bytes(v[0].as_str().unwrap()).try_into().unwrap());
        let b=u128::from_be_bytes(bytes(v[1].as_str().unwrap()).try_into().unwrap());
        let divisor=U256::from(b);
        json!({"input":v,"quotient":hex(&(a/divisor).to_be_bytes()),"remainder":hex(&(a%divisor).as_u128().to_be_bytes())})
    }).collect();
    println!("{}",json!({"numbers":numbers,"paths":paths,"divisions":divisions}));
}
