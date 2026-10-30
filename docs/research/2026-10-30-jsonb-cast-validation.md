# D01c4e: source numeric conversion and scalar casts

Base: `027210a`; Mojo `1.0.0 (ed45d567)`. This supplies conversion semantics
required by the [Lance consumer plan](../plans/2026-10-30-lance-json-functions-source-port.md).
The complete 49-package scope remains open; no optimization or weaker gates.

## Sources and implementation

jsonb 0.5.6 `number.rs` supplies exact i64/u64 and rounded i128/i64/u64 conversion,
including half-open float bounds, Decimal exact divisibility, half-away rounding,
scales exceeding representable powers and target overflow. Native `JsonbNumber`
exposes all five methods. Decimal values stay in integer arithmetic.

ethnum 1.5.3 `intrinsics/native/divmod.rs` supplies full unsigned 256-bit division:
the existing single-word branch, normalization, quotient estimate/correction,
full product, borrow/carry correction and remainder denormalization. Shared
division moved from Display into the Number module. This does not claim the
entire signed ethnum division API or replace the source algorithm.

jsonb `functions/scalar.rs` supplies RawJsonb `to_bool`, `to_i64`, `to_u64`,
`to_f64`, `to_str` and integer-string cast dispatch. Rust core's radix-10 checked
accumulation is adapted with a bounded widened accumulator; installed Rust
1.92.0 source and MIT notice were verified against commit
`ded5c06cf21d2b93bffd5d884aa6e96934ee4234`. Existing fast-float2 parsing is reused
and compared directly against the original Rust `str::parse` results.

Native functions are exported from `akasha.document`. Python
`JsonbValue.cast(target)` is a thin validated transport/result boundary for
`bool`, `int64`, `uint64`, `float64`, and `string`. All conversion is Mojo.
See [contracts and examples](../native-jsonb.md#source-scalar-casts).

Exact checks and rounded casts are distinct. Integer casts round ties away from
zero; strings try exact integer parsing first, preserving Int64/UInt64 boundary
values before the floating fallback. No whitespace is stripped. Boolean casts
accept booleans or case-insensitive true/false/yes/no strings, but reject numeric
0/1 and strings "0"/"1". String casts use Number Display and return unquoted
existing text. Null/containers/extensions yield InvalidCast; Lance nullable
consumers must separately check null/missing before invoking these casts.

## Independent evidence

The original Rust harness calls Number methods and each RawJsonb cast separately.
It uses original ethnum division/remainder as a separate arithmetic oracle.
Crate source/archive checks, pinned Rust source and reproducible fixture hashes
are retained; no Akasha or replacement conversion algorithm defines expectations.

| Evidence | Count |
| --- | ---: |
| Typed Number inputs | 96,744 |
| Five exact/rounded Number outcomes | 483,720 |
| Binary JSONB values | 19,975 |
| Five RawJsonb cast outcomes | 99,875 |
| Successful casts | 51,409 |
| Original InvalidCast errors / Display panics | 48,416 / 50 |
| Full unsigned quotient/remainder pairs | 22,188 |
| Pairs with a divisor exceeding 128 bits | 10,433 |

Inputs cover all six Number variants, every scale byte, 71,175 Float64 bit
patterns, target limits and half-rounding neighbors, original/legacy binary
bodies, UTF-8 float-grammar strings and invalid/coercion edge cases. Integer
outputs compare exactly; floats compare IEEE bits, including signed zero and
NaNs. Source Display panics become native errors; no source success is waived.

## Validation

- New native conversion/division suite: **4 passed** on its first run; the final
  run also passes after removing unused-initialization compiler warnings.
- Related Display (5), Number arithmetic (4), selector (5), path (3), writer (4):
  **21 passed**, for **25 related native tests** total.
- `pixi run build-python`: passed.
- Targeted `tests/python/test_jsonb_cast.py`: **17 passed**, including all five
  full source cast corpora, exact result types, invalid target/transport/body,
  source rounding, limits and nonfinite behavior.
- Full `tests/python`: **3,698 passed, 1 skipped** on the rebuilt kernel.
- WAL-only/checkpoint reopen tests query and cast restored values, verify failed
  casts leave fields/sequence/WAL unchanged, and retain owned text after close.
- Generated cases, metadata and Cargo.lock reproduce byte-for-byte. Local
  `.build/jsonb-cast-validation/` preserves commands, logs and result hashes.

The first targeted Python run had one test expectation error: oversized carriers
already raise `ValueError` at construction, before the cast can run. The test now
preserves that existing contract and independently checks the native cast size
guard. All source cast comparisons passed on that first run. The failed log is
retained; production behavior was not altered to satisfy the test.

## Remaining scope

These are usable native/Python conversions and a required Lance dependency.
Actual Lance first-text/multi-match/typed extraction, nullable get/array functions
and Arrow row semantics still need their consumer integration. Exact key/index
access, source type tags, collection filters/projections/indexes, remaining
C/distributed contracts and SQL UDFs are open. Full D01/D03/A03 and all other
product/platform/performance packages remain open. No durable format changed;
native Linux acceptance remains deferred under the user's existing instruction.
