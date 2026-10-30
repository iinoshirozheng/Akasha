// Pinned original jsonb crate is the oracle; no parser/float substitute.
use serde_json::{json, Value};
use std::io::{self, Read};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn parse(bytes: &[u8], standard: bool) -> Value {
    std::panic::catch_unwind(|| {
        let parsed = if standard { jsonb::parse_owned_jsonb_standard_mode(bytes) }
            else { jsonb::parse_owned_jsonb(bytes) };
        match parsed {
            Ok(value) => {
                let tree = if standard { jsonb::parse_value_standard_mode(bytes) }
                    else { jsonb::parse_value(bytes) }.unwrap();
                let encoded = value.to_vec();
                assert_eq!(encoded, tree.to_vec());
                // Lance decode_json calls RawJsonb::to_string, which uses
                // serde_json serialization, not Value's distinct Display.
                json!({"hex": hex(&encoded),
                    "text": jsonb::RawJsonb::new(&encoded).to_string(),
                    "display_text": tree.to_string()})
            },
            Err(error) => json!({"error": error.to_string()}),
        }
    }).unwrap_or_else(|_| json!({"panic": true}))
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let inputs: Vec<String> = serde_json::from_str(&input).unwrap();
    let rows: Vec<_> = inputs.into_iter().map(|input| {
        let bytes: Vec<u8> = input.as_bytes().chunks_exact(2)
            .map(|v| u8::from_str_radix(std::str::from_utf8(v).unwrap(), 16).unwrap()).collect();
        json!({"hex": input, "standard": parse(&bytes, true), "extended": parse(&bytes, false)})
    }).collect();
    println!("{}", serde_json::to_string(&rows).unwrap());
}
