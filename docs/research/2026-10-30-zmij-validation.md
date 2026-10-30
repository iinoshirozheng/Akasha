# zmij F64 formatting source port

D01c3h ports the F64 numeric-formatting dependency used by Lance's JSONB text
output. It uses zmij **1.0.21** and Mojo **1.0.0 (ed45d567)**. The enclosing
RawJsonb/serde_json serializer, Arrow JSON integration and complete product
ledger remain in progress. No performance tuning or gate changes were made.

## Source path and implementation

The actual Lance path is `lance-arrow/src/json.rs::decode_json` →
`jsonb::RawJsonb::to_string` → its serde serialization →
`serde_json::Formatter::write_f64` → `zmij::Buffer::format_finite`. This differs
from `jsonb::Value::Display`. The prior text fixture preserves both outputs;
the writer must use the RawJsonb path. serde_json maps nonfinite floating values
to JSON null before calling its finite formatter.

The zmij archive checksum is
`b8848ee67ecc8aedbaf3e4122217aff892639231befc6a1b58d29fff4c2cabaa`.
[Provenance](../../tests/fixtures/zmij/sources.json) verifies 12 source, test,
manifest and license files against the archive. The original
[MIT license](../upstream/licenses/zmij-MIT.txt) is retained.

`src/akasha/document/zmij.mojo` ports the source's F64 constants and these
`lib.rs` paths:

- UInt128 products, 192-bit high products and inexact rounding to odd;
- decimal exponent and exponent-shift calculations;
- yy fast conversion with both original boundary checks and Schubfach fallback;
- irregular and subnormal conversions, shorter candidates and ties-to-even;
- the source portable BCD significand writer and trailing-zero removal;
- fixed notation for decimal exponents -5 through 15, scientific notation
  otherwise, explicit scientific signs and no exponent-leading zeros;
- signed zero, NaN and signed infinities.

Rust `u128` becomes Mojo `UInt128`. Bounded array offsets replace pointers;
overlapping copies retain memmove direction. The source portable exponent
arithmetic and BCD writer are used on all targets, without its architecture
assembly/SIMD specializations. Byte packing is explicit to avoid host-endian
dependence. These are source branches, not a replacement conversion algorithm.
There is no Python, Rust or libc numeric formatter in the runtime path.

The 617 two-word powers and 2,048 exponent shifts are emitted by the original
Rust const functions. Every emitted power lookup is checked against the same
original const computation, including the platform-specific table layout.
Python packages the output without recalculating powers. F32 is not part of
this F64 JSONB dependency and is not claimed implemented.

`format_zmij` preserves source special tokens. `format_zmij_finite` rejects
nonfinite arguments, whose upstream output is unspecified. Neither standalone
function is advertised as a complete JSON serializer.

## Differential evidence

Run `pixi run python scripts/zmij_reference.py`. The pinned public crate is
cross-checked with an unchanged copy of all original source modules; only a
test adapter is appended to expose original internals. The fixture contains
70,662 distinct bit patterns:

| Input class | Cases |
| --- | ---: |
| Signed zero | 2 |
| Subnormal | 2,328 |
| Normal with zero explicit significand (irregular) | 4,092 |
| Other normal | 64,220 |
| NaN/infinity | 20 |

All 2,048 IEEE exponent fields occur with boundary significands and both signs.
The corpus adds low subnormals, prior parsing results, upstream `dtoa` regression
literals, decimal powers and their adjacent bit patterns, and deterministic
random inputs. This is not an exhaustive enumeration of all bit patterns.

For **70,640 finite nonzero inputs**, both the native fast entry and a separately
forced Schubfach conversion match original intermediate significands/exponents.
All **70,662 text outputs** match byte-for-byte. All **70,642 finite outputs**
round-trip through the independent native fast-float2 parser to the original
bits, including negative zero. The original Rust oracle also checks Rust's
parser round-trip. Focused checks cover notation cutoffs, one/two/three-digit
exponents, source tie/boundary regressions, packed digit groups, table shifts
and full-width multiplication carries.

## Executed validation and limits

`pixi run mojo run -I src tests/mojo/test_zmij.mojo` compiled and passed **4/4**
tests, exit status 0. Compiler output from the first test-only list-typing error
was corrected before this successful run; no production algorithm mismatch
occurred. The first oracle attempts exposed environment/scaffold errors
(system Python lacks `tomllib`, bit-neighbors of zero needed bounds, and the
upstream license is named `LICENSE-MIT`), all corrected before generating the
accepted fixture.

`.build/zmij-validation/` retains the captured successful native test output,
terminal status, hashes, and reproduction log/results. Reproduction checks
the fixture, metadata, Cargo lock, license and generated tables byte-for-byte.

This is a new standalone native dependency. Existing readers, payload/storage
formats, Python bindings and protocol code are unchanged. Their existing
accepted validation is retained; full Python/crash/C suites were not rerun for
this unconnected dependency. Native Linux remains deferred, not passed.

Next: complete the RawJsonb/serde_json writer, including decimal and extension
formatting, then its public/Arrow JSON paths. D01, other product capabilities,
M5/M6 and all remaining acceptance gates retain their original scope.
