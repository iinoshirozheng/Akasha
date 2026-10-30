// Test-only direct calls to the pinned RawJsonb/serde_json writer.
use jsonb::RawJsonb;
use serde_json::json;
use std::io::{self, Read};

fn bytes(value: &str) -> Vec<u8> {
    value.as_bytes().chunks_exact(2).map(|pair|
        u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap()).collect()
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let inputs: Vec<String> = serde_json::from_str(&input).unwrap();
    let mut rows = Vec::new();
    for hex in inputs {
        let data = bytes(&hex);
        let raw = RawJsonb::new(&data);
        // Codec validity and formatter validity differ for date/offset ranges.
        assert!(raw.to_value().is_ok());
        let output = std::panic::catch_unwind(|| {
            let compact = raw.to_string();
            let pretty = raw.to_pretty_string();
            (compact, pretty)
        });
        let mut row = json!({"hex":hex});
        match output {
            Ok((compact, pretty)) => {
                // Assertions stay outside catch_unwind: a scaffold mismatch
                // must fail generation, never become an expected source panic.
                assert_eq!(compact, serde_json::to_string(&raw).unwrap());
                assert_eq!(pretty, serde_json::to_string_pretty(&raw).unwrap());
                row["compact"] = json!(compact);
                row["pretty"] = json!(pretty);
            },
            Err(_) => { row["panic"] = json!(true); },
        }
        rows.push(row);
    }
    println!("{}", serde_json::to_string(&rows).unwrap());
}
