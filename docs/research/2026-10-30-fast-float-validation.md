# fast-float2 F64 source port

D01c3f is the numeric dependency for the pending jsonb text parser. It ports
fast-float2 **0.2.3**'s F64 path into Mojo **1.0.0 (ed45d567)**. The complete
jsonb text parser, text serializer, Arrow JSON integration and product ledger
remain open. No performance tuning or gate change was performed.

## Source and implementation

The crates.io archive checksum is
`f8eb564c5c7423d25c886fb561d1e4ee69f72354d16918afa32c08811f6b6a55`.
[Provenance](../../tests/fixtures/fast-float/sources.json) records 16 source,
test, manifest and license files checked against that archive. The original
[MIT license](../upstream/licenses/fast-float2-MIT.txt) is retained.

`src/akasha/document/fast_float.mojo` ports:

- `number.rs`: decimal prefix grammar, exponent rollback, wrapping accumulation,
  leading zeros, 19-digit truncation, normal/disguised short paths and Inf/NaN.
- `binary.rs`: the Eisel–Lemire product path, original 128-bit powers table,
  subnormal handling, ties-to-even and the ambiguous-result fallback signal.
- `decimal.rs` and `simple.rs`: the 768-digit decimal buffer, truncated-tail
  tracking, decimal shifts, final rounding and long-mantissa conversion.
- `parse.rs`, `lib.rs` and `float.rs`: F64 dispatch, sign bits, complete versus
  partial consumption and the original F64 constants.

Rust slice cursors and eight-digit input batching become checked byte-index
loops. Rust `u128` multiplication uses Mojo `UInt128`; native compilation
confirmed the operation and leading-zero intrinsic on the project compiler.
Fixed arrays replace Rust arrays; original table literals are extracted without
recomputing them. Decimal sign is kept by the outer parsed number because the
source decimal arithmetic does not consume its duplicate sign field. No libc,
Python or Rust conversion runs in the native implementation. F32 is not part of
this jsonb dependency port and is not claimed implemented.

## Oracle and coverage

Run `pixi run python scripts/fast_float_reference.py` to regenerate the fixture
and tables. The adapter uses the pinned public crate and copies its eight
internal modules **without editing them**. It checks public/internal results
bit-for-bit before emitting expectations, including the long-mantissa algorithm
forced on every accepted numeric prefix. Python only constructs input bytes,
extracts tables and packages the results; it does not supply expected floats.

Inputs include the prior Lance/jsonb corpus, upstream test literals, all decimal
exponents from -350 through 317 with boundary mantissas and signs, exact binary
midpoints and their decimal neighbors, 767/768/769/1024/2000-digit tails,
deterministic generated numbers, malformed exponents, case variants and all
256 byte values in selected prefix/suffix positions.

| Source dispatch | Cases |
| --- | ---: |
| Rejected prefix | 2,922 |
| Short numeric path | 1,147 |
| Disguised short numeric path | 36 |
| Binary product path | 10,178 |
| Long-mantissa fallback | 801 |
| Inf/NaN | 107 |
| Total | 15,191 |

All full and partial outcomes match: **11,439 complete tokens accepted**, **12,269
prefixes accepted**, and **12,162 forced long-mantissa comparisons**. Accepted
results compare raw 64-bit representations, including NaN sign and negative
zero. Partial results also compare byte consumption. Tests assert the numeric
branch decisions from the ported primitives against the source categories.
Additional tests cover full-width multiplication, exact ties, underflow,
overflow and the separate serde_json profile.

The shared corpus contains **689 root F64 results** that differ from the pinned
serde_json default profile. For example, `18446744073709551615000e-308` has bits
`332165511190492533` under fast-float2 and `332165511190492534` under serde_json.
This is compatible with the earlier broader 695 differing JSON result trees;
the counts have different scopes. Both native profiles remain independently
tested. The float token parser is not itself JSON syntax validation: it accepts
`+.5`, `1.`, Inf/NaN and overflowing exponents according to its source.

## Executed validation

Serial, exit status 0 for each command:

| Command (`pixi run mojo run -I src`) | Passed |
| --- | ---: |
| `tests/mojo/test_fast_float.mojo` | 5 |
| `tests/mojo/test_json_reader.mojo` | 7 |
| `tests/mojo/test_jsonb.mojo` | 6 |

The existing readers additionally retain their 5,630 serde_json cases and
6,246 current plus 85 legacy JSONB codec cases. Raw output and command statuses
are in `.build/fast-float-validation/{test_*.log,results.json}`. Regenerating the
source fixture, metadata, Cargo lock, license and tables reproduced their
SHA-256 values exactly; local evidence is `reproduce.json` and `reproduce.log`.

This adds a standalone native dependency and tests; existing payload, storage,
bindings and protocol implementations are unchanged. Their previously accepted
checks are retained rather than rerunning the full Python/crash/C suites for
an unconnected numeric dependency. Linux x86_64 remains deferred as instructed.

Next: port the actual jsonb standard/extended grammar and source text serializer,
then expose complete Arrow JSON ingress/export and nullable-slot behavior.
