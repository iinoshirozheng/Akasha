# Original JSONB scalar conversion and division oracle

Regenerate with `pixi run python scripts/jsonb_cast_reference.py` using the
pinned Rust 1.92.0 compiler/source and locked offline jsonb 0.5.6 databend
release profile. The harness calls original Number methods, RawJsonb casts and
ethnum 1.5.3 U256 division/remainder. Expected results are not computed by Akasha.

| Evidence | Count |
| --- | ---: |
| Typed Number inputs, five exact/rounded methods each | 96,744 |
| Binary JSONB values, five scalar casts each | 19,975 |
| Expected cast errors / mapped source panics | 48,416 / 50 |
| Full unsigned 256-bit division pairs | 22,188 |

Number cases retain every scale byte, floating bits and powers-of-ten neighbors
from the Display corpus, plus signed/unsigned target limits and half-rounding
neighbors across decimal widths. Raw cases include every original/legacy codec
body and valid UTF-8 strings from the float grammar corpus, boolean variants,
integer limits, whitespace, nonfinite values and malformed numeric strings.

Integer results are decimal strings; floating results are exact UInt64 bit
strings. Each cast outcome is independently `ok`, `error` or `panic`. Division
outputs are exact 32-byte quotient/remainder values. Zero divisors are tested
as native errors instead of crashing the reference process.

`sources.json` records archive/source/generator/input hashes, counts and pinned
Rust core integer-parser provenance. Rust's installed source and MIT notice
were checked against its fixed upstream commit. `Cargo.lock` freezes crate
dependencies. This README is maintained documentation.
