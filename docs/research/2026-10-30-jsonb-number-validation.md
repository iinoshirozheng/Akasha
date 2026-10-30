# D01c4b: source JSONB Number comparison and arithmetic

Base: `70d102c`; Mojo `1.0.0 (ed45d567)`. Continue step 2 of the
[complete JSONB query plan](../plans/2026-10-30-jsonb-path-source-port.md).
The full 49-package product scope remains open; no performance tuning.

## Sources and implementation

- jsonb 0.5.6 `src/number.rs`: all six variants' `as_f64`, `neg`, `add`, `sub`,
  `mul`, `div`, `rem`, `Ord::cmp` and `adjust_decimal_scales`.
- ethnum 1.5.3 native `umulddi3`/`mul3` and release `I256::pow`.
- Arrow 58.4.0 `bigint::i256::checked_mul`: source signed-magnitude and carry
  checks avoid porting a division implementation solely for overflow detection.
  The original ethnum checked multiply is the independent acceptance oracle.
- ordered-float 5.3.0 total NaN/zero comparison. Existing JSONB decimal/F64
  conversion and binary codec are reused; no replacement conversion algorithm.

The native `JsonbNumber` uses fixed two-word coefficients, preserving variant,
scale and raw F64 bits during expression evaluation. `from_value` accepts all
numeric codec variants, including legacy decimal widths; `to_value` applies
the source's canonical binary representation. This separation retains signed
integer zero until serialization, as required by the original AST/Number.

Mixed integer casts, checked overflow and error strings follow source dispatch.
Decimal comparison retains exact promotion and scale adjustment, including
release-wrapped scale powers, then the actual source Float64 fallback.
Decimal arithmetic remains the source Float64 operation, not invented exact
decimal arithmetic. Decimal64/128 minimum negation wraps; Decimal256 errors.

## Evidence

The original Rust code supplies:

| Oracle | Cases |
| --- | ---: |
| Six typed variants: negation, F64 conversion, encoding/decoding | 8,495 |
| Ordered pairs: comparison and five operations each | 94,213 |
| Arithmetic results across pairs | 471,065 |
| Expected arithmetic errors across pairs | 25,354 |
| Independent i256 checked/wrapping multiply | 2,404 |
| Wrapped i128 and i256 powers, all scale bytes | 256 |
| Original/legacy binary numeric bodies | 4,709 |

All 36 type pairs and all 256 scales for each Decimal width occur. Independent
i256 inputs include exact signed-limit products and neighboring failures;
1,225 checked products succeed. Expected unary errors include 273 Int64 and
256 Decimal256 overflows. Pair errors include 23,254 zero-divisions, 1,091
Int64 overflows and 1,009 UInt64 overflows. Arithmetic NaN sign/payload is not
asserted; all finite results, infinity and signed zero are exact-bit comparisons.
Raw numeric conversion separately verifies literal F64 bit preservation.

`pixi run mojo run -I src tests/mojo/test_jsonb_number.mojo`: four tests pass.
Related `test_jsonb_path.mojo` (3), `test_jsonb.mojo` (6), and
`test_jsonb_writer.mojo` (4) pass: **17 native tests total**.
Source fixture, metadata, Cargo.lock and license reproduction is checked
byte-for-byte. `.build/jsonb-number-validation/` retains command/log/hash evidence.

The first compile caught a test-only String-to-UInt64 constructor mismatch.
The initial runtime comparison then caught Mojo 1.0 floating `%` producing
floor modulo (including infinity for tiny divisors); `std.math.remainder`
instead rounds the quotient to nearest. Neither matches Rust `%`. The code now
uses the native `fmod` primitive, with the complete source corpus passing.
The test's Python None check was also corrected. Failed logs are retained.

## Scope and remaining work

This adds a native dependency and package export. It changes no persisted
format, collection operation, Python binding, C/HTTP API or benchmark parameter.
The Python kernel hash still matches the previous Arrow JSON validation;
its 3,629 passed / 1 skipped result remains applicable and was not rerun.
No new Python or recovery behavior is claimed from the native tests.

Next: complete selector execution in every source output mode, source Number/
AST Display, and public native/Python/collection/filter/projection boundaries.
JSONB indexes, remaining C/distributed boundaries, all other product packages,
M5/M6 and deferred native Linux acceptance remain open. This does not complete
JSONB queries, full Number conversion APIs, D01 or the full product.
