// Reference-only Arrow numeric conversion oracle, independent of Akasha.
use arrow_array::{Array, Float16Array, Float32Array, Float64Array};
use arrow_schema::DataType;
use serde_json::json;

fn main() {
    let mut inputs = vec![0u64, 1, 0x8000000000000000, 0x8000000000000001,
        f64::MAX.to_bits(), (-f64::MAX).to_bits(), f64::MIN_POSITIVE.to_bits()];
    for boundary in [1.0f64, 1.0 + 2.0f64.powi(-11), 1.0 + 2.0f64.powi(-24),
                     65504.0, 65520.0, 2.0f64.powi(-25), 2.0f64.powi(-24),
                     2.0f64.powi(-14), 2.0f64.powi(-150), 2.0f64.powi(-149),
                     f32::MAX as f64, f32::MIN_POSITIVE as f64] {
        for sign in [1.0, -1.0] {
            let bits = (boundary * sign).to_bits();
            inputs.extend([bits - 1, bits, bits + 1]);
        }
    }
    let mut seed = 0xa625097d183e5c21u64;
    for _ in 0..2048 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        if f64::from_bits(seed).is_finite() { inputs.push(seed); }
    }
    inputs.sort_unstable(); inputs.dedup();
    let source = Float64Array::from(inputs.iter().map(|&bits| f64::from_bits(bits)).collect::<Vec<_>>());
    let options = arrow_cast::CastOptions { safe: false, ..Default::default() };
    let half = arrow_cast::cast_with_options(&source, &DataType::Float16, &options).unwrap();
    let single = arrow_cast::cast_with_options(&source, &DataType::Float32, &options).unwrap();
    let half = half.as_any().downcast_ref::<Float16Array>().unwrap();
    let single = single.as_any().downcast_ref::<Float32Array>().unwrap();
    let cases: Vec<_> = inputs.iter().enumerate().map(|(i, bits)| json!({
        "f64_bits": format!("{bits:016x}"), "f16_bits": format!("{:04x}",half.value(i).to_bits()),
        "f32_bits": format!("{:08x}",single.value(i).to_bits()),
        "f16_finite": half.value(i).is_finite(), "f32_finite": single.value(i).is_finite()
    })).collect();
    println!("{}", serde_json::to_string_pretty(&cases).unwrap());
}
