# zmij F64 source oracle

Regenerate with `pixi run python scripts/zmij_reference.py` from the repository
root. Rust is used only for this test oracle, never by the Mojo formatter.

`sources.json` pins the zmij 1.0.21 archive, verifies its source/test/license
files against that archive, and hashes the generator, adapters, input fixture,
output fixture, Cargo lock and generated Mojo tables. `Cargo.lock` fixes the
original crate. A second test-only crate copies the complete original `src/`
and `build.rs`; its `lib.rs` retains the upstream bytes unchanged as a prefix,
followed by `scripts/zmij_reference_adapter.rs`. The appended functions expose
the original internal conversion results and tables. Both copies' public
outputs are compared before a row is emitted.

`cases.json` contains 70,662 raw F64 bit patterns as decimal strings. `text` is
the original `Buffer::format` result. `sig`/`exp` are the original fast-path
entry's intermediate decimal (including its normal fallback); `slow_sig` and
`slow_exp` force the original Schubfach routine. For subnormals both use the
source subnormal branch before normalization. These fields are zero sentinels
for signed zero, infinity and NaN. They are not floats reconstructed by Python.

Inputs cover every IEEE exponent with significand boundary neighbors, both
signs, the first 1,024 subnormal significands, prior fast-float source results,
upstream `dtoa` regression literals, decimal powers with adjacent bit patterns,
and 8,192 deterministic random bit patterns plus their opposite signs. This is
finite differential coverage, not an exhaustive test of all 2^64 inputs.

`zmij_tables.mojo` is emitted from the original Rust power/shift tables. Each
power-table lookup is also checked against its original const computation.
Python does not recompute those tables. Native tests compare both conversion
paths and exact text, then round-trip each finite output through the separately
ported fast-float2 parser. Native nonfinite `format_zmij_finite` calls raise
instead of exposing upstream's unspecified result; `format_zmij` preserves the
source `NaN`, `inf`, `-inf` behavior.

Full JSONB/serde_json serialization is a separate pending integration: its
nonfinite floats serialize as JSON null, not these standalone formatter tokens.
