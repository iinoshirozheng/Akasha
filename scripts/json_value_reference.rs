use serde_json::{json, Value};
use std::io::{self, Read};

fn tree(value: &Value) -> Value {
    match value {
        Value::Null => json!([5]),
        Value::Bool(v) => json!([4, v]),
        Value::String(v) => json!([1, v]),
        Value::Number(v) => {
            if let Some(n) = v.as_i64() { json!([2, n.to_string()]) }
            else if let Some(n) = v.as_u64() { json!([8, n.to_string()]) }
            else { json!([3, v.as_f64().unwrap().to_bits().to_string()]) }
        }
        Value::Array(v) => json!([6, v.iter().map(tree).collect::<Vec<_>>()]),
        Value::Object(v) => json!([7, v.iter().map(|(k,v)| json!([k,tree(v)])).collect::<Vec<_>>()]),
    }
}

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<String> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = cases.into_iter().map(|hex| {
        let bytes: Vec<u8> = hex.as_bytes().chunks_exact(2).map(|v|
            u8::from_str_radix(std::str::from_utf8(v).unwrap(),16).unwrap()).collect();
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(v) => json!({"hex":hex,"value":tree(&v)}),
            Err(e) => json!({"hex":hex,"error":e.to_string()}),
        }
    }).collect();
    println!("{}", serde_json::to_string_pretty(&results).unwrap());
}
