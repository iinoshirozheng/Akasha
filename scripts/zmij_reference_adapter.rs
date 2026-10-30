
// Appended to an unchanged copy of upstream lib.rs for test-only observation.
// No numerical function or table in that source prefix is modified.
pub fn akasha_power(exp: i32) -> (u64, u64) {
    assert!((-292..=324).contains(&exp));
    let p = unsafe { POW10_SIGNIFICANDS.get_unchecked(exp) };
    let computed = Pow10SignificandsTable::compute((exp + 292) as u32);
    assert_eq!((p.hi, p.lo), (computed.hi, computed.lo));
    (p.hi, p.lo)
}

pub fn akasha_shift(raw_exp: usize) -> u8 {
    EXP_SHIFTS.data[raw_exp]
}

pub fn akasha_decimal(bits: u64) -> (i64, i32, i64, i32) {
    let raw_exp = f64::get_exp(bits);
    let fraction = f64::get_sig(bits);
    if raw_exp == 2047 || (raw_exp == 0 && fraction == 0) {
        return (0, 0, 0, 0);
    }
    let sig = if raw_exp == 0 { fraction } else { fraction | f64::IMPLICIT_BIT };
    let regular = raw_exp == 0 || fraction != 0;
    let slow = to_decimal_schubfach(sig, if raw_exp == 0 { -1074 } else { raw_exp - 1075 }, regular);
    let fast = if raw_exp == 0 {
        to_decimal_schubfach(sig, -1074, true)
    } else {
        to_decimal_fast::<f64, u64>(sig, raw_exp, regular)
    };
    (fast.sig, fast.exp, slow.sig, slow.exp)
}
