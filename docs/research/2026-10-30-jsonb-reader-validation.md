# jsonb text parser source port

D01c3g implements the pinned **jsonb 0.5.6**, databend, non-arbitrary-precision
standard and extended text parsers in Mojo **1.0.0 (ed45d567)**. Native callers
can construct an owned `JsonbValue` with `parse_jsonb` / `parse_jsonb_bytes`;
Python callers use `JsonbValue.from_json`. The result uses existing native
payload storage, Python/HTTP typed transport and NDJSON v3.

Text serialization, complete Arrow JSON extension integration, JSONB querying/
indexing and the full product ledger remain open. No optimization or acceptance
threshold change was made.

## Source and design

The parser follows `src/parser.rs`'s profile dispatch, literals, whitespace,
number selection, quoted/unquoted strings, arrays and duplicate-checking
objects. `src/util.rs` supplies string escape and surrogate handling. Source
hashes and archive checksums are frozen in
[the fixture provenance](../../tests/fixtures/jsonb-text/sources.json);
the existing [Apache-2.0 license](../upstream/licenses/jsonb-Apache-2.0.txt) applies.
The numerical dependency is the independently verified
[fast-float2 F64 port](2026-10-30-fast-float-validation.md).

`src/akasha/document/jsonb_reader.mojo` uses byte offsets in place of Rust slice
borrows and directly builds the existing checked JSONB values instead of a
temporary recursive Rust AST. It reuses the source-backed binary builders for
sorted object keys and duplicate rejection. Unused second-half integer storage
for the disabled arbitrary-precision feature is omitted; the original numeric
precision/scale transitions remain. Checked UInt64/UInt128 accumulation adapts
Rust integer token parsing. Mojo's integer-exponent `pow` supplies the exact
powers of 16 in the source hexadecimal fraction path. Numeric conversions and
source boundaries are covered by bit-exact encoded results.

Python performs exact type checks, UTF-8 encoding and immutable-byte transport.
It does not parse text, select numeric types or implement the binary codec.
`standard` must be an exact bool; accepted text is exact `str` or `bytes`.
Native code also checks types/limits when its binding is called directly.

## Preserved behavior and deliberate bounds

- Extended mode is the default, matching pinned Lance: plus signs/leading
  zeros, hexadecimal integers/fractions, single-quoted strings, unquoted keys,
  case-insensitive literals, NaN/Infinity, empty text as null and omitted array
  members as null. A trailing array comma adds a null member. `-NaN` is rejected.
- Both profiles reject duplicate keys and sort object keys in the binary body.
  Numeric representation follows the source profile and codec, including
  negative floating zero, compact integers and canonical numeric zero/NaN.
- Standard mode uses the source shared whitespace/string helpers. It therefore
  still accepts raw control characters, literal escaped whitespace outside
  strings, four-digit braced Unicode escapes and preserved unpaired surrogate
  escapes. This profile is not interchangeable with the ordinary serde_json
  reader. Unknown escapes, invalid UTF-8 and variable-width braced escapes are
  rejected. `\'` is not a supported escape even inside single quotes.
- Both modes require complete input consumption and retain fast-float exponent
  overflow/underflow behavior.
- Akasha limits source/decoded content to 16 MiB, parsed nodes to 65,536 and
  container depth to 64, in addition to the independent 16 MiB binary-body
  limit. Limits are checked before recursive descent or publication. These
  bounded-resource rules intentionally constrain the upstream unbounded parser.
- Errors use native `Error` and Python `ValidationError`. Source error wording,
  positions and the Rust error enum are not exposed as an Akasha compatibility
  promise. Acceptance/rejection and accepted encoded values are the oracle.

## Actual-source oracle

`pixi run python scripts/jsonb_text_reference.py` compiles the original crate,
calls both `parse_owned_jsonb` profiles and cross-checks each successful body
against `parse_value(...).to_vec()`. It verifies all registered source files
from seven pinned dependencies against their crate archives. No Python/Mojo
result supplies an expected value. There are **20,757 input byte strings**:

| Source profile | Accepted exact bodies | Rejected | Panic |
| --- | ---: | ---: | ---: |
| Standard | 11,074 | 9,683 | 0 |
| Extended | 16,353 | 4,404 | 0 |

Every outcome is checked independently through native Mojo and the public
Python factory. The corpus includes all prior fast-float/Lance inputs, decimal
precision boundaries, all-byte string/key probes, case variants, malformed and
truncated escapes, surrogate combinations, shared whitespace, hexadecimal
128-bit and fractional limits, deterministic nested extended values, and valid
nesting through 64. Separate tests cover the additional native resource bounds.

The fixture also distinguishes `RawJsonb::to_string` from `Value::Display` for
future writer verification. Pinned Lance's `decode_json` calls the former,
which delegates to serde_json; it is not the latter's formatting path. The two
outputs differ for 1,082 standard and 2,939 extended accepted inputs in this
corpus. These text outputs are source evidence, **not a native writer pass**.

## Executed checks

All heavy commands ran serially. The Python module build succeeded.

| Validation | Result |
| --- | --- |
| `test_jsonb_reader.mojo` | 5 passed |
| `test_fast_float.mojo` | 5 passed |
| `test_json_reader.mojo` | 7 passed |
| `test_jsonb.mojo` | 6 passed |
| `test_jsonb_storage.mojo` | 6 passed |
| `test_jsonb_text.py` + `test_jsonb_payload.py` | 61 passed |
| Complete `tests/python` | 3,472 passed, 1 skipped, 3 existing warnings |

Fifteen Python tests are new. Native/Python cases verify owned results, null
distinction, integer and floating boundaries, corrupt/invalid text, input and
encoded-size limits, WAL-only and checkpoint reopen, snapshots, logical export/
import and rejected parsing before a write leaving WAL/sequence unchanged.
Existing serde_json, JSONB codec and storage suites remain green.

Raw logs/statuses are under `.build/jsonb-reader-validation/`, including
`results.json`, `targeted-python.json`, `test_*.log` and `full-python.log`.
The source fixture, metadata and Cargo lock reproduce byte-for-byte
(`reproduce.json`, `reproduce.log`). No durable-format or storage implementation
changed, so the prior crash/C acceptance is retained; Linux x86_64 remains
deferred. Initial test-adapter compile errors were corrected before these runs.

Next: port the actual `RawJsonb`/serde_json text writer and its numeric
formatting dependency, then finish Arrow JSON nullable-slot and metadata
round trips. All remaining product and performance items stay open.
