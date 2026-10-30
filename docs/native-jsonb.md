# Native JSONB values

`akasha.document.JsonbValue` owns a checked binary JSONB value. Its encoding is
ported from jsonb 0.5.6's databend backend, the backend used by pinned Lance.
It can be stored in native collection payloads using `PayloadValue.jsonb(value)`.
Python/HTTP/NDJSON values, textual JSONB parsing/rendering and `arrow.json`
integration are still pending; those public boundaries do not yet accept this
logical type.

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
