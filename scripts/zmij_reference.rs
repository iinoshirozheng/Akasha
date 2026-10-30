// Test-only caller; numerical conversion is the checksum-verified original crate.
use std::io::{self, BufRead};

fn main() {
    if std::env::args().any(|arg| arg == "--tables") {
        for exp in -292..=324 {
            let (hi, lo) = zmij_adapter::akasha_power(exp);
            println!("p\t{hi}\t{lo}");
        }
        for raw_exp in 0..2048 {
            println!("s\t{}", zmij_adapter::akasha_shift(raw_exp));
        }
        return;
    }
    for line in io::stdin().lock().lines() {
        let bits = u64::from_str_radix(&line.unwrap(), 16).unwrap();
        let value = f64::from_bits(bits);
        let text = zmij::Buffer::new().format(value).to_owned();
        assert_eq!(text, zmij_adapter::Buffer::new().format(value));
        if value.is_finite() {
            assert_eq!(text, zmij::Buffer::new().format_finite(value));
            assert_eq!(text.parse::<f64>().unwrap().to_bits(), bits);
        }
        let (fast_sig, fast_exp, slow_sig, slow_exp) = zmij_adapter::akasha_decimal(bits);
        println!("{text}\t{fast_sig}\t{fast_exp}\t{slow_sig}\t{slow_exp}");
    }
}
