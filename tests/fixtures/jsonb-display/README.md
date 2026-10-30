# Original JSONB Display and ethnum division oracle

Regenerate with `pixi run python scripts/jsonb_display_reference.py`.
The original jsonb 0.5.6 `Number::fmt` and `JsonPath::fmt`, plus ethnum 1.5.3
unsigned division/remainder, execute in locked offline release mode. Crate
archive checksums and source bytes are verified before building the harness.
No Akasha result or replacement formatting algorithm supplies expectations.

| Input/result | Count |
| --- | ---: |
| Typed Number inputs, including all scales and the zmij float corpus | 88,716 |
| Original Number Display successes / panics | 79,658 / 9,058 |
| Complete existing parser corpus | 8,525 |
| Parsed paths with original Display output | 4,238 |
| Parse errors / parser panics | 4,275 / 12 |
| Original U256 / u128 quotient and remainder pairs | 11,692 |

Number cases include powers-of-ten neighbors across decimal widths/scales,
signed limits, all scale bytes, nonfinite values and exact floating bits.
Division cases cover normalization shifts, high-word quotient/remainder,
single-word shortcuts, limits and seeded random inputs. Path text retains the
source's lack of escaping and selective parentheses, not an invented canonical
or round-trip encoding. Source panics are explicit expected native errors.

`cases.json` stores expected text or panics and exact quotient/remainder bytes;
`sources.json` stores verified source/generator/input hashes and counts;
`Cargo.lock` freezes dependencies. This README is maintained documentation.
