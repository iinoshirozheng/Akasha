// Test-only adapter. The source modules below are copied byte-for-byte from
// the checksum-verified fast-float2 0.2.3 crate by fast_float_reference.py.
#![allow(dead_code)]
mod binary;
mod common;
mod decimal;
mod float;
mod number;
mod parse;
mod simple;
mod table;
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines() {
        let hex = line.unwrap();
        let bytes: Vec<u8> = hex.as_bytes().chunks_exact(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect();
        let partial = fast_float2::parse_partial::<f64, _>(&bytes).ok();
        let full = fast_float2::parse::<f64, _>(&bytes).ok();
        let internal = parse::parse_float::<f64>(&bytes);
        assert_eq!(partial.map(|(f, n)| (f.to_bits(), n)), internal.map(|(f, n)| (f.to_bits(), n)));
        let mut path = "invalid";
        let mut forced = String::from("-");
        if let Some((num, _)) = number::parse_number(&bytes) {
            path = if num.try_fast_path::<f64>().is_some() {
                if num.exponent > 22 { "disguised" } else { "fast" }
            } else {
                let am = binary::compute_float::<f64>(num.exponent, num.mantissa);
                if am.power2 < 0 || (num.many_digits && am != binary::compute_float::<f64>(num.exponent, num.mantissa + 1)) {
                    "long"
                } else { "binary" }
            };
            // Exercise the unchanged long-decimal source even for inputs for
            // which its dispatcher chooses a short path.
            let am = simple::parse_long_mantissa::<f64>(&bytes);
            let mut bits = am.mantissa | ((am.power2 as u64) << 52);
            if num.negative { bits |= 1 << 63; }
            forced = bits.to_string();
            assert_eq!(Some(bits), partial.map(|(f, _)| f.to_bits()));
        } else if partial.is_some() { path = "special"; }
        let f = full.map(|v| v.to_bits().to_string()).unwrap_or_else(|| "-".into());
        let (p, n) = partial.map(|(v, n)| (v.to_bits().to_string(), n)).unwrap_or_else(|| ("-".into(), 0));
        println!("{f}\t{p}\t{n}\t{path}\t{forced}");
    }
}
