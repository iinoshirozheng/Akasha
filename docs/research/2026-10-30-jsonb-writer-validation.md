# Native JSONB text output

D01c3i implements compact and pretty text output through native `format_jsonb`
and Python `JsonbValue.to_json`. It ports the pinned Lance-reachable
`RawJsonb`/serde path, including every currently supported JSONB scalar,
extension and container. Complete Arrow JSON integration, JSONB queries/indexes,
other product capabilities and the existing performance gates remain open.
No optimization or gate changes were performed.

## Source and public behavior

The call path is Lance `decode_json` → jsonb 0.5.6 `RawJsonb::to_string` →
`RawJsonb::serialize` → serde_json 1.0.151's compact formatter. Pretty output
uses the source `RawJsonb::to_pretty_string`/two-space `PrettyFormatter`.
`Value::Display` is a different source path and is not used as the JSON oracle.

`jsonb_writer.mojo` ports the direct databend body walk, punctuation, string
escaping and indentation. Objects retain raw key order; no AST reconstruction
or sort occurs. UTF-8 bytes outside the source ASCII escape set are retained.
Empty containers stay on one line and output has no trailing newline.

`jsonb_formatting.mojo` ports:

- `Number::serialize` without `arbitrary_precision`: signed/unsigned integer
  output, F64 serialization and Decimal64/128/256 conversion. Decimal256 uses
  ethnum 1.5.3's two UInt128 casts, high-word scaling/addition and signed
  magnitude; all decimals divide by the source integer power of ten.
- serde_json's nonfinite-to-null rule, before the previously verified zmij
  F64 formatter. Noncanonical raw Float64 NaN/infinity bodies follow the same
  rule as the codec's dedicated nonfinite tags.
- `ExtensionValue::Display`: uppercase binary hex, dates, timestamps,
  timezone timestamps and intervals, including old timezone/decimal bodies.
- jiff 0.2.28's Neri–Schneider epoch-day conversion and positive-domain timestamp
  conversion, source ranges, date Display and the exact timestamp strtime
  year/fraction/offset formatting used by jsonb. No general timezone/calendar
  API or complete jiff port is claimed.

Mojo standard integer formatting replaces Rust's standard integer formatter;
the source padding rules are explicit. Rust signed division is adapted to
truncate toward zero, and signed-minimum wrapping is retained. In particular,
the pinned release interval formatter has unusual minus signs at signed
minima; its successful outputs are preserved rather than normalized.
Timestamp fractions/clamps, BCE year formats and offsets containing seconds
also follow the original output exactly.

Native `format_jsonb(value, *, pretty=False)` takes an owned checked value.
The Python binding validates exact immutable bytes/exact bool, body size and
the complete codec before formatting; Python does not stringify or format any
values. Invalid date/calendar or timezone offset values raise native `Error`
or Python `ValidationError` in place of the upstream unwrap panic. Malformed
binary is rejected, not passed through upstream's unchecked raw-text fallback.

This output is a projection: nonfinite values become null, decimals can lose
precision, and extensions become strings. Binary `.data` / `to_bytes()` and
typed transport remain the lossless interfaces. Formatting leaves source
bytes unchanged. Input byte/node/depth bounds bound output growth; JSON
escaping/indentation can exceed the separate 16 MiB body/text-input limit and
is not incorrectly rejected at that output size.

## Original-source oracle

`pixi run python scripts/jsonb_writer_reference.py` verifies all seven pinned
crate archives and 231 original Rust source files. Newly used ethnum/jiff MIT
licenses are verified against their archives and retained under
`docs/upstream/licenses/`. The [metadata](../../tests/fixtures/jsonb-writer/sources.json)
records their hashes alongside the adapter, generator, input fixtures, output
and Cargo lock. The existing jsonb/serde_json/zmij source and license identities
remain pinned. Rust runs only for this oracle, not in the native runtime.

The adapter directly calls original RawJsonb compact/pretty methods. Successful
results must also match direct serde serialization; these assertions are outside
the panic catcher so a scaffold failure cannot become an expected source panic.
The fixture/provenance/lock/licenses reproduce byte-for-byte.

The **29,003 unique source bodies** include existing typed/current/legacy codec
cases and both text profiles, every decimal scale byte, signed integer extrema,
F64 cast boundaries and random wide decimals, Gregorian/leap/century cycles,
BCE/year zero, date bounds, timestamp clamps, fractional and second-bearing
offsets, interval extrema, control/Unicode strings and a raw unsorted-key object.

- **28,901** bodies have exactly matching native and Python compact/pretty
  strings.
- **102** source formatting panics have native/Python error results.
- Additional tests cover noncanonical nonfinite Float64 bodies, unchanged byte
  ownership, 64 container levels, 65,536 nodes, a full 16 MiB binary string whose
  controls expand to almost 96 MiB of text, and public output exceeding 16 MiB.
- WAL-only and checkpoint/reopen tests preserve display results and bytes;
  failed formatting leaves the stored values, WAL and sequence unchanged.

These are finite differential cases and checked resource boundaries, not an
exhaustive enumeration of all values.

## Validation

All builds/tests run serially with Mojo 1.0.0 (ed45d567):

| Check | Result |
| --- | --- |
| `pixi run mojo run -I src tests/mojo/test_jsonb_writer.mojo` | 3 passed |
| `pixi run build-python` | Passed |
| New Python writer tests | 13 passed |
| Related Python writer/parser/payload tests | 74 distinct passed |
| Complete Python suite | 3,485 passed / 1 skipped / 3 existing warnings |
| Fixture/provenance/Cargo lock/license reproduction | Byte-identical |

Raw outputs, terminal statuses, timing and reproduction hashes are under
`.build/jsonb-writer-validation/`. The initial native compile found two
conditional integer literals requiring explicit UInt8; after correction the
native suite passed without any algorithm/output mismatch. Its first failed
log is retained. A subsequent oracle assertion-hardening/license-provenance
update reproduced identical case bytes and did not invalidate the native
output comparison. The additional noncanonical Float64 check passed separately
after the 73-test targeted run, making 74 distinct targeted cases.

No durable format, commit protocol or storage mutation path changed. Existing
successful crash/C validation remains applicable and was not rerun solely for
this read-only conversion. Native Linux remains deferred, not passed.

Next: complete Arrow JSON extension ingress/export using this actual text path,
preserving nullable storage slots versus JSON null and nested metadata. C/
distributed values, JSONB query/index functionality and every remaining full
product/platform/quality/performance deliverable remain required.
