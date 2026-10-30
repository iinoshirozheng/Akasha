# D01c4d: native source Number and JSONPath Display

Base: `b1775b1`; Mojo `1.0.0 (ed45d567)`. Continue the
[complete JSONB query plan](../plans/2026-10-30-jsonb-path-source-port.md).
The full 49-package scope remains open; no performance work or changed gates.

## Source-backed implementation

- jsonb 0.5.6 `src/number.rs`: Number Display and both decimal formatters,
  retaining powers, padding bounds, split/cast behavior and release overflow.
- jsonb `src/jsonpath/path.rs`: JsonPath, Path, Index, ArrayIndex, recursive
  levels, parsed PathValue, operators and Expr Display.
- ethnum 1.5.3 `src/intrinsics/native/divmod.rs`: the normalized two-digit
  `udiv256_by_128_to_128` primitive and `udivmod4` single-word-divisor branch.
  This is the source arithmetic required to split Decimal256 at 10^38.
- Existing source zmij formatting supplies Float64 output. Mojo's primitive
  integer formatting replaces itoa's buffer interface; source text comparisons
  cover signed/unsigned limits and decimal fragments.

`format_jsonb_number_display` and `format_jsonb_path` are exported native APIs.
Number Display retains exact decimal text/scale, independently of RawJsonb's
serde-based JSON rendering. All six native Number variants are covered. The
path formatter covers the complete existing parsed AST, preserving source
spacing, selective parentheses, index-group separators and unescaped text.
It is not a canonical round-trip encoder. Rust-only programmatic Raw/Decimal
literal AST variants outside the existing parser representation are not added.

The selector's AST validation moved to the path module so both consumers share
it. All original conditions and error strings are unchanged. Output and visit
budgets, mutable-AST validation and native QueryControl bound formatting work.
Returned strings own their bytes. See [API contracts](../native-jsonb.md#native-source-display).

## Original-source evidence

The oracle calls actual Number/JsonPath Display and ethnum division/remainder;
no replacement formatter or Akasha result generates expectations. Archives and
source files are verified against pinned checksums before locked offline release
execution. Cases, metadata and Cargo.lock reproduce byte-for-byte.

| Evidence | Count |
| --- | ---: |
| Typed Number inputs | 88,716 |
| Exact Number text results | 79,658 |
| Original Number panics mapped to errors | 9,058 |
| Unique Float64 bit patterns | 71,175 |
| Existing parser inputs | 8,525 |
| Exact parsed-path Display results | 4,238 |
| Parse errors / parser panics | 4,275 / 12 |
| Original unsigned 256/128-bit quotient/remainder results | 11,692 |

Decimal inputs cover every scale byte and powers-of-ten neighbors across widths.
Division cases cover all normalization shifts, both high-word quotient cases,
single-word inputs, signed-boundary bit patterns and seeded random values.

Source quirks are intentionally visible. Decimal128 minimum at scale 1 produces
`--17014118346046923173168730371588410572.8`; Decimal256 minimum negation panics.
Its high quotient is cast to i128, so coefficients beyond the formatter's intended
range can lose or wrap high digits. Scale/padding lookup and arithmetic panics
become explicit native errors. These Display rules do not restrict binary
storage or change the separate JSON writer contract.

## Validation

- `pixi run mojo run -I src tests/mojo/test_jsonb_display.mojo`: **5 passed**.
  Includes all source results, owned output, Unicode byte limits, invalid limits,
  cancellation/deadline/candidate budgets, invalid ASTs and repeated-node work.
- Related selector (5), path (3), Number (4), writer (4): **16 passed**;
  **21 native tests total** for this change.
- `pixi run build-python`: passed after relocating shared AST validation.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python -q`:
  **3,681 passed, 1 skipped**, with three existing dependency/binding warnings.
  No new Python API/test count is claimed; this regression checks the rebuilt
  kernel and existing public query behavior.
- Byte-identical fixture/metadata/lock reproduction; source/license and target
  hashes are recorded in the port registry and local validation result.

The first compile identified the moved validator's error-helper dependency and
explicit UInt128 shift operand requirements. The second caught transferring an
owned String out of a still-live writer; restoring an empty field before return
resolved ownership. The third run passed all source cases. Failed compile logs
remain in `.build/jsonb-display-validation/`; no runtime mismatch was waived.

## Remaining work

Lance Arrow's first-text selection and DataFusion's multi-match array/typed
extraction still need their actual consumer integrations. Follow with collection
JSONB filter/projection/index operations and remaining C/distributed boundaries;
SQL UDF integration requires the real SQL layer. Full Number conversion APIs,
D01/D03/A03 and all remaining product/platform/performance requirements remain
open. Persistence formats and benchmarks are unchanged; native Linux acceptance
remains deferred under the user's existing instruction.
