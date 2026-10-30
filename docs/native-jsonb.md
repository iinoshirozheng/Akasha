# Native JSONB values

`akasha.document.JsonbValue` owns a checked binary JSONB value. Its encoding is
ported from jsonb 0.5.6's databend backend, the backend used by pinned Lance.
It can be stored in native collection payloads using `PayloadValue.jsonb(value)`.
Python/HTTP/NDJSON also transport this type as complete source bytes. Native
and Python text parsing support the original standard and extended profiles.
Native/Python text rendering and Arrow JSON interchange are available below.
Native/Python value queries, collection JSONB filters and computed scanner
columns are available below. Dedicated indexes, SQL and complete protocol
integration remain pending.

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
element. The Arrow extension boundary preserves its independent validity.

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
storage range. `JsonbNumber` below provides the source arithmetic/comparison
rules; text rendering uses the source's floating conversion for decimals.
Dates are signed days since the Unix epoch, timestamps signed microseconds,
timezone offsets signed seconds, and intervals `(months, days, microseconds)`.
These constructors preserve binary codec fields; `format_jsonb` applies the
source's calendar validation and formatting rules.

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
path/expression grammar. `JsonbSelector` below executes it; parsing alone does
not execute a query. Native AST/Number Display, collection filters and computed
scanner columns are available below; dedicated indexes remain pending.

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

## Native JSONB expression numbers

`akasha.document.JsonbNumber` provides source Number comparison and arithmetic
for Int64, UInt64, Float64 and Decimal64/128/256. Construct with `integer`,
`unsigned`, `floating`, or `decimal(big_endian_bytes, scale)`, or convert a
numeric `JsonbValue` with `from_value`. `to_value` returns a canonical JSONB
number body; accepted legacy decimal bodies decode to the same numeric value.

```mojo
from akasha.document import JsonbNumber

def main() raises:
    var a = JsonbNumber.integer(-5)
    var b = JsonbNumber.integer(2)
    print(a.rem(b).as_f64())  # -1.0: source truncating remainder
    print(a.cmp(b))          # -1, 0, or 1
    var stored = a.add(b).to_value()
```

Methods are `neg`, `add`, `sub`, `mul`, `div`, `rem`, `cmp`, and `as_f64`.
The fixed-size Number retains its variant between operations, including signed
integer zero and floating bits. Serializing may canonicalize integer zero or
NaNs as described above. It owns no input references.

These are the original jsonb rules: mixed signed/unsigned arithmetic can cast
before checking overflow; subtraction returns Int64; division returns Float64;
binary arithmetic involving decimals uses source Float64 conversion. Decimal
comparison instead promotes coefficients and adjusts scales exactly when the
source checked multiplication succeeds, then uses its float fallback on overflow.
The pinned release source wraps the scale power before checking multiplication.
Decimal64/128 minimum negation wraps; Decimal256 minimum negation errors.
NaNs sort equal and above infinity; positive and negative floating zero compare
equal. Overflow and zero division raise the original source error messages.

Floating remainder uses native libm `fmod`, matching Rust's truncating operation.
Mojo 1.0 floor `%` and nearest-quotient `std.math.remainder` have different rules.
Finite results, infinity and signed zero are compared bit-for-bit with Rust;
arithmetic NaNs are compared by classification because their payload/sign are
not a portable arithmetic guarantee. This API is a native selector dependency,
and backs the selector below. See [numeric validation](research/2026-10-30-jsonb-number-validation.md).

Exact Number conversions `as_i64()` and `as_u64()` return `Optional` and reject
fractional values. Rounded `to_i128()`, `to_i64()` and `to_u64()` follow source
nearest-integer rounding with ties away from zero, returning absence on overflow
or nonfinite input. Decimal conversion uses fixed-width integer arithmetic;
it does not pass through Float64. Float target checks use half-open bounds.
Scale-zero, scales beyond representable powers, negative zero, signed minima and
unsigned maxima retain the original Number contract.

## JSONB value queries

Python `JsonbValue.query(path: str | bytes, *, mode="values", max_work=1_000_000,
max_results=65_536, max_bytes=67_108_864, cancellation=None, timeout_ns=None)`
parses and executes the original JSONB grammar in Mojo. It validates arbitrary
carrier bytes before executing and returns independently owned values.

```python
from akashadb import JsonbValue

value = JsonbValue.from_json('{items:[{price:3},{price:9},{price:7}]}')
selected = value.query('$.items[*]?(@.price < 8)', mode="array")
assert selected.to_json() == '[{"price":3},{"price":7}]'
assert value.query('$.items[*].price', mode="first").to_json() == '3'
assert value.query('$.missing', mode="value") is None
```

| Python mode | Native `JsonbSelector` method | Result |
| --- | --- | --- |
| `values` | `select_values` | List of every match; empty list if missing |
| `array` | `select_array` | One JSONB array containing every match |
| `first` | `select_first` | First match or absent |
| `value` | `select_value` | Absent, one value, or an array of multiple matches |
| `exists` | `exists` | Whether execution produced any item |
| `predicate` | `predicate_match` | Boolean, or absent for unknown/nonpredicate |

Python absence is `None`; native absence is `Optional`. JSON null always
remains a present `JsonbValue`. A predicate that evaluates to false still
produces a boolean item, so `exists` returns true for it. First/existence modes
execute the complete source selection before returning; they do not suppress
later errors or work limits by stopping early.

Native usage keeps an owned root and starts fresh execution on every call:

```mojo
from akasha.document import JsonbPath, JsonbSelector
from akasha.document.jsonb_reader import parse_jsonb

def main() raises:
    var selector = JsonbSelector(parse_jsonb("[1,2,3]"))
    var path = JsonbPath.parse("$[0,0 to 1,last]")
    var values = selector.select_values(path)  # 1, 1, 2, 3 in source order
```

Object traversal preserves stored order. Recursive traversal is preorder;
overlapping index groups retain duplicates. Bracket wildcard is lax for
scalars/objects; dot wildcard selects only object values. Arithmetic inputs
flatten arrays once: unary accepts a numeric sequence, binary requires exactly
one number on each side. Extension values are skipped in expression conversion
as in the source. Containers yield unknown comparisons. Comparison examines
cross-product pairs in source order, returning on the first true or unknown.
And/or evaluate both operands and propagate unknown rather than applying SQL
three-valued short-circuit rules.

Arithmetic output follows the source's serde Number serialization. In the
pinned profile this converts Decimal results to Float64 even for unary plus;
ordinary selection preserves original Decimal and legacy bytes. Invalid
arithmetic/cardinality errors are retained. Queries do not mutate stored data.

Native constructor limits have the same defaults as Python. Work includes
traversal/expression operations and virtual index-set size. Result limits apply
to intermediate and final value sequences; the byte limit bounds cumulative
owned staging, with final arrays checked separately. Output values retain the
existing codec bounds: 16 MiB, 65,536 nodes and 64 container levels. A root at
maximum depth can be returned unchanged but cannot be wrapped at level 65.
The original negative range-end to usize cast can request an enormous set;
Akasha rejects it before allocation, including `[0 to last]` on an empty array.
These are explicit bounded-execution adaptations, not changed success values.

Native `control=QueryControl(...)` supports cooperative cancellation/deadlines
and a work budget. Python accepts the existing `CancellationToken`, sampled
before its synchronous native call, and a positive `timeout_ns` checked during
native execution. It does not promise Python-thread cancellation mid-call.
Malformed mutable native ASTs, invalid inputs and exhausted limits raise errors.

This value-level API also works on values read after WAL/checkpoint reopen.
The APIs below separately expose Lance Arrow transformations, collection
predicates and computed scanner columns. JSONB indexes, SQL UDFs and complete
C/distributed query exposure remain pending.

## Native source Display

`format_jsonb_number_display(number, *, max_bytes=512)` and
`format_jsonb_path(path, *, max_bytes=65_536, max_work=1_000_000, control=None)`
are exported by `akasha.document`. They implement the original jsonb 0.5.6
Number and parsed-AST Display contracts, independently of `format_jsonb`.

```mojo
from akasha.document import JsonbNumber, JsonbPath
from akasha.document import format_jsonb_number_display, format_jsonb_path

def main() raises:
    print(format_jsonb_number_display(JsonbNumber.floating(1.0)))  # 1.0
    print(format_jsonb_path(JsonbPath.parse("$ [1,last + 2]")))  # $[1, last+2]
```

Number Display preserves Decimal scale and coefficient text instead of converting
to Float64. Floating values use the existing original zmij formatter, including
`NaN`, `inf`, `-inf` and signed zero. Integer output is exact. The source's
Decimal edge behavior is retained: Decimal128 minimum with nonzero scale may
produce two minus signs; Decimal256's split/cast rules can truncate or wrap high
digits beyond its intended decimal range. This is the source formatter's output,
not a promise of valid JSON or numeric round trips.

Source Decimal lookup/padding panics and Decimal256 minimum negation become
`JSONB Number Display source panic` errors. These Display limits do not change
which binary values can be stored, selected or rendered through `format_jsonb`.

Path Display normalizes whitespace, operators, index groups and selected
parentheses as source does. Field names and string literals are written without
escaping: a quoted literal field containing a dot can display as a dotted path;
quotes/control characters may make the displayed text unparsable. Use the
original input or owned AST when identity matters. The existing AST represents
the complete parsed grammar; manually constructed Rust Raw/Decimal literal
variants outside that AST are not added by this formatter.

Results own their text. Mutable ASTs share the selector's structure/depth/text
validation before traversal. Output bytes and rendered visits are bounded;
repeated DAG children consume work on each visit. Native QueryControl applies
cancellation, deadlines and candidate budgets. Both formatters reject nonpositive
limits; Number formatting has fixed bounded internal output before its byte
limit check. These are native helpers, with no new Python/protocol API.

## Source scalar casts

Python `JsonbValue.cast(target)` delegates the original RawJsonb scalar
conversion to Mojo. Targets are `bool`, `int64`, `uint64`, `float64`, and `string`.
Invalid targets or conversions raise `ValidationError`; the existing carrier
constructor retains its `TypeError`/`ValueError` checks for type/size violations.

```python
from akashadb import JsonbValue

assert JsonbValue.from_json('1.5').cast('int64') == 2
assert JsonbValue.from_json('-1.5').cast('int64') == -2
assert JsonbValue.from_json('"18446744073709551615"').cast('uint64') == 2**64 - 1
assert JsonbValue.from_json('"YeS"').cast('bool') is True
assert JsonbValue.from_json('"hello"').cast('string') == 'hello'
```

Native equivalents, exported by `akasha.document`, are `jsonb_to_bool`,
`jsonb_to_i64`, `jsonb_to_u64`, `jsonb_to_f64`, and `jsonb_to_str`.

- Boolean casts accept booleans or ASCII-case-insensitive `true`, `false`, `yes`,
  `no` strings. Numeric 0/1 and strings `"0"`/`"1"` are rejected.
- Integer casts convert booleans to 0/1 and round numeric values using Number's
  source rules. Strings try exact signed/unsigned integer parsing first, then
  float parsing and rounding. They do not trim whitespace.
- Float casts accept numbers, booleans and source-compatible numeric strings,
  including nonfinite values. Exact IEEE bits are checked against Rust parsing.
- String casts return an existing string unquoted, booleans as lowercase text,
  and numbers through Number Display, including Decimal scale and source quirks.

Null, arrays, objects and extension values reject these raw casts. This differs
from Lance's nullable get functions below, which check null/missing before
casting. It also differs
from `to_json()`, which serializes complete containers and quotes strings.
Cast failures do not mutate stored values, and returned strings own their bytes.
Existing binary input bounds apply; no durable format or query contract changes.

## Lance JSON functions

`akashadb.json_functions` exposes the eleven original Lance consumer operations.
Ten correspond to Lance DataFusion JSON UDFs; `json_path` wraps the original
per-row Lance Arrow helper with the same nullable/broadcast batch boundary.
Pass a `JsonbValue` (or `None`) for a scalar result, or a PyArrow `LargeBinary`
array for an Arrow result. JSONB bytes are already encoded; text parsing remains
`JsonbValue.from_json`. Arrow path/key/needle arguments are `Utf8` arrays, or a
Python string/None broadcast to all rows. A one-element argument array also
broadcasts. Inputs with `lance.json` extension storage can pass `.storage`.

```python
import pyarrow as pa
from akashadb import JsonbValue
from akashadb import json_functions as jf

value = JsonbValue.from_json('{items:[1,2],price:1.5,flag:"YES"}')
assert jf.json_path(value, '$.items[*]') == '1'
assert jf.json_extract(value, '$.items[*]') == '[1,2]'
assert jf.json_get_int(value, 'price') == 2
assert jf.json_get_bool(value, 'flag') is True
assert jf.json_array_length(value, '$.items') == 2

column = pa.array([value.data, None], type=pa.large_binary())
assert jf.json_extract(column, '$.items').to_pylist() == ['[1,2]', None]
typed = jf.json_extract_with_type(column, '$.price')
assert typed.to_pylist()[0]['type_tag'] == 3
```

| Function | Scalar result / Arrow output |
| --- | --- |
| `json_path(value, path)` | First selected JSON text / Utf8 |
| `json_extract(value, path)` | JSON text; multiple matches form an array / Utf8 |
| `json_extract_with_type(value, path)` | `{value, type_tag}` / Struct(LargeBinary, UInt8) |
| `json_exists(value, path)` | Whether any value is selected / Boolean |
| `json_get(value, key)` | Owned JsonbValue / LargeBinary |
| `json_get_string(value, key)` | Nullable source cast / Utf8 |
| `json_get_int(value, key)` | Nullable source cast / Int64 |
| `json_get_float(value, key)` | Nullable source cast / Float64 |
| `json_get_bool(value, key)` | Nullable source cast / Boolean |
| `json_array_contains(value, path, needle)` | Source rendered-element comparison / Boolean |
| `json_array_length(value, path)` | First match's array length / Int64 |

Keys are exact object keys, including empty strings, dots and Unicode. Array
keys use Rust's unsigned decimal integer grammar (optional `+`, leading zeros,
no whitespace/negative sign); these are not JSON paths. Missing keys return None.
`json_get` preserves JSON null as a value; typed get functions return None for
JSON null before casting. `json_exists` tests selection, so a selected `false`
or JSON null still exists.

Type tags are Null=0, Boolean=1, Int64=2, Float64=3, String=4, Array=5, Object=6.
Stored Float64 remains tag 3 even when integral; exact integral Decimal/UInt64
within Int64 range can be tag 2. Extensions get tag 4 while retaining their
binary bytes. A missing/null input produces `{value: None, type_tag: 0}`;
a selected JSON null has non-null JSONB bytes and tag 0. The Arrow struct itself
is non-null and its type_tag field is non-nullable.

Array contains checks the elements of every selected array against `needle`
and a simply quoted `needle`, using the source JSON writer. It does not escape
the alternative string or perform structural/numeric equality. Array length
uses the first match; a valid nonarray returns 0, and no match returns None.
Both execute the source's full selection before consuming matches.

Null storage/path/needle rows return null before decoding or parsing, except
for typed extraction's struct described above. Other row errors abort the whole
batch. Results own their data and remain usable after inputs/collections close.
Arrow structural/UTF-8 validation precedes transport. Python only transports
values and constructs typed Arrow output; row selection,
null/broadcast handling, binary traversal and all computations run in Mojo.
The current Arrow transport materializes primitive lists; it is not zero-copy.

All functions accept `max_work=1_000_000`, `max_results=65_536`,
`max_bytes=64*1024*1024`, `cancellation=None`, and `timeout_ns=None`.
Work limits apply per row and traversal/consumer phase; repeated source array
index scans are charged for each visit. Results limit bounds selector matches
and batch rows. The byte budget bounds native input transport, staging and
output; output accounting includes null slots. Batches/argument arrays have a
65,536-row cap, individual bodies retain the 16 MiB/depth/node codec limits,
and each string argument has a 65,536 UTF-8 byte cap. Arguments must have length
one or cover every body row; extra source-compatible argument rows are ignored.
Negative/zero limits, invalid shapes/types and exhausted budgets raise
`ValidationError`. Python cancellation is sampled before the synchronous call;
native deadlines/cancellation are checked during work. Source panics become
errors; binary and parser limits remain enforced.

Native `LanceJson(value, ...)` exposes `json_path`, `extract`,
`extract_with_type`, `exists`, `get`, `get_string`, `get_int`, `get_float`,
`get_bool`, `array_contains`, `array_length`. Native typed extraction returns
`Optional[Tuple[JsonbValue, UInt8]]`; Arrow/scalar Python exposes the row struct.
Exact helpers `jsonb_get_by_name`, `jsonb_get_by_index` and `lance_json_type`
are also exported by `akasha.document`.

These functions work on values read from a collection or an Arrow scanner.
Boolean collection predicates and computed scanner columns are described
below. Dedicated indexes, SQL UDF registration, document-record computation
and complete C/distributed query exposure remain separate tasks.

## Collection JSONB filters

The existing collection filter tree accepts a `jsonb` leaf. Selection and
computation run in Mojo, reusing the source selector and Lance consumers above.

```python
from akashadb import JsonbValue, PayloadField, QueryRequest

collection.upsert(1, [1.0], [PayloadField(
    "data", "jsonb", JsonbValue.from_json('{price:12,active:true,tags:["sale"]}')
)])  # example collection dimension: 1
predicate = {
    "kind": "jsonb", "key": "data", "function": "predicate_match",
    "argument": "$.price >= 10 && $.active == true",
}
hits = collection.query(QueryRequest(filter=predicate))
collection.set_payload({"selected": True}, filter=predicate)
```

| `function` | `argument` | Match rule |
| --- | --- | --- |
| `predicate_match` | JSONB path/expression | Source predicate result is true; unknown and non-predicate paths do not match |
| `json_exists` | JSONB path/expression | Source selects any value, including false or JSON null |
| `json_array_contains` | JSONB path/expression | Source array contains `needle` (required string), using rendered-element comparison |
| `json_get_bool` | Exact object key or unsigned array index string | Source nullable boolean cast is true; missing/null is a nonmatch, invalid casts raise |

`key` is the existing Qdrant-style payload path, for example `items[].data`;
`argument` uses the separate JSONB grammar, except for exact-key `json_get_bool`.
The empty string is a valid exact key. Any selected carrier that matches makes
the leaf true, in payload traversal order. Missing fields and storage null do
not match. JSONB null is a real JSONB value. A visited non-JSONB value raises
`ValidationError`; strings and ordinary objects are not implicitly converted.

The leaf composes with existing `all`, `any`, `not`, `nested` and `at_least`
nodes. Outer Boolean semantics remain the collection filter contract, including
`not` of a nonmatch being true. This is not SQL three-valued logic. Row-local
short circuiting is preserved in metadata bitmap evaluation, so masked invalid
values do not cause extra errors. Expressions containing JSONB currently use
the metadata plain checker over the whole expression, not a dedicated JSONB
index or independent per-leaf set operations.

Optional positive Int64 `max_work`, `max_results`, `max_bytes` default to
1,000,000, 65,536 and 64 MiB. These bound each evaluated carrier and native
traversal/consumer phase, not the total collection query. String arguments and
needles are limited to 65,536 UTF-8 bytes. Existing outer query controls retain
their checkpoints; this integration does not add mid-leaf cancellation checks.
Unknown properties, invalid types, incompatible/missing `needle`, invalid
limits and path syntax are rejected during filter construction, even on an
empty collection. Unlike scalar/Arrow value functions, a missing/null payload
does not suppress configuration errors. Existing API no-op/zero-limit
short circuits remain unchanged.

The shared tree reaches scans, dense/HNSW/IVF/sparse/hybrid and batch searches,
universal queries/formula conditions, Arrow results, current HTTP search routes
and conditional payload set/overwrite/delete/clear. Updates select and validate
before their atomic commit; data-dependent errors leave WAL and sequence
unchanged. Snapshots retain their own JSONB values across updates and reopen.
Native callers use `FilterExpression.jsonb(JsonbCondition(...))` from
`akasha.query` or `akasha`.

This is an Akasha filter extension composed from source implementations. It
does not claim a Qdrant wire condition, SQL execution, computed projection or
dedicated JSONB indexing. See [integration validation](research/2026-10-30-jsonb-condition-validation.md).

## Computed JSONB scanner columns

`scan_record_batches` can evaluate the eleven [Lance functions](#lance-json-functions)
inside the captured collection scan. Computation and final Arrow buffers are
native; Python only transports configuration and constructs the schema.

```python
from akashadb.arrow import scan_record_batches

scanner = scan_record_batches(
    collection, columns=("id",),
    json_columns={
        "price": {"function": "json_get_float", "input": "data", "argument": "price"},
        "items": {"function": "json_extract", "input": "data", "argument": "$.items[*]"},
        "name": {
            "function": "json_get_string", "argument": "name",
            "input": {"function": "json_get", "input": "data", "argument": "profile"},
        },
    },
)
for batch in scanner:
    print(batch.to_pydict())
```

`json_columns` maps unique output aliases to expressions. An expression requires
`function`, `input` and `argument`; `json_array_contains` additionally requires
`needle`. Arguments and needles are constant strings or null. `input` is an
exact stored payload field name (not a Qdrant path) or another `json_get`
expression. Intermediate inputs must return JSONB, so scalar/typed-struct
outputs cannot be supplied as JSONB. Nesting executes from inner to outer;
an outer null argument does not suppress errors in an evaluated inner call.

Result types match the value functions: Utf8 for text, LargeBinary for JSONB,
Boolean, Int64, Float64, or the non-null typed-extraction struct. Raw binary
results retain their source JSONB bytes and can be wrapped in `JsonbValue`.
Float64 preserves nonfinite values and signed zero; computed results do not
pass through the finite-only persisted payload type. A missing/storage-null
input yields a null output, except typed extraction's `{value: null, type_tag: 0}`
struct. Stored JSONB null remains a real value. Ordinary non-JSONB fields are
errors. A valid null argument yields the source null result after its input
has been evaluated.

Configuration and non-null path syntax are checked eagerly, including on empty
scans. `json_get*` arguments are exact keys/index strings, including empty keys.
Unknown properties, invalid types, incompatible `needle`, nonpositive limits,
non-JSONB intermediate output, and invalid aliases are rejected. At most 256
computed columns and 16 function steps per expression are allowed; each string
argument/needle has a 65,536 UTF-8 byte bound. The native configuration transport
also enforces its aggregate node/byte limits.

Only the outer expression accepts `max_work=1_000_000`, `max_results=65_536`,
and `max_bytes=64*1024*1024`. These retain the source per-call traversal/consumer
limits for each row and step. Native cancellation/deadline checks reach the
source functions; scanner `max_candidates` continues to count visited rows,
separately from JSON traversal work. Python cancellation is checked between
batches as for existing scanners.

`max_batch_bytes` bounds the shared aligned final-buffer allocations across all
columns. A separate temporary budget of that size bounds one computed column's
fixed result cells plus owned string/binary result bytes before export. It is
not a peak-RSS bound: retained source generations, source-call working memory
and Arrow metadata are excluded. Output statistics count final logical buffer
bytes, excluding padding; computed columns own their output and borrow no
source buffers. Earlier returned batches/slices survive scanner/collection close.

Filtering happens before projection. Data errors abort the current batch and
close the scanner; no rows from a failed batch are returned. Earlier batches
remain valid. Updates after scanner creation do not change its captured input.
Neither projection nor its errors write WAL or advance collection sequences.

Native callers use `JsonbProjection(spec: PayloadValue).evaluate(fields, control)`
to obtain an owned `LanceJsonResult`. The result stores nullable source text,
binary, integer, float or boolean values and the typed-extraction tag. The
shared `evaluate_lance_json` dispatcher is also used by the scalar/Arrow value
functions, so projection does not introduce another selector/cast algorithm.

This scanner layer does not provide SQL syntax, column-valued path arguments,
computed document-record projection or dedicated JSONB indexes. Those remain
tracked in the full plan. See [validation](research/2026-10-31-jsonb-projection-validation.md).
