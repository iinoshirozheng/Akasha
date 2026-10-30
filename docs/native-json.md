# Native JSON values

Mojo callers can parse JSON directly into the existing owned `PayloadValue`
model, then use normal document writes, payload operations and filters:

```mojo
from akasha import DocumentField, PersistentCollection
from akasha.document import parse_json

def main() raises:
    var collection = PersistentCollection.open("./json-example", 2)
    var value = parse_json('{"title":"hello","tags":["a",null],"count":42}')
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", value^)])
    collection.close()
```

`parse_json(String)` and `parse_json_bytes(Span[UInt8, origin])` accept one whole
JSON value with optional JSON whitespace. The byte form validates UTF-8 strings;
neither function retains the input buffer. No Python parser is invoked.

The source profile is serde_json **1.0.151**, `std` + `preserve_order`, without
`float_roundtrip` or `arbitrary_precision`. This is an explicit dependency
profile, not a claim that every build of Qdrant or Lance enables the same flags.

- Objects keep first insertion order; a repeated key replaces its value in that
  original slot. Empty and NUL-containing object keys are valid. The enclosing
  collection's top-level `DocumentField` name rules still apply.
- Values include strings, bool, explicit null, arrays, objects, Int64, UInt64 and
  finite Float64. Positive integers through Int64.MAX use the existing signed
  representation; larger values through UInt64.MAX use UInt64.
- Larger integer literals and negative values below Int64.MIN follow the source
  conversion to Float64. Decimal/exponent inputs use the source's default
  significand and power-of-ten conversion. This does **not** promise arbitrary
  precision or correctly rounded decimal conversion; changing the source
  feature profile can change low bits. `-0` retains negative floating zero.
- Nonfinite numbers, malformed escapes, unpaired surrogates, invalid UTF-8,
  trailing input/commas and invalid JSON grammar fail before returning a value.
  Errors are native errors; serde_json's exact text/line/column API is not exposed.
- Limits are 16 MiB of input bytes, 16 MiB of decoded content, 65,536 parsed
  values and 64 container levels. Nodes/content include duplicate entries later
  discarded. These are bounded-input/value contracts, not a process RSS limit.

The parser uses the existing durable value format and does not change Arrow
behavior. Typed StringView input/output is available separately. Standard
`arrow.json` input/output, its storage-null distinction and Lance/jsonb textual
numeric semantics remain in the [interop plan](plans/2026-10-30-json-interop-source-port.md).
The separate [native JSONB binary-value API](native-jsonb.md) preserves that
source format and extended types; it is not yet integrated with collection
storage or Arrow JSON. Native parse support alone does not implement those
capabilities or an HTTP JSON parser.
