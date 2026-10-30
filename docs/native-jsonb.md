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
Text serialization, JSONB traversal/indexing and Arrow JSON are still pending.

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
