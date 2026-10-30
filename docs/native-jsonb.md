# Native JSONB values

`akasha.document.JsonbValue` owns a checked binary JSONB value. Its encoding is
ported from jsonb 0.5.6's databend backend, the backend used by pinned Lance.
It can be stored in native collection payloads using `PayloadValue.jsonb(value)`.
Python/HTTP/NDJSON also transport this type as complete source bytes. Native
and Python text parsing support the original standard and extended profiles.
Text rendering and `arrow.json` integration remain pending.

```mojo
from akasha.document import JsonbValue

def main() raises:
    var json_null = JsonbValue.null()
    var storage_null = Optional[JsonbValue]()
    var valid_json_null = Optional(json_null.clone())
    var values: List[JsonbValue] = [json_null.clone(), JsonbValue.string("中文")]
    var array = JsonbValue.array(values)
    var bytes = array.to_bytes()
    var restored = JsonbValue(Span(bytes))
    var children = restored.children()
    print(children[1].as_string())
```

An outer absent slot and a present JSON null are different states. Plain JSONB
arrays contain values, including JSON null; they do not introduce an undefined
element. The future Arrow extension boundary must preserve its own validity.

## Native collection payloads

```mojo
from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document import JsonbValue

def write(path: String) raises:
    var collection = PersistentCollection.open(path, 2)
    collection.upsert_document(1, [1.0, 0.0], [
        DocumentField("json", PayloadValue.jsonb(JsonbValue.null())),
        DocumentField("items", PayloadValue.array([
            PayloadValue.null(), PayloadValue.jsonb(JsonbValue.string("present")),
        ])),
    ])
    collection.flush()
    collection.close()
```

`is_jsonb()` distinguishes the payload type and `as_jsonb()` returns an owned
copy; `clone()`, child extraction and stored snapshots retain independent data.
The native point/document APIs, WAL-only reopen, checkpoint/compaction and
physical backup/restore preserve exact source bodies, including accepted old
JSONB encodings. [Payload v3](formats/payload-format.md) is the default writer;
v1/v2 payload readers remain and old values migrate when rewritten. Existing
plain JSON paths treat the JSONB body as a leaf. Source-based JSONB traversal,
query and typed index integration remain separate work.

## Python and JSON transport

```python
from akashadb import JsonbValue, PayloadField

json_null = JsonbValue(bytes.fromhex("2000000000000000"))
field = PayloadField("items", "array", [None, json_null])
collection.upsert(1, [1, 0], [field])
assert collection.get(1).fields == [field]
http_field = field.to_wire()
assert PayloadField.from_wire(http_field) == field
```

Python `JsonbValue` is an immutable bytes carrier, not a second binary codec.
It checks the byte type and maximum body length; Mojo validates the complete
JSONB body and combined depth/node/byte limits before any write. Invalid bytes
may be held in the carrier but cannot enter the database. This API does not
interpret JSON text in Python. `JsonbValue.from_json` delegates text parsing to
Mojo. `set_payload` and `overwrite_payload` accept carriers inside
ordinary dicts/lists; JSONB null remains a value while plain null follows the
existing mutation semantics.

`PayloadField.to_wire()` preserves the ordinary JSON field shape unless JSONB
occurs in that field. JSONB fields use explicit `encoding: "typed"`, with each
container child encoded as a `{type, value}` node; JSONB values are hexadecimal
source bytes. `to_wire(typed=True)` always selects that representation.
The HTTP point routes accept it and return it for fields containing JSONB.
Typed payload updates put `encoding: "typed"` alongside `payload` and encode
each top-level value as a node. Ordinary dict keys never opt into this format.
NDJSON exports always use version 3 and typed fields; v1/v2 readers remain.
See [the wire contract](formats/logical-point-format.md) for exact value tags
and [the public API](python-api.md#jsonb-values) for examples.

## Constructors and readers

All constructors/readers that validate data can raise. `JsonbValue(Span(bytes))`
checks the entire body before copying; `to_bytes()`, `clone()`, `children()` and
`keys()` return independently owned data. `kind()` uses the tags below.

| Kind | Constructor | Reader |
| --- | --- | --- |
| 1 | `string(String)` | `as_string()` |
| 2 | `integer(Int64)` | `as_int()` |
| 3 | `floating(Float64)` | `as_float()` |
| 4 | `boolean(Bool)` | `as_bool()` |
| 5 | `null()` | `kind() == 5` |
| 6 | `array(List[JsonbValue])` | `children()` |
| 7 | `object(List[String], List[JsonbValue])` | `keys()`, `children()` |
| 8 | `unsigned(UInt64)` | `as_uint()` |
| 9 | `decimal(Span[UInt8], UInt8)` | `decimal_bytes()`, `decimal_scale()` |
| 10 | `binary(Span[UInt8])` | `as_binary()` |
| 11 | `date(Int32)` | `as_date()` |
| 12 | `timestamp(Int64)` | `as_timestamp()` |
| 13 | `timestamp_tz(Int64, Int32)` | `as_timestamp()`, `timezone_offset()` |
| 14 | `interval(Int32, Int32, Int64)` | `as_interval()` |

The source codec collapses signed and unsigned integer zero to unsigned zero.
Floating signed zero keeps its bits. NaNs use the source's canonical NaN tag;
positive/negative infinity have their own tags. This does not change the finite
floating contract of ordinary `PayloadValue` or the serde_json reader.

Decimal values use signed two's-complement big-endian unscaled bytes of width
8, 16 or 32 and an unsigned 8-bit scale. The API preserves the complete source
storage range; it does not yet provide decimal arithmetic or formatting.
Dates are signed days since the Unix epoch, timestamps signed microseconds,
timezone offsets signed seconds, and intervals `(months, days, microseconds)`.
These are binary codec fields, not calendar validation or formatting APIs.

Object construction sorts UTF-8 keys and rejects duplicates as the upstream
ObjectBuilder does. Empty and NUL-containing keys/strings are supported. Raw
objects may retain a different key order; keys must be unique. Wrong typed
readers raise instead of coercing values.

## Format and validation boundary

Headers and entry tables are big-endian. A scalar has one entry; arrays have
one entry per value; objects store all key entries/bodies before value entries/
bodies. Nested arrays/objects retain their headers. The source compacts integer
payloads to 1, 2, 4 or 8 bytes. Binary readers also accept the upstream's old
precision-bearing Decimal128/256 and hour-based timezone encodings. Raw bytes
are retained; reconstructing from the typed fields produces the current format.

The untrusted-input boundary checks complete consumption, entry/subcontainer
lengths, UTF-8, key types/uniqueness, scalar and numeric widths, extension tags,
depth, nodes and bytes. Offset-mode entries are rejected because this source
backend does not implement them. The upstream decoder's unchecked UTF-8 and
panicking malformed-input paths are not reproduced. This is deliberate input
validation; valid emitted source bytes are compared exactly.

Limits are 16 MiB for the complete encoded body, 65,536 values including the
root and all descendants, and 64 array/object levels. Object keys consume bytes
but do not add value nodes. Builders check aggregate bounds before allocating
the result. A scalar counts as one value and has container depth zero.

Source fixtures, old-format evidence and validation results are recorded in
[the codec report](research/2026-10-30-jsonb-codec-validation.md).


## Text parsing

```mojo
from akasha.document import parse_jsonb, parse_jsonb_bytes

def main() raises:
    var extended = parse_jsonb("{items:[1,,],label:'中文',n:0x1a.b}")
    var standard = parse_jsonb('{"items":[1,null,null]}', standard=True)
    var text = String("null")
    var json_null = parse_jsonb_bytes(text.as_bytes())
```

Python uses the same native parser:

```python
from akashadb import JsonbValue, PayloadField

value = JsonbValue.from_json("{items:[1,,],n:0x1a.b}")
plain = JsonbValue.from_json(b'{"items":[1,null,null]}', standard=True)
collection.upsert(1, [1, 0], [PayloadField("json", "jsonb", value)])
```

`parse_jsonb` / `parse_jsonb_bytes` and `JsonbValue.from_json` default to jsonb
0.5.6's extended profile, as pinned Lance does. Extended input allows leading
plus/zeros, hexadecimal integers/fractions, case-insensitive literals,
single-quoted strings, unquoted object keys, empty text as JSON null and omitted
array elements as null. `-NaN` and duplicate object keys are rejected; object
keys are sorted in the encoded body. Both profiles consume the entire input.

`standard=True` selects **the source library's standard profile**, rather than
the ordinary serde_json reader. Shared source string/whitespace routines still
accept raw control characters, exactly four hex digits in `\u{XXXX}`, escaped
whitespace outside strings and preserve unpaired surrogate escapes as literal
`\uXXXX` text. They reject invalid UTF-8 and unknown escapes (including `\'`).
Both modes allow exponent overflow to infinity, with source fast-float rounding.
The APIs preserve these source behaviors instead of silently substituting a
different JSON parser. The ordinary `parse_json` API retains its own contract.

Source text and decoded content are limited to 16 MiB; parsed values have at
most 65,536 nodes and 64 container levels. The resulting encoded body must also
fit its 16 MiB bound. Python accepts exact `str` or immutable `bytes` and an
exact `bool` mode; invalid text/resources raise `ValidationError`. Native APIs
raise `Error`. Error wording is Akasha's, not a reproduction of Rust's error
enum. Results own their data and can use all existing JSONB payload transports.

See [text parser validation](research/2026-10-30-jsonb-reader-validation.md).
JSONB traversal/indexing remains pending. Arrow extension interchange is described below.

## Text output

```mojo
from akasha.document import parse_jsonb, format_jsonb

def main() raises:
    var value = parse_jsonb("{items:[1,,],n:NaN}")
    print(format_jsonb(value))
    print(format_jsonb(value, pretty=True))
```

```python
value = JsonbValue.from_json("{items:[1,,],n:NaN}")
assert value.to_json() == '{"items":[1,null,null],"n":null}'
print(value.to_json(pretty=True))
```

Native `format_jsonb(value, *, pretty=False)` and Python
`JsonbValue.to_json(*, pretty=False)` use Lance's actual
`RawJsonb::to_string`/`to_pretty_string` serde path. They preserve raw body key
order, use serde_json string escaping and two-space pretty indentation, and
return UTF-8 strings without an added trailing newline. Python requires an
exact bool and validates the supplied binary body in Mojo before formatting.

This text is a projection, not lossless JSONB transport:

- Nonfinite floats become JSON `null`; finite F64 values use the pinned zmij
  formatter, retaining negative zero and source notation thresholds.
- Decimal64/128/256 convert through the source F64 cast and `10.powi(scale)`
  division because the pinned source disables `arbitrary_precision`.
- Binary becomes an uppercase hexadecimal JSON string. Dates, timestamps,
  timezone timestamps and intervals also become strings using source formats.
- Date Display uses six magnitude digits for negative years, while timestamp
  `%Y` uses a minimum total width of four. Timestamps keep six fractional digits,
  clamp to source bounds, and timezone text includes offset seconds when nonzero.
- The pinned release interval formatter's signed-minimum wrapping behavior is
  retained, including unusual minus signs; it is not silently normalized.

Out-of-range calendar dates and invalid timezone offsets raise native `Error`
or Python `ValidationError` instead of reproducing upstream's `unwrap` panic.
These values can still be valid binary JSONB and remain unchanged in storage.
Malformed bodies are rejected at the checked boundary; upstream's unchecked
raw-byte fallback is not exposed by this owned-value API.

Escaping and indentation can expand output beyond the 16 MiB binary-body/text-
input limit. Valid input byte/node/depth bounds bound that growth; formatting
does not impose a second 16 MiB output limit. Such expanded text may exceed the
parser's input bound. Use Python `.data` / Mojo `to_bytes()`, typed transport and NDJSON
for exact bytes/types rather than a text round-trip.

See [writer validation](research/2026-10-30-jsonb-writer-validation.md).

## Arrow JSON interchange

Both `upsert_record_batch` and `upsert_point_record_batch` accept `pa.json_()`
with string, large-string or StringView storage. They also accept a large-binary
field with `ARROW:extension:name = lance.json`. Native Mojo converts text using
the extended source parser; binary cells use the checked JSONB constructor.
Plain string columns remain strings. Unknown extensions and incompatible storage
are rejected; unmarked binary columns are outside this payload adapter.

```python
import pyarrow as pa
from akashadb.arrow import upsert_record_batch, scan_record_batches

batch = pa.record_batch([
    pa.array([1, 2, 3], type=pa.int64()),
    pa.array([[1.0, 2.0]] * 3, type=pa.list_(pa.float32(), 2)),
    pa.array([None, "null", "{items:[1,,],n:NaN}"], type=pa.json_()),
], names=["id", "vector", "payload.document"])
upsert_record_batch(collection, batch)

binary = pa.field("document", pa.large_binary(), metadata={
    b"ARROW:extension:name": b"lance.json",
})
with scan_record_batches(collection, columns=(), payload_schema={"document": binary}) as scanner:
    binary_batches = list(scanner)
with scan_record_batches(collection, columns=(), payload_schema={"document": pa.json_(pa.string_view())}) as scanner:
    text_batches = list(scanner)
```

The collection above has dimension 2. Storage null remains ordinary payload
null; valid text `null` becomes a distinct `JsonbValue`. This distinction also
holds inside struct, list, large-list, fixed-list and map children. Parent nulls
mask semantic child parsing, matching Akasha's existing typed Arrow contract.
Arrow's structural/UTF-8 validation still applies to incoming batches. Each
nonempty batch validates before atomic publication; the existing empty-ingress
rejection is unchanged. Empty collections retain the requested scanner schema.

A map is stored as an ordered array of two-field entry objects. The C Data
boundary normalizes names to `entries`/`key`/`value`, following PyArrow 21.
Duplicate and non-string keys retain order; map entries and keys must be non-null.
The caller's `keys_sorted` declaration is retained without sorting or deduplication.
User field metadata and nested nullability survive requested projections. Arrow's
registered `arrow.json` type consumes its reserved extension metadata keys;
Lance's name/serialized metadata remain on the binary field. Like the source
Lance adapter, recognition does not interpret serialized extension parameters.

Text output uses `format_jsonb`, so the lossy projection rules above also apply
to Arrow. Use `lance.json` for exact original body bytes, including legacy and
noncanonical encodings. Native rendering shares the scanner's finite output
budget and cooperatively checks cancellation/deadlines, including binary-to-hex
expansion. All output buffers have independent C Data ownership and remain valid
after scanner/collection close. Text conversion is not zero-copy.

This does not persist the producer's table schema or implement schema evolution,
Lance file interoperability, JSONB field-path filtering or indexes. See the
[Arrow JSON source validation](research/2026-10-30-arrow-json-validation.md).

## Numeric dependency

The native `akasha.document.fast_float` module provides
`parse_fast_float(Span[UInt8]) -> Float64` and
`parse_fast_float_partial(Span[UInt8]) -> Tuple[Float64, Int]`, both raising on
invalid input. The latter returns a consumed byte count. These are the pinned
fast-float2 F64 token rules, including optional plus signs, partial decimal
forms, Inf/NaN, signed zero and overflow to infinity. They are not a JSON
validation API. The complete grammar above consumes these tokens to build
`JsonbValue`; the ordinary serde_json reader keeps its separate numeric contract.
See [numeric source validation](research/2026-10-30-fast-float-validation.md).

The writer's `akasha.document.zmij` dependency ports the source F64 fast path,
Schubfach fallback and portable digit writer. Its standalone `format_zmij`
returns source `NaN`/`inf` tokens; the enclosing JSON serializer applies the
nonfinite-to-null rule above. See [formatting validation](research/2026-10-30-zmij-validation.md).


## Native JSONB path grammar

`JsonbPath.parse(String)` and `JsonbPath.parse_bytes(Span[UInt8])`, exported from
`akasha.document`, build an owned bounded AST using jsonb 0.5.6's complete
path/expression grammar. This is a native query dependency: **selection,
predicate evaluation, source Display and Python/collection query APIs are still
pending**. Parsing a path does not execute it against a document.

```mojo
from akasha.document import JsonbPath

def main() raises:
    var selection = JsonbPath.parse("$.book[*]?(@.price < 10)")
    var predicate = JsonbPath.parse("$.price < 10")
    print(selection.is_predicate())  # False: a selection chain
    print(predicate.is_predicate())  # True: one root expression
```

The parser accepts dot/colon/quoted fields, array/index/range/last-relative
selectors, recursive levels, filters, exists, unary/binary arithmetic,
comparisons/starts-with and and/or expressions. Integer and floating literals
retain their source variants and bits. It is separate from the existing Qdrant
`JsonPath`, not a replacement or a union of two syntaxes.

Source quirks are intentional: empty paths are legal, quoted empty fields are
rejected, raw fields can include tab/newline/ampersand, and integer alternatives
precede the float recognizer. For example, `1.0` alone is a two-field path while
`$.x == 1.0` is rejected; `$.x == .5` reaches the float branch. Arithmetic atoms
have the source's restricted structure, not a general expression precedence
parser. `is_predicate()` tests for a single root Expr, including arithmetic.
Unterminated quoted-string source panics become native errors.

Limits are 65,536 input bytes, 65,536 AST nodes, 64 syntax/AST levels and
1,000,000 parser steps. The AST retains no input-buffer references. These are
resource adaptations, not claims about unbounded upstream inputs. See
[path grammar validation](research/2026-10-30-jsonb-path-parser-validation.md)
and the [complete query implementation plan](plans/2026-10-30-jsonb-path-source-port.md).
