# Python API

Build the Mojo extension before importing the local package:

```bash
pixi run build-python
PYTHONPATH=python python -c 'import akashadb; print(akashadb.__version__)'
```

`akashadb.Collection(path, dimension)` owns an embedded Mojo
`PersistentCollection`. `upsert`, `apply_batch`, sparse updates, delete,
flush, lookup, and every query execute in the compiled kernel. `close()` drains
background maintenance before releasing the collection directory lock.

## Atomic mutations

```python
from akashadb import BatchMutation, Collection, PayloadField

collection = Collection("/tmp/python-batch", 3)
commit = collection.apply_batch(
    [
        BatchMutation.upsert(
            1,
            [1.0, 0.0, 0.0],
            [PayloadField("chunk", "string", "owned text")],
        ),
        BatchMutation.delete(9),
    ]
)
print(commit.first_sequence, commit.last_sequence)
```

The return value names the contiguous accepted sequence range. Validation failure
changes neither durable nor live state. An append/fsync error can leave a complete
durable envelope even when the call raises. After that error, or a failure while
publishing committed batch state, new operations fail with `requires reopen`.
Close and reopen the collection to recover the entire accepted batch or discard
its incomplete tail. Previously captured snapshots remain valid; do not infer
that an I/O exception means the batch is absent on disk.

## Dense batches and filters

```python
filters = [
    {
        "kind": "condition",
        "name": "language",
        "operator": "eq",
        "type": "string",
        "value": "zh-TW",
    },
    {
        "kind": "condition",
        "name": "page",
        "operator": "ge",
        "type": "int",
        "value": 10,
    },
]
results = collection.search_batch(
    "cosine",
    [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    10,
    num_workers=4,
    filters=filters,
)
```

`filters` is optional. When present, its length must equal the vector count;
each dictionary uses the same bounded condition/all/any/negate shape as
`SearchRequest.filter`. Result lists remain aligned to input vectors.

A condition's `type` describes its query literal. Integer and string `eq` match
their corresponding JSON scalar values; unsigned values fitting Int64 can match
integer literals. `ne` follows Qdrant MatchExcept, including other present types
but excluding null. Arrays use one-level any-element evaluation; nested arrays
are not recursively flattened. Numeric ranges and floating-literal comparisons
include signed/unsigned integers and float values after Float64 conversion, so integers above 2^53 may
round in range comparisons. Boolean conditions match only booleans. Missing
and null fields fail these scalar comparisons; an outer `not` includes those fields.

### JSON-path payload filters

`condition.name` keeps its literal field-name meaning. `field.key` uses Qdrant
JSON paths, including quoted keys, array indexes and `[]` traversal:

```python
predicate = {
    "kind": "nested", "key": "items",
    "filter": {"kind": "all", "children": [
        {"kind": "field", "key": "color", "match": {"value": "red"}},
        {"kind": "field", "key": "stock", "range": {"gt": 0}},
    ]},
}
hits = collection.search(SearchRequest("cosine", 10, vector=query, filter=predicate))
collection.set_payload({"available": True}, filter=predicate)
```

`nested` appends `[]` unless already present and accepts only object elements.
Its entire child filter must match the same element; separate array elements
cannot satisfy different parts. Paths inside the child are relative to that
object. Nested objects retain support for empty and NUL-containing quoted keys.
`{"kind": "at_least", "min_count": 2, "children": [...]}` requires that many
matching children. Zero matches every point; a count above the number of children
matches none. These nodes compose with existing `all`, `any`, `not` and literal
`condition` nodes under the same 16-level/256-node limits.

Supported `field` properties:

| Property | Native behavior |
| --- | --- |
| `match.value` | Exact string, bool or Int64 match; `2.0` does not match integer `2` |
| `match.any` / `match.except` | Homogeneous string or Int64 lists; source MatchExcept type/null rules |
| `match.text` / `match.phrase` | Case-sensitive substring check in the plain payload evaluator |
| `match.text_any` | Any substring token, split with Rust Unicode whitespace rules |
| `match.prefix` | Case-sensitive string prefix |
| `range` | Optional `lt`, `gt`, `lte`, `gte`; all supplied bounds apply |
| `values_count` | Same bounds with UInt64 counts: missing/null=0, array=length, other values=1 |
| `is_empty` | Boolean: missing/null/empty array are empty; empty string/object are not |
| `is_null` | Boolean: explicit null or an array containing null; missing matches only `false` |
| `geo_bounding_box` | `top_left`/`bottom_right` coordinates; strict borders and antimeridian handling |
| `geo_radius` | `center` and numeric `radius` in meters; strict distance less than radius |
| `geo_polygon` | Exterior ring and optional interior holes; boundaries are excluded |

Numeric ranges convert JSON numbers to Float64. A string range bound selects
datetime parsing for every bound; invalid query dates are rejected, invalid stored
dates do not match. Comparisons retain seconds and nanoseconds, including the
source leap-second representation; they do not use rounded formula scores.
Geo query coordinates are validated; stored points must be objects containing
numeric `lon` and `lat`, with the source's unchecked-coordinate evaluation.
Coordinate arrays are accepted for query points, not as stored geo objects.

Polygon filters use `{"geo_polygon": {"exterior": {"points": [...]},
"interiors": [{"points": [...]}]}}` inside a `field` node. Each ring must have at
least four points, including closure; points use `{"lon": x, "lat": y}` or
`[x, y]`. Omitted/null `interiors` means no holes. The first and last coordinate
may differ by at most Float64 EPSILON on each axis; accepted rings then close
exactly, following Qdrant and GeoRust. Exterior edges, hole edges and vertices
do not match. Coordinates use GeoRust's planar winding-number interpretation;
a polygon crossing longitude ±180 is not automatically wrapped. Ring direction,
degeneracy, self-intersections and holes outside/overlapping the exterior follow
the source algorithm; no extra topology validation or repair is added. Robust
adaptive orientation preserves the source decisions near collinear boundaries.

Within a single field node, source precedence is `values_count`, then `is_empty`,
then `is_null`; these override other properties. Otherwise match/range/geo checks
are alternatives. Use `all` to require multiple independent predicates. Ordinary
arrays use one-level any-element evaluation. Missing paths use the count/empty/null
rules above; they fail ordinary match/range/geo predicates.

These filters reach existing Python search/batches, named queries, universal
prefetch/formula conditions, Arrow queries/scans and HTTP search/payload updates.
Native callers construct `PayloadCondition(spec: PayloadValue)` and use
`FilterExpression.field`, `.nested` and `.at_least`. New predicates currently
evaluate authoritative payloads; dedicated typed indexes,
tokenizer/BM25/position-aware phrase search and full Qdrant REST/gRPC schemas remain
open. Unsupported properties and ambiguous match variants are rejected explicitly.

### Point identity, vector presence and whole-path conditions

The same filter trees also accept these independent nodes:

```python
{"kind": "has_id", "ids": [1, 42]}
{"kind": "has_vector", "name": "image"}
{"kind": "has_vector", "name": ""}  # default dense vector
{"kind": "has_vector", "field_id": 1}  # native unnamed sparse field
{"kind": "slice", "total": 8, "index": 3}
{"kind": "is_empty", "key": "items[].value"}
{"kind": "is_null", "key": "items[].value"}
```

`has_id` accepts native signed Int64 IDs; duplicates have no effect. UUIDs and
integers outside that range remain unsupported until the point-ID format work.
`has_vector` tests stored presence, including empty sparse/multivector values,
not whether a vector can contribute a search result. Unknown names return false.
Exactly one of `name` and the native UInt32 `field_id` selector is required.
Empty name selects default dense field 0; field 1 is the independent default
sparse field. Removing a vector changes current results while captured read
views retain the previous presence.

`slice` requires UInt32 `total > 0` and `0 <= index < total`. It uses Qdrant's
fixed zero-key SipHash-2-4 of the numeric ID's eight little-endian bytes, modulo
`total`. Native negative IDs use their two's-complement UInt64 bit pattern.
Slices for one total partition all live IDs, and totals with shared factors
produce correlated subsets. The hash does not depend on process, collection,
payload or vector updates. UUID byte hashing is tested against upstream but
does not enable UUID point storage or public UUID filters.

Standalone `is_empty` requires **every** value returned by the path to be null
or an empty array; a missing path matches. Standalone `is_null` requires at least
one returned value to be null; a missing path does not match. Neither implicitly
flattens a returned array. For `{"a": [null]}`, `is_null` on `a` is false and on
`a[]` is true. These are deliberately distinct from a `field` node's any-element
`is_empty` / `is_null` properties described above.

Inside `nested`, the point ID and vector storage context are absent, following
Qdrant: `has_id`, `has_vector` and `slice` are false for each nested object.
Negating those predicates is true within an existing nested object; a missing
or non-object nested array still cannot match.

Mojo callers use `FilterExpression.point(PointCondition(spec))`, `.is_empty`
and `.is_null`. Direct payload evaluation can take `PointFilterContext`; its
default has no ID or vectors. Payload-only `MetadataIndex` evaluation supplies
IDs but no vector storage. Collection/read-generation evaluators supply current
authoritative vector presence and the retained field catalog independently of
the unchanged payload-index cache. Search, scans, formula conditions, payload
mutations, Python/Arrow and existing HTTP routes share these semantics. These
native dictionaries do not claim complete Qdrant REST/gRPC schema compatibility.

### Rich document values

`PayloadField` now accepts `null`, `array`, `object` and `uint` in addition to
`string`, `int`, `float` and `bool`. Explicit scalar fields retain the existing
Python scalar conversion protocols, including integer input for `float`.
Nested container contents use strict JSON types; strings and booleans there
remain distinct from numbers. Mojo validates the new declared container types:

```python
collection.upsert(42, [1.0, 0.0], fields=[
    PayloadField("metadata", "object", {
        "authors": [{"name": "王", "verified": True}],
        "optional": None,
        "scores": [1, 2.5, None],
    }),
    PayloadField("reviewed", "null", None),
    PayloadField("counter", "uint", 2**64 - 1),
])
metadata = collection.get(42).fields[0].value
```

Reads return independent Python dict/list values; mutating the input or returned
containers cannot mutate stored data. Nested keys preserve insertion order and
may contain empty strings, NUL and Unicode. Top-level names remain nonempty,
NUL-free and unique. Native map construction replaces duplicate keys in their
original slot; Python dicts already have that property.

Payloads retain the 16 MiB encoded and 1,024 top-level-field limits, with at most
65,536 value nodes and 64 container levels per field. Cycles, excessive nesting,
nonfinite numbers, non-string object keys and integers outside Int64/UInt64 are
rejected before WAL append. Null differs from an absent field and from an empty
container. Rich values survive WAL-only reopen, checkpoint, physical backup and
NDJSON v3. Reads retain payload v1/v2 compatibility; new writes use payload v3.

### JSONB values

`JsonbValue(data: bytes)` carries the exact jsonb 0.5.6 databend body used by
the pinned Lance implementation. It accepts immutable bytes; Mojo validates
the body and combined payload limits before writing. The carrier itself does
not guarantee that arbitrary supplied bytes are valid. To parse text, use
`JsonbValue.from_json(text: str | bytes, *, standard: bool = False)`, which
delegates to the source-ported Mojo parser and returns a validated owned body.
The default extended profile matches pinned Lance. `standard=True` selects
jsonb's standard profile; its shared Unicode/whitespace behavior differs from
the ordinary serde_json reader. See [the exact profiles](native-jsonb.md#text-parsing).

```python
from akashadb import JsonbValue, PayloadField
from akashadb.payload import encode_value

json_null = JsonbValue(bytes.fromhex("2000000000000000"))
parsed = JsonbValue.from_json("{items:[1,,],n:0x1a.b}")
standard = JsonbValue.from_json(b'{"items":[1,null,null]}', standard=True)
print(parsed.to_json())
print(parsed.to_json(pretty=True))
fields = [PayloadField("items", "array", [None, json_null])]
collection.upsert(42, [1.0, 0.0], fields)
assert collection.get(42).fields == fields
collection.set_payload({"json_null": json_null}, points=[42])

# POST /collections/demo/points
body = {"id": 42, "vector": [1, 0], "fields": [f.to_wire() for f in fields]}
# POST /collections/demo/points/payload
update = {"points": [42], "encoding": "typed",
          "payload": {"items": encode_value([None, json_null])}}
```

JSONB null is present; plain null still follows the source mutation semantics
(for example, shallow `set_payload` removes a plain-null member). The carrier
also works in `PointMutation`, batches, nested objects and overwrite operations.
Reads return independently owned wrappers/containers. Body bytes survive WAL,
checkpoints, physical backup and logical export/import unchanged, including
accepted old JSONB encodings and nonfinite numbers inside the body.

`PayloadField.to_wire()` adds `encoding: "typed"` only if the field contains
JSONB; `typed=True` always selects it. `PayloadField.from_wire()` decodes an
explicit wire field. The HTTP API accepts these fields and uses the same shape
in GET results. Typed updates encode each payload member as a `{type, value}`
node. Normal JSON object keys such as `type`, `value` and `encoding` remain user
data. NDJSON v3 always uses typed fields, retaining v1/v2 reads. Ordinary nested
integers use the `integer` wire tag; explicit field roots retain int/uint.

`JsonbValue.to_json(*, pretty: bool = False) -> str` validates the binary body
and delegates compact/two-space pretty output to the native RawJsonb/serde
writer. Raw object key order is retained. This is a text projection: nonfinite
floats become null, decimals use source F64 conversion, and binary/date/time/
interval extensions become strings. Invalid calendar/offset values raise
`ValidationError`; formatting does not mutate the body. Escaping can expand
output beyond 16 MiB, so use `.data` or typed transport for lossless interchange.
See [text output contracts](native-jsonb.md#text-output).

`JsonbValue.query(path, *, mode="values", max_work=1_000_000,
max_results=65_536, max_bytes=67_108_864, cancellation=None, timeout_ns=None)`
executes the source JSONB path/expressions entirely in Mojo. Modes are `values`,
`array`, `first`, `value`, `exists`, and `predicate`. `value` returns one match
or wraps multiple matches in an array; `first` returns only the first match.
Missing first/value and unknown/nonpredicate predicate results return `None`;
JSON null remains a present `JsonbValue`. Both first and existence execute the
full source selection, preserving later errors and resource limits.

```python
value = JsonbValue.from_json('{items:[{price:3},{price:9},{price:7}]}')
assert value.query('$.items[*]?(@.price < 8)', mode="array").to_json() == '[{"price":3},{"price":7}]'
assert value.query('$.missing', mode="first") is None
```

Python provides UTF-8/byte transport and result wrappers; the native parser,
selector, numeric operations and limits are authoritative. `CancellationToken`
is sampled before the synchronous call; the deadline is checked during native
execution. See [query modes and resource contracts](native-jsonb.md#jsonb-value-queries).
The strict ordinary-JSON filter/formula configuration path does not accept a
JSONB carrier as configuration. The `kind="jsonb"` filter reads stored carriers
using source boolean operations; see [collection JSONB filters](native-jsonb.md#collection-jsonb-filters).
Computed JSONB projection and dedicated indexes remain
in progress; [wire format](formats/logical-point-format.md) specifies transport.

`JsonbValue.cast(target)` provides Mojo scalar conversion to `bool`, `int64`,
`uint64`, `float64` or `string`. Integer casts round ties away from zero; numeric
strings try exact integer parsing before floating conversion. Boolean casts
accept booleans and true/false/yes/no strings (ASCII case-insensitive), while
numeric 0/1 are invalid. String casts return unquoted text and use exact source
Number Display for numbers. Null, containers, extensions and invalid inputs
raise `ValidationError`; this is separate from nullable Lance get operations.

```python
assert JsonbValue.from_json('-1.5').cast('int64') == -2
assert JsonbValue.from_json('"YES"').cast('bool') is True
assert JsonbValue.from_json('"hello"').cast('string') == 'hello'
```

See [scalar cast contracts](native-jsonb.md#source-scalar-casts), including exact
integer limits, nonfinite values and differences from `to_json()`.

`akashadb.json_functions` provides source-backed Lance `json_path`,
`json_extract`, `json_extract_with_type`, `json_exists`, `json_get`, typed
`json_get_string/int/float/bool`, `json_array_contains`, and `json_array_length`.
Each accepts a scalar `JsonbValue`/None or a nullable Arrow LargeBinary array,
with Utf8/string argument broadcasting and native Mojo execution.

```python
from akashadb import json_functions as jf
value = JsonbValue.from_json('{items:[1,2],price:1.5}')
assert jf.json_extract(value, '$.items[*]') == '[1,2]'
assert jf.json_get_int(value, 'price') == 2
```

See [Lance function contracts](native-jsonb.md#lance-json-functions) for type
tags, null/missing, first versus multiple matches, array behavior, Arrow output,
ownership and bounds. This is value/Arrow execution; collection planner and SQL
integration remain pending.

Native `payload_value_get`, `payload_value_set` and `payload_value_remove` operate
on owned `PayloadValue` objects with `JsonPath`. They follow Qdrant source:
merge null deletes a key, indexed writes never grow an array, deleting an array
index does nothing, and a terminal wildcard clears its array. Collection-level
operations below use the same source semantics. Dedicated nested/array indexes and complete REST/gRPC/C
and distributed payload contracts remain tracked in D01–D05/A01–A03/X01–X04.
Typed Arrow projections require an explicit compatible scalar or nested schema.

### Payload mutations

`set_payload`, `overwrite_payload`, `delete_payload` and `clear_payload` modify
existing points without replacing any default, sparse or named vectors:

```python
collection.set_payload({"status": "reviewed"}, points=[42, 43])
collection.set_payload({"verified": True}, points=[42], key="metadata.authors[]")
collection.delete_payload(["metadata.obsolete", "metadata.authors[].draft"], points=[42])
collection.overwrite_payload({"reviewed": None}, points=[43])  # retains null
collection.clear_payload(filter={"kind": "condition", "name": "expired",
                                 "operator": "eq", "type": "bool", "value": True})
```

`set_payload` shallow-merges at the root or optional `key` JSON path; a source
null removes that map member. Overwrite replaces the entire payload and retains
null. Delete applies its paths in order; array index deletion remains a no-op,
while terminal `[]` empties that array. Quoted keys and wildcard traversal use
the shared source parser. Nested map patches allow empty/NUL keys; persisted
top-level keys retain their existing constraints. Document roots do not consume
one of the 64 allowed container levels per field.

Provide `points` or the existing native `filter` expression. When both are
provided, `points` takes precedence, including an empty list. Duplicate explicit
IDs select a point once; filter-selected points are ordered by ID. Missing or
deleted explicit IDs fail the whole operation. Selection, reading, modification
and commit share one native writer lock, so concurrent writes cannot land
between those stages. Existing snapshots retain their prior data.

Each call returns `BatchWriteResult`. `count` is selected unique points,
including existing points whose values did not change. A nonempty selection
commits one atomic point batch. An empty selection returns `first_sequence=0`,
unchanged `last_sequence` and `count=0`, without appending to the WAL. Both input
ID count and selected count are bounded by `min(limits.max_batch_rows, 65536)`;
delete accepts at most 1,024 paths. Resulting payload and WAL size limits still
apply, and validation finishes before append. Validation failures leave all
targets unchanged. I/O or post-commit publication failures require reopening
and recovery; an error after append is not proof that the batch was rolled back.

The native entry point is `PersistentCollection.apply_payload_update`, with
`PayloadUpdate.set(names, values, path)`, `.overwrite(names, values)`,
`.delete(paths)` or `.clear()`, and optional IDs or native filter. Python only
serializes these inputs. Native atomicity and row-sequence results differ from
Qdrant's internal chunk execution and operation acknowledgments; these methods
do not claim full Qdrant protocol compatibility.

The current HTTP service exposes POST/PUT `/collections/{name}/points/payload`
for set/overwrite, plus POST `.../payload/delete` and `.../payload/clear`.
Bodies use `payload`, `points`/`filter`, optional set `key`, or delete `keys`.
Responses are native batch results; filters use Akasha's existing expression
schema. Combined mixed-operation batches and full Qdrant REST/gRPC remain open.

`upsert_columns` validates column-shaped Python data and copies it through
Python values. It is not a zero-copy Arrow C Data interface.

`upsert_record_batch` imports a producer's Arrow C Data schema/array capsules
into a one-shot `ArrowBatchLease`, validates the complete schema and offsets,
and keeps the imported owner alive through the synchronous Mojo call. Primitive
buffers reach the compiled binding without an intermediate Python list.
Persistence still copies accepted values once into WAL/MemTable-owned memory.

Both `upsert_record_batch` and `upsert_point_record_batch` accept payload columns
of Arrow null, boolean, signed/unsigned integer (8/16/32/64 bits), floating
(16/32/64 bits), UTF-8/large UTF-8, struct, list/large list and fixed-size list.
Nested types compose. Signed integers become native Int64, unsigned integers
become UInt64, and floating values become finite Float64. Values in masked null
parents are ignored. Valid parents enforce their child fields' nullability.
Supplied null cells are stored as **explicit payload null**, including top-level
cells; older scalar ingress omitted these fields. An absent column is absent.
Every row is a whole-point upsert, and an invalid row rejects the complete batch.

Struct keys preserve declaration order. Arrow C Data names are NUL-terminated:
RecordBatch schemas containing NUL in a field name are rejected before exporting
capsules, preventing silent truncation. Empty nested struct keys and NUL inside
string **values** are supported. Other producers must supply valid C Data names.
Dictionary, union, unmarked binary payload, decimal, temporal and unknown
extension types are not accepted by this typed JSON adapter. Map and the
`arrow.json`/`lance.json` extensions use the contracts below. Payload depth/node/byte and encoded
size limits still apply. This imports typed values without retaining the input
table schema; it does not implement schema evolution or Lance files.

StringView (`pa.string_view()`) is also supported for payload input and output,
including nested/sliced arrays and multiple external data buffers. Mojo validates
active view lengths, zero inline padding, external buffer indices/ranges, prefixes
and UTF-8 before writes. Null parents retain the existing masking rules. String
values are copied into native durable ownership; the input physical layout is
not persisted. Output uses 16-byte views with inline data through 12 UTF-8 bytes,
otherwise owned external data and the Arrow C Data buffer-size trailer. All these
allocations share the scanner byte cap. The native raw vector datatypes are unchanged.

Typed scalar and nested output use the scanner schema described below.
`arrow.json` on UTF-8/large UTF-8/StringView and `lance.json` on LargeBinary
are supported in both ingress APIs and scanner projections. Text parses to
owned native JSONB; storage null and valid JSON null remain distinct. Binary
projection preserves original bytes; text projection follows RawJsonb formatting.
Nested Struct/List/Map fields, slicing, metadata, ownership and budgets use the
same native traversal. Maps retain ordered entry objects, duplicate/non-string
keys and `keys_sorted`; PyArrow C Data normalizes child names to key/value.
See [JSON extension examples and contracts](native-jsonb.md#arrow-json-interchange).
[Source fixtures](../tests/fixtures/rich-arrow/README.md).

`search_record_batch(collection, request)` runs any `SearchRequest` directly into
owned `int64` ID and `float32` score columns. It uses the same limits, filters,
errors and ordering as `Collection.search`, without staging Python result rows.
The native result list is copied once into NumPy columns (12 bytes per result),
which PyArrow retains without another data copy. Batches and slices remain valid
after collection close; the last Arrow owner releases the output buffers.

```python
from akashadb import SearchRequest, search_record_batch

batch = search_record_batch(
    collection, SearchRequest("cosine", 10, vector=query_vector)
)
selected = batch.slice(0, 5)
collection.close()
print(selected.column("id"))
```

`results_to_record_batch` remains available to convert existing Python
`SearchResult` sequences into an independently owned batch with the same schema.

Projected reads use `Collection.get(id, projection=Projection(...))`.
`include_vector=False` omits the embedding, `fields=None` selects every payload
field, and a tuple selects only named fields.

## Snapshot batch scanning

`scan_record_batches` captures one immutable view immediately. It yields PyArrow
RecordBatches in run/slot order, with at most `batch_size` rows each; batches do
not cross run boundaries. Later updates, deletes, flushes and collection close
do not change that view. Use a context manager when stopping before exhaustion:

```python
from akashadb import scan_record_batches

with scan_record_batches(
    collection,
    batch_size=1024,
    columns=("id", "vector"),
    payload_schema={"chunk": "string", "page": "int"},
) as scanner:
    print(scanner.schema)
    for batch in scanner:
        process_batch(batch)
    print(scanner.stats)
```

Core columns are `id` (I64), `sequence` (U64), `vector` (fixed-size F32 list),
`sparse_term_ids` (I64 list) and `sparse_weights` (F32 list). The default includes
all except sequence. A missing sparse field is null; present fields preserve
their ragged lengths. The existing writer rejects empty sparse vectors.

Payload remains schemaless in storage, so the caller specifies projected field
types as `string`, `int`, `float` or `bool`, or a real PyArrow `DataType` or `Field`.
Output names use the `payload.` prefix. Supported types match typed ingress above.
An explicit `Field` must have the same name as its mapping key; its nullability
and metadata are retained, including nested field metadata. The input table
schema/metadata are not persisted or inferred from stored values.
Missing fields and explicit null become Arrow null; a present non-null value with a different type raises and
closes the scanner. No preliminary whole-collection schema discovery occurs.
An empty `columns` projection is supported, including zero-column batches with
their row counts preserved. `filter` accepts the same expression dictionaries
as `SearchRequest.filter` and runs against the captured point state.

```python
import pyarrow as pa

with scan_record_batches(
    collection, columns=("id",),
    payload_schema={"document": pa.struct([
        pa.field("title", pa.string(), nullable=False),
        pa.field("tags", pa.list_(pa.string())),
        pa.field("count", pa.uint64()),
    ])},
) as scanner:
    for batch in scanner:
        process_batch(batch)
```

A struct projection emits only its declared keys, in declaration order. A null
parent masks its required children; an active parent with a missing/null required
child fails. Fixed-size lists require the declared number of elements. List
nulls, empty lists, null elements and empty structs remain distinct.
Signed integer, unsigned integer, floating, Boolean and string families are
strict: projection does not implicitly convert between them. Integer narrowing
checks bounds. Floating narrowing follows the pinned Arrow cast behavior:
F16 first rounds through F32, then to F16; F32 rounds directly from F64. Results
that become nonfinite raise rather than returning Infinity. This finite-value
rule is Akasha's numeric contract, not a claim that Arrow rejects Infinity.
NUL field names, duplicate struct names and extension types are rejected.

One-row dense vectors borrow their immutable native buffer and retain its read
generation through a real Arrow C Data release callback. Multi-row vectors and
ID, sequence, sparse and payload columns are gathered directly into final native
buffers. Owned columns retain no generation pin. Arrow handles schema and capsule
exports; no raw addresses appear in this public API. Batches, child columns and
slices survive scanner and collection close. The last borrowed consumer releases
its generation and can reclaim retired files, including from another thread.

`cancellation=CancellationToken()` is checked between Python batch calls. Native
scan and export loops also check `deadline_ns` (absolute monotonic nanoseconds,
zero disables) cooperatively. `max_candidates` defaults to the collection's query
limit and bounds total visited physical slots, including filtered/tombstoned
slots. `max_batch_bytes` defaults to 64 MiB and caps aligned output buffer
allocations; exceeding it closes the scanner with an error. Reduce batch size
for large payloads. The byte limit excludes retained source generations,
selection descriptors and Arrow metadata. A cursor has one consumer; separate
cursors can retain independent snapshots.

Nested buffers share the same output allocation cap. Typed payload traversal is
also bounded to `max(1024, max_batch_bytes // 32)` logical cell descriptors per
payload column/batch on the supported 64-bit ABI, including masked fixed-list
children. This bounds null-only expansions even when they need no value buffer.
Reducing batch size or the projected nesting/width reduces that work. The byte
cap and traversal bound are not process RSS limits.

`stats` counts returned rows/batches, visited slots, logical materialized buffer
bytes (including offsets and validity, excluding allocation padding) and borrowed
bytes. These are not process RSS or a claim of zero-copy multi-row storage. The
[scanner measurements](benchmarks/2026-09-30-arrow-scanner.md) include RSS and
explicitly account for the different ownership paths.
# Native named vectors and atomic point batches

`export_ndjson` / `import_ndjson` preserve complete typed point states with the
[versioned logical format](formats/logical-point-format.md), including points
without a default dense vector. Import into a collection created with the same
`config` and `vectors`; all imported fields commit as one point batch. Missing
fields clear the corresponding values on overwritten IDs. Legacy unversioned
document imports remain supported. Physical backups also preserve the catalog.

Pass `vectors={name: VectorField(...)}` when creating or migrating a collection.
Every new collection uses the point format; omitting `vectors` creates only the
reserved default dense and sparse fields, just like `vectors={}`. Existing legacy
collections migrate on their first open. Reopening without `vectors` loads its
persisted catalog; an
explicit different catalog is rejected. The catalog is immutable after cutover.

```python
from akashadb import Collection, PointMutation, VectorField

db = Collection("example", 2, vectors={
    "image": VectorField(3, dtype="f16", metric="cosine"),
    "tokens": VectorField(2, dtype="bf16", kind="multivector", metric="dot"),
    "bits": VectorField(9, dtype="binary", kind="binary", metric="hamming"),
})
db.apply_point_batch([PointMutation.upsert(
    1, vector=[1, 2], vectors={"image": [1, 2, 3], "tokens": [[1, 0], [0, 1]]},
)])
hits = db.search_field("image", [1, 2, 3], 10)
point = db.get_point(1)
db.close()
```

`upsert` replaces or creates the entire point: omitted vectors are removed and
`fields=None` becomes an empty payload. `update` requires an existing live point
and preserves omitted vectors and payload. `delete` removes the whole point. A
vector value of `None` removes that field, and `fields=[]` clears the payload. Empty sparse vectors and zero-row multivectors remain present. Cosine accepts zero vectors and queries; either zero operand produces similarity 0. A batch
validates every mutation before writing one WAL envelope; no accepted prefix is
visible on a validation error. NumPy inputs are copied into independently owned
native buffers. Integer inputs must be integral and in range; numeric authority
must be finite after conversion. Reads return owned lists/bytes.

`Point.sequence` covers every point mutation. `Point.document_sequence` tracks
the default dense/payload projection and is zero if the default vector is absent.
Named-only points participate in named search and point scans, but not default
dense queries. Named search defaults to native exact kernels with Float64 results.
Dense and multivector accumulation uses Float64, except F16 cosine. F16 cosine
normalizes native half inputs in Float32, rounds normalized components to half,
then accumulates their dot product in Float32, following Qdrant's half metric.
Zero and near-unit squared lengths use Qdrant's preprocessing thresholds.
Raw stored vectors are retained; the comparison to Qdrant uses these canonical
half inputs, since Qdrant otherwise normalizes the original Float32 ingestion
values before storing half values. MaxSim sums the row scores in Float64.
Sparse accumulation uses Float32. Dense fields configured with `VectorField(hnsw=...)` also
accept `mode="approx"`, `ef_search`, and `rerank_k`. Each field uses its own
dimension, metric and graph encoding; candidates are reranked from native
authoritative values into Float64 scores. `rerank_k=0` uses `max(k, ef_search)`;
an explicit value must be at least k and bounds the number reranked. Both ef and
the candidate budget must fit that field's configured `max_ef_search`. Exact mode
rejects ANN-only options. Binary and multivector fields use their exact kernels.

Graphs are built lazily outside the writer lock and shared by queries/snapshots
of the same immutable root. Updates and reopen acquire a new root and build new
named-field graphs on first use; named graphs currently have no durable sidecar.
The persisted default HNSW graph has its separate retained-base recovery path.

Approximate dense dispatch uses the available vector population and filtered
cardinality, rather than `k`, `ef_search`, or an empirical scan-cost estimate.
Collections with fewer than 64 available vectors use exact search; a filter
matching fewer than `max(1, available_vectors // 8)` vectors also uses exact
search. The same threshold controls supplementary payload graph construction.
These are Akasha tuning values, not Qdrant's default byte-budget setting. An
exact cardinality at the threshold takes the graph path deterministically.

`last_search_stats()` reports the field path, graph encoding, traversal and native
rerank counts, including any exact fallback after exhausted filtered search.
For default segmented ANN, `distance_evaluations` counts preliminary graph/delta
scoring, while `reranked_candidates` counts authoritative scoring afterward.
A delta scan whose admitted IDs all fit its candidate breadth skips preliminary
scoring, so zero preliminary distances can accompany a nonzero rerank count.
Planned exact scans count their scoring in `distance_evaluations`; in that path,
`reranked_candidates` reports retained hits and must not be added as extra
scoring work.
Named search accepts `timeout_ns` and `cancellation`, and enforces
`limits.max_candidates` against the captured visible point count. Native builds
check cancellation/deadlines between rows and before publication; graph search
checks before/after its bounded traversal. Python cancellation is sampled at entry
to the synchronous call, as in `search_controlled`.

Named and default sparse fields share root-owned inverted postings and the
source-derived Qdrant search paths. Products round to Float32 before addition,
in ascending query-term order. `mode="exact"` and `mode="approx"` select the same
sparse dispatch; HNSW-only `ef_search` / `rerank_k` remain invalid. Without a
filter, search uses indexed batches. With a filter, source-ID exclusion or
rerank candidate-ID restriction, fewer than 5000 admitted vectors select plain
search; at 5000 the indexed path is used. Akasha uses exact admitted counts,
not Qdrant's cardinality estimate; configurable thresholds and IDF remain open.

Indexed batches omit zero scores, while plain search and the single-posting
tail may retain overlapping zero scores. Empty queries and no-overlap rows do
not produce hits. Negative scores remain valid. The source's TopK threshold
omits NaN, negative overflow and exactly `f32::MIN`; positive overflow can be
returned by ordinary sparse search. Recommendation queries retain their
separate finite-result validation. Sparse reranking applies the same search
with the candidate IDs as an additional filter; it cannot introduce points
outside that candidate set. Stats report `field_sparse_empty`,
`field_sparse_plain` or `field_sparse_indexed`.

Dense fields also support `mode="ivf", ivf=IvfOptions(nlist=32, nprobe=4,
iterations=8)`. Import `IvfOptions` from `akashadb`; these are the defaults when
IVF mode omits options. IVF uses deterministic L2 coarse partitions, then scores
selected rows with the field's native score contract above, returning Float64.
`nlist` is 1–256, `nprobe` is 1–`nlist`, and training iterations must be positive;
all three require integers. Effective lists are limited to present field rows,
and probes are clamped to that count. Probing every list equals exact search.
With fewer probes, filters may leave fewer than k results: IVF does not expand
the probe budget automatically. HNSW ef/rerank controls cannot be combined with IVF.

IVF builds on first use per immutable root and `(field, nlist, iterations)`;
changing probes, k or filters reuses the index. It retains centroids and membership,
not a second vector corpus. Writes/reopen cause a new build on first use, and no
IVF sidecar is persisted. Training uses a temporary Float32 projection for all
five dense dtypes; original native values remain authoritative for scoring.
Cancellation, deadlines and candidate limits apply as for named search.
`last_search_stats()` exposes `ivf_partitions`, `ivf_probed_partitions`, visited
rows and native rerank counts. Arrow search and `FieldQuery(..., mode="ivf",
ivf=...)` accept the same options.

`search_field_by_id(name, id, k, ...)` queries a named field using a vector
already stored in a point. Lookup and search use one captured read root, and the
source point ID is excluded **before** Top-K / HNSW admission / IVF scoring.
Excluding the source does not consume a result slot. HNSW can still traverse an
excluded vertex. Payload filters constrain results, not source-vector lookup.
The method accepts the same exact/approx/IVF controls, filters, deadlines and
candidate limits as `search_field`.

```python
hits = collection.search_field_by_id("text", 42, 10)
hits = collection.search_field_by_id(
    "text", 42, 10, lookup_from=examples, lookup_field="reference",
)
```

`lookup_from` is another open `Collection`; omission or explicit self lookup
uses the searched collection's single root. `lookup_field` defaults to the
searched field's name. With a different collection, coincident IDs remain
eligible in the searched collection. Its source view is captured independently;
this does not create a cross-collection transaction. Native `ReadSnapshot` and
`PersistentCollection` expose `search_field_by_id(..., lookup=source_snapshot)`.
Explicit native snapshots can retain older source values across mutation/close.
Same-collection identity across reopen is checked using canonical directory paths.

Lookup supports all existing native vector kinds and scalar types under the
current typed-query contract: source kind, dimension and scalar must match the
target field. Missing/deleted points, missing vector fields and incompatible
types are errors. Empty sparse source vectors return no hits; empty multivector
queries are rejected. Query values remain native owners and are never passed
through Python lists. Stored values retain Akasha's existing raw-vector semantics;
Qdrant storage preprocessing and cross-datatype conversion require their separate
compatibility work. Reference selection/exclusion is source-ported; this API
does not claim complete Qdrant Query API compatibility.

`akashadb.arrow.search_field_by_id_record_batch` accepts the same options and
returns owned Int64 ID / Float64 score columns that survive collection close.
See [source reference cases](../tests/fixtures/qdrant-point-lookup/README.md).

`search_fields([FieldQuery(name, vector, mode="exact", ...), ...], k,
fetch_k=100, rank_constant=2, filter=...)` fuses rankings from one captured read
root. Each branch retrieves at most `fetch_k` results using that field's metric
and selected exact/approximate/IVF mode. RRF adds `1 / (rank_constant + rank)` for each
branch, with ranks starting at zero and contributions/sums in Float32, and breaks ties by
ascending point ID. Duplicate field names are allowed for different queries.
Filters apply to every branch before its Top-K. The aggregate candidate limit
counts the captured visible point count once per branch. `search_fields_record_batch`
offers the same options and directly exports owned Int64/Float64 columns.

Pass `weights=[3.0, 1.0, ...]` to set an RRF weight for each branch in query
order. The list must match the branch count; `None` means all weights are 1.
Qdrant's F32 contribution is `1 / ((rank + 1) / weight + rank_constant - 1)`
for positive weights. This adjusts the rank before taking its reciprocal;
it is not multiplication of the unweighted score. Zero and negative weights
contribute zero but retain their returned IDs, including in final rerank
candidate selection. All branches still run and count against resource limits.
Weights must be finite after F32 conversion. Nonfinite fused results are rejected,
including overflow caused by very large positive weights at `rank_constant=1`.
`weights` is supported only with `fusion="rrf"`; DBSF rejects an explicit list.
Arrow accepts the same `weights` keyword. The unchanged legacy hybrid search
entry points use equal weights; use named `FieldQuery` branches for weighted fusion.

```python
hits = collection.search_fields(
    [FieldQuery("text", text_vector), FieldQuery("image", image_vector)],
    10,
    fetch_k=100,
    weights=[3.0, 1.0],
)
```

Source and bit-exact fixtures: [weighted RRF port](../tests/fixtures/qdrant-rrf/README.md).

Pass `fusion="dbsf"` to use Qdrant distribution-based score fusion instead of
the default `fusion="rrf"`. DBSF converts each branch's returned scores to F32,
normalizes them with sample variance and `mean +/- 3 * standard_deviation`, then
sums contributions for matching IDs in branch order. Empty branches contribute
nothing; singleton and constant branches contribute 0.5 per result. Scores are
not clamped to [0, 1]. Nonfinite inputs or normalization/aggregation overflow
raise a validation error. This is a finite-range adaptation of the upstream port.

DBSF uses the branch's returned score units directly, as Qdrant's score-fusion
function does. It does not invert L2/Hamming/Jaccard distances; callers should
choose similarity-scored branches when larger values should contribute more.
Fused scores sort descending with ascending point-ID ties. `rank_constant` is
still validated as a positive integer but only affects RRF. `fetch_k`, filters,
candidate budgets, cancellation and optional final-field reranking apply to both
modes. `search_fields_record_batch(..., fusion="dbsf")` exposes the same native
path; HTTP's existing default-vector search route does not yet expose this API.

```python
hits = collection.search_fields(
    [FieldQuery("text", text_vector), FieldQuery("image", image_vector)],
    10,
    fetch_k=100,
    fusion="dbsf",
)
```

Source and native fixtures: [DBSF port](../tests/fixtures/qdrant-dbsf/README.md).

Pass `rerank=FieldQuery("tokens", query_matrix)` to score a bounded candidate set
with another field. Each first-stage branch retrieves `fetch_k` hits, RRF selects
at most `fetch_k` unique IDs, and the final exact field query returns the best k
of those candidates. Both stages use the same captured read root. This supports
dense/sparse retrieval followed by native MaxSim or packed Hamming/Jaccard scoring,
and works with all existing native final-field kinds and metrics. Rerank queries
must use exact mode; candidate branches may use exact, HNSW or IVF.

Results contain the final field's Float64 scores in its metric direction, with
ascending IDs for ties. Missing final fields and empty document multivectors are
excluded. Filters apply before candidate selection. A limited candidate set can
return fewer than k; no full-corpus expansion occurs. Increasing `fetch_k` changes
candidate recall and work, not the final scoring formula. The aggregate candidate
limit includes another `min(fetch_k, visible_points)` for reranking. Cancellation
and deadlines are checked during both stages. Final stats use `field-rerank`,
`base_candidates` counts the selected input IDs, `reranked_candidates` counts
final scores, and `retained_candidates` counts returned hits. Distance evaluations
remain aggregate across stages. `search_fields_record_batch` accepts the same
`rerank` argument and exports final scores directly.

`akashadb.arrow.upsert_point_record_batch` accepts `id`, optional `vector` and
`sparse`, `vectors.<name>`, and `payload.<name>` columns, returning a
`BatchWriteResult`. Each row replaces the whole point: omitted columns and null
vector values remove fields. Payload columns replace the payload; omitting all
payload columns clears it. The complete Arrow batch commits atomically. Producer buffers must remain
unchanged during the synchronous call and may be released after it returns.

`scan_record_batches(..., vectors=("image", "tokens"))` projects named fields as
nullable Arrow columns. Numeric dense fields use fixed-size lists, multivectors
use lists of fixed-size lists, binary fields use fixed-size bytes, and sparse
fields use `list<struct<term_id: int64, weight: float32>>`. F16/F32/I8/U8 retain
their Arrow primitive types. BF16 uses UInt16 **bit patterns** with field metadata
`akashadb.dtype=bf16`; importing BF16 without that metadata is rejected. Scans
support `document_sequence` alongside the point `sequence`. Single-row numeric
and binary buffers retain the captured generation through Arrow C Data ownership;
gathered buffers have independent ownership, and slices survive scanner/collection
close. `search_field_record_batch` accepts the same search options and emits owned
Int64 IDs and Float64 scores.

### Qdrant behavior migration

All upserts replace whole points (including omitted fields and payload),
sparse searches use the path-specific zero rules above, and RRF defaults to
constant 2 with zero-based ranks and Float32 accumulation. Use `PointMutation.update` for partial
changes. Older WAL v4 is replayed with its historical merge semantics; new writes
use WAL v5. Complete point checkpoints use Segment v5, which permits zero sparse
weights; existing Segment v4 remains readable with its original validation.
`upsert_sparse` accepts empty vectors and zero weights and updates only that field.
Default collection opens also perform the catalog migration, so supply any named
fields on that first open. See the
[field envelope contract](formats/field-envelopes-format.md) for upgrade behavior.


## MMR diversity selection

Named nearest search accepts optional native MMR selection:

```python
from akashadb import MmrOptions

hits = db.search_field(
    "image", query, 10,
    mmr=MmrOptions(diversity=0.5, candidates_limit=100),
)
```

`search_field_by_id`, `search_field_record_batch`, and
`search_field_by_id_record_batch` accept the same `mmr` option. Candidate retrieval
can use exact, HNSW or IVF, with their existing field/mode restrictions. Filters
and same-collection source-ID exclusions apply before candidate selection. Lookup,
retrieval and MMR retain their read roots through the operation.

`diversity` defaults to 0.5; 0 favors relevance and 1 favors diversity. The source
always chooses the most relevant first candidate. `candidates_limit=None` uses
`k`, explicit values range from 0 to 16384, and Python also enforces
`ResourceLimits.max_k`. Zero candidates returns no results; fewer candidates than
`k` returns fewer results. Native named search retains its positive-k contract.
When HNSW `rerank_k` is set, it must cover the effective candidate limit.

MMR follows Qdrant's F32 selection and volatile dense/sparse/MaxSim scoring. Ties
choose the last entry in the source insertion/swap-removal order. Returned scores
are the **original native candidate scores**, not MMR selection scores; result
order therefore need not be sorted by score. Native L2 candidate scores remain
squared distances. Binary MMR is rejected. Native BF16/I8 and low-precision fields
are accepted through the existing typed boundary, but full Qdrant datatype and
canonical-storage equivalence remains an open gate.

`max_candidates` additionally bounds the conservative visible-row count plus
MMR relevance scores and newly computed ordered pair scores. Cancellation and
deadlines are checked between candidates/pair evaluations and during selection.
Stats report `field_mmr`, `qdrant-mmr-f32`, candidate counts and aggregate distance
evaluations. MMR outputs own their result buffers, including Arrow after close.
Nested prefetch/fusion MMR and Qdrant-compatible REST/gRPC are not exposed yet.

## Discovery and context queries

`Collection.discover_field(name, target=None, context=None, k=10, *, mode="exact",
ef_search=None, lookup_from=None, lookup_field=None, filter=None,
cancellation=None, timeout_ns=None)` runs Qdrant-derived discovery/context in Mojo:

```python
from akashadb import ContextPair

hits = db.discover_field(
    "image", target=[0.2, 0.8, 0.1],
    context=[ContextPair(positive=42, negative=19)], k=10,
)
zone = db.discover_field("image", context=[ContextPair(42, 19)], k=10)
```

Each target/positive/negative is a raw vector or integer point ID. IDs resolve
from `lookup_from` (default: this collection), using `lookup_field` (default:
the searched field); every referenced ID in the target collection is excluded
before selection. An external lookup with a colliding ID does not exclude the
target point. Input kind/dimension, stored-source preprocessing and target
datatype conversion follow the shared recommendation preparation path.

With a target, each pair contributes `-1`, `0` or `1` according to Rust
`f32::total_cmp` of its positive/negative similarities. The final F32 score is
the sum of those ranks plus `0.5 * (s / (1 + abs(s)) + 1)` for target similarity
`s`. Without a target, each pair contributes `d / (1 + abs(d))`, where
`d = min(positive_similarity - negative_similarity - f32::EPSILON, 0)`;
the final score sums these losses. L2 similarities are negative squared
distances and these composite scores receive no distance postprocessing.

Dot/cosine signed zeros follow the portable source metric; `-0` and `+0` can
produce different discovery ranks. Finite inputs may overflow during scoring.
Source-defined NaN final scores rank above finite scores and remain NaN in the
returned Float64/Arrow score (not null). NaN payload bits are not a public
contract. Equal final scores use Akasha's ascending point-ID order.

Dense `mode="approx"` requires configured HNSW. Target discovery first searches
context for up to ten entry candidates, then traverses with the full discovery
score from the highest-level eligible candidate, taking the last level tie.
Context-only uses one custom traversal. The native exact/planner fallbacks and
HNSW graph lineage still apply; this is not graph-identical Qdrant traversal or
a recall/performance acceptance. Sparse custom queries score all eligible
vectors in either mode, including zero/nonoverlap. Multivector MaxSim supports
exact queries; multivector HNSW and binary discovery are unavailable.

`k=0` returns empty before query/lookup/filter resolution, while still requiring
an open target collection. Otherwise a target or at least one complete pair is
required. `max_query_batch` counts one target plus two examples per pair;
`max_k`, visible-candidate budget, cancellation and deadlines apply. Dense ANN
`ef_search` must be positive and within its configured maximum; the source's
context entry search requires breadth of at least ten when ten candidates exist.

`discover_field_record_batch` in `akashadb.arrow` takes the same arguments and
owns its `id: int64` and `score: float64` columns. Native collection/snapshot APIs
accept `Optional[RecommendationExample]` and `List[ContextPair]`; the existing
`RecommendationExample.point/raw` is the shared vector-or-ID input. Captured
target and lookup snapshots remain usable after writer close.
Stats use `discovery_*` / `context_*` planner reasons and
`qdrant-discovery-f32` / `qdrant-context-f32` backends, counting both graph
stages' work. Queries appear in collection telemetry.

Universal/nested prefetch, batch discovery, offsets/projections and Qdrant
REST/gRPC/C ABI exposure remain pending, along with full low-precision
canonical-storage and SIMD/source-planner parity.

## Recommendation queries

`Collection.recommend_field(name, positive, negative=None, k=10, *,
strategy="average_vector", mode="exact", ef_search=None, lookup_from=None, lookup_field=None,
filter=None, cancellation=None, timeout_ns=None)` executes all three Qdrant
recommendation strategies in Mojo. Each example is an integer point ID or a raw
vector matching the target field's kind/dimension; IDs resolve from the selected
lookup collection and field. Raw numeric inputs become F32 query values before
preprocessing and conversion to the target datatype. Source IDs are excluded
before Top-K only when lookup identifies the target collection. Both positive
and negative IDs are excluded; repeated examples still contribute repeatedly.

```python
hits = db.recommend_field(
    "image", positive=[42, [0.2, 0.8, 0.1]], negative=[19],
    k=10, strategy="best_score",
)
```

- `average_vector` requires a positive example. Dense/sparse values are averaged
  in F32, then combined as `positive + positive - negative` when negatives exist.
  Sparse terms use a sorted union with zero for missing values. Multivector
  inputs concatenate positive rows and append negated negative rows.
- `best_score` chooses the largest similarity in each set; a tie chooses the
  negative set. The selected score passes through Qdrant's signed scaled fast
  sigmoid. Positive-only and negative-only requests are valid.
- `sum_scores` separately accumulates all positive and all negative similarities
  in F32 and subtracts the totals. Positive-only and negative-only are valid.

Dot/cosine use higher-is-better internal similarity. Custom L2 scores use
**negative squared distance** before the best/sum reduction. Only average-vector
results apply Qdrant's final Euclidean square root, so their public L2 units
are distance, unlike Akasha's existing `search_field` squared-L2 contract.
Scores are F32 values exported through the native Float64 result columns.
Ties keep Akasha's ascending ID ordering. Sparse average queries follow the
path-specific zero rules below; sparse custom queries include zero/nonoverlap results. Missing fields,
empty stored multivectors and excluded IDs never occupy a result slot.

`recommend_field_record_batch` in `akashadb.arrow` exposes the same options and
returns owned `id: int64` and `score: float64` columns. Native `ReadSnapshot` and
`PersistentCollection` expose `recommend_field` using `RecommendationExample.point`
and `.raw`; a native lookup snapshot can outlive its source writer. Recommendations count as
queries in collection telemetry. `max_query_batch` bounds the total examples;
`max_k`, `max_candidates`, cancellation and deadlines apply. Nonfinite results
are rejected. Binary recommendation is unsupported by the upstream strategies.

For dense fields, `mode="approx"` requires configured HNSW. All three strategies
score each visited candidate with the same prepared query used by exact search;
best/sum do not substitute a single averaged query. `ef_search` defaults to the
field's configured search breadth and must be positive and within its maximum.
It is invalid in exact mode. Native APIs use `approximate=True, ef_search=...`.
Filtering, same-collection source exclusion and shadowed-row visibility apply
before candidates enter graph traversal. Candidates use the native stored field
values even when the graph uses another scalar representation.

Stats identify `recommendation_hnsw`, `recommendation_exact`, or a documented
planner fallback (`recommendation_small_collection`, `recommendation_selectivity`,
`recommendation_ann_exhausted`). An empty eligible set reports
`recommendation_empty`; the backend is `qdrant-recommendation-f32`. Custom-score
distance counts include each positive/negative example similarity. A small or
selective dataset uses exact search; insufficient graph results also trigger an
explicit exact fallback. A full result count does not guarantee exact recall.
The repeated-vector quality diagnostic remains open even at high ef; see the
[ANN validation and limitation](research/2026-10-30-recommendation-ann-validation.md).

Sparse fields use the same source execution for `mode="exact"` and
`mode="approx"`: Qdrant's sparse index does not use the `exact` search parameter.

- `average_vector` searches retained postings. With a filter or same-collection
  example exclusions and fewer than 5000 eligible vectors, it uses the plain
  postings path; otherwise it uses batched indexed search. These are exact
  sparse algorithms, not HNSW ANN. `ef_search` is invalid for sparse fields.
- Batched indexed search omits zero sums. Plain postings search and the final
  single-posting tail can include zero scores for overlapping terms, exactly
  as in the pinned source. Empty queries and rows with no overlapping terms
  produce no nearest results. The blanket rule "sparse nearest never returns
  zero" does not describe all upstream execution paths.
- `best_score` and `sum_scores` scan all eligible vectors with the actual
  composite scorer, including zero/nonoverlap scores. This is the source's
  intended custom-query execution, not an ANN fallback.

Stats identify `recommendation_sparse_indexed`, `recommendation_sparse_plain`,
`recommendation_sparse_empty`, or `recommendation_sparse_scored`. The first
three use `field-postings`; custom scoring uses `field-flat`. Filter/exclusion
visibility is retained, and owned Arrow results survive close. Native sparse
planning currently uses exact eligible counts and the upstream default threshold;
configurable thresholds, IDF and full source planner/service parity remain open.
Ordinary nearest, default/hybrid and candidate-rerank APIs now share this source
dispatch. Sparse recommendation has no alternate flat average path. See
[shared sparse validation](research/2026-10-30-sparse-nearest-validation.md).

Multivector HNSW recommendation and universal REST/gRPC/C exposure remain
required work. F32 scalar
pipelines have independent upstream fixtures. Native F16/U8 conversion and
Akasha BF16/I8 extensions have regression coverage but not a full upstream
cross-datatype oracle yet. Integer metric accumulation is widened to Int64.
Akasha retains raw typed authority: recommendation reconstructs cosine's stored
representation from those native values. For low-precision fields, this cannot
recover the original pre-ingestion F32 input; full canonical storage alignment
requires the separate Q02/Q06 audit/migration. No existing stored values change.

Source and verification: [recommendation port](plans/2026-10-30-recommendation-source-port.md)
and [exact validation](research/2026-10-30-recommendation-validation.md).


## Universal query trees and nested prefetch

`Collection.query(QueryRequest(...))` runs all branches on one captured native
read root. The Mojo planner resolves every point-ID example before retrieval,
propagates ancestor filters, and evaluates ordered prefetches before rescoring.
Python only serializes the tree and passes retained lookup owners.

```python
from akashadb import QueryRequest, MmrOptions
from akashadb.arrow import query_record_batch

branches = (
    QueryRequest("nearest", "image", target=image_embedding, limit=40),
    QueryRequest("nearest", "text", target=text_embedding, limit=40),
)
fused = QueryRequest("rrf", prefetch=branches, limit=10, rank_constant=2)
hits = collection.query(fused)
batch = query_record_batch(collection, fused)

# Restrict nearest rescoring to the union of the prefetch IDs.
reranked = QueryRequest(
    "nearest", "text", target=text_embedding, prefetch=branches,
    limit=10, mmr=MmrOptions(diversity=0.5, candidates_limit=30),
)
hits = collection.query(reranked)
```

Supported `kind` values are `nearest`, `recommend`, `discover`, `context`,
`rrf`, `dbsf`, and `scroll`. `using=""` selects the default dense field.
Nearest uses `target`; recommendation uses `positive`, `negative`, and
`strategy` (`average_vector`, `best_score`, `sum_scores`). Discovery has a
`target` plus parallel `positive`/`negative` context sequences; context-only
omits `target` and requires at least one pair. Examples are raw vectors or
integer point IDs. `lookup_from` and `lookup_field` apply independently at each
node. A lookup field may be `""` for the source's default dense vector.

All IDs referenced on the target collection are excluded from **every** branch,
including siblings. External source IDs are not excluded from target results.
Explicit `lookup_from=collection` uses the target root. External lookup owners
are retained once per request, after conversions finish; this is not an atomic
cross-collection snapshot or transaction. Native `ReadSnapshot.query` can retain
explicit older target and source roots across updates and collection close.

Each node has its own `limit` (positive), `filter`, and `score_threshold`.
Only the root accepts `offset`; its retrieval limit is `limit + offset`.
Child limits are not automatically expanded. Parent filters run before child
Top-K selection. Nearest/recommendation/discovery with prefetch rescore the
**union** of candidate IDs, not an intersection or a fresh collection-wide
search. An empty union stays empty. Dense HNSW uses `mode="approx"` and optional
`ef_search`; sparse execution uses the existing source-derived sparse dispatcher.
Multivector queries support exact scoring. Binary queries and IVF are not yet
part of this universal API; their existing field APIs remain available.

`rrf` accepts `rank_constant` and optional ordered `weights`. Qdrant weights
compress/stretch ranks: `1 / ((position + 1) / weight + k - 1)` for zero-based
positions. Nonpositive weights contribute zero while retaining their points.
`dbsf` applies the existing source-derived distribution normalization. These
paths retain native finite-score validation and stable ascending-ID ties;
Qdrant's fusion tie ordering is not specified. Scores are source F32 values
returned in Float64 result columns. Nearest/average-recommendation L2 returns
Euclidean distance, unlike the older native `search_l2` squared-distance API.

The pinned Qdrant MMR stage rules are preserved:

- Root MMR first retrieves/rescores nearest candidates, applies its threshold,
  selects the original request `limit`, then applies `offset`. Thus a nonzero
  offset can leave fewer than `limit` results.
- Nested MMR with children directly selects from their ordered results,
  preserving the first occurrence's score. Its `candidates_limit` and threshold
  do not prune that intermediate input.
- A leaf prefetch carrying MMR returns nearest `candidates_limit` candidates;
  it does not itself run MMR selection. The default candidate count is that
  node's original `limit`, excluding the root offset.
- MMR keeps its selection order and original scores. Equal relevance uses
  the source's last-candidate tie rule, including at maximum diversity.

`QueryRequest()` performs ID-ordered no-vector retrieval, returning `SearchResult`
values with score zero. This is a bounded query, not a complete scroll-cursor or
payload-projection API. `query_record_batch` returns owned `id: int64` and
`score: float64` arrays that survive collection close.

`max_query_batch` bounds both tree nodes and the total number of vector/ID
examples. Maximum prefetch depth is 64. Every `limit + offset` and MMR candidate
count must fit `max_k`. One `max_candidates` budget covers the entire plan:
vector/scroll nodes charge the visible row count, fusion/nested MMR charge their
input lengths, and MMR relevance/matrix scoring consumes additional work.
Cancellation and deadlines are checked during native preparation and execution.
Native arena input rejects shared children, cycles, forward links, and
unreachable nodes; Python serializes repeated subtree objects as distinct tree
occurrences and rejects ancestor cycles.

This is a native universal-query slice, not full Qdrant REST/gRPC compatibility.
Order-by, complete formulas, sampling, feedback, batch/projections, full datatype/storage
parity, and multivector HNSW remain in the feature ledger. The existing graph
quality/performance failures remain open. See the
[query validation record](research/2026-10-30-universal-query-validation.md).

## Numeric formulas over prefetched candidates

`Formula` is a data-only expression wrapper. Parsing, planning, numeric evaluation,
payload access, condition checks and Top-K execute in Mojo:

```python
from akashadb import Formula, QueryRequest
from akashadb.arrow import query_record_batch

request = QueryRequest(
    "formula",
    prefetch=(QueryRequest("nearest", "text", target=query_vector, limit=100),),
    formula=Formula(
        {"sum": ["$score", {"mult": [0.2, "importance"]}]},
        defaults={"importance": 0},
    ),
    limit=10,
)
hits = collection.query(request)
batch = query_record_batch(collection, request)
```

The supported Qdrant numeric expression shapes are:

- A number is an F32 constant, promoted to F64 for evaluation. A string selects
  `$score` (the first prefetch), `$score[n]`, or a payload field through Qdrant's
  JSON-path grammar. Quoted paths select literal flat names containing dots,
  spaces or other punctuation; nested keys, UInt64 indexes and `[]` wildcards
  traverse the stored JSON values.
- `{"sum": [a, b, ...]}` and `{"mult": [a, b, ...]}` evaluate in source order.
  Empty sum is zero; empty multiplication is one.
- `{"div": {"left": a, "right": b, "by_zero_default": 0}}` supports an optional
  F32 division-by-zero default. `{"pow": {"base": a, "exponent": b}}` computes powers.
- Unary `neg`, `abs`, `sqrt`, `exp`, `ln`, and `log10` take one expression.
- `lin_decay`, `exp_decay`, and `gauss_decay` take a dictionary containing `x`,
  optional `target` (zero), `scale` (one), and `midpoint` (0.5). Scale must be
  positive. Linear midpoint permits [0, 1]; other decays require (0, 1).
- `{"geo_distance": {"origin": {"lon": 121.5654, "lat": 25.033}, "to": "location"}}`
  returns the spherical distance in meters from the constant origin to a
  GeoPoint resolved from the payload path or its default. It uses the pinned
  Qdrant/GeoRust Haversine implementation with the 6,371,008.8-meter radius.
- `{"datetime": "2025-03-19T00:00:00Z"}` converts a constant datetime to epoch
  seconds. `{"datetime_key": "metadata.created_at"}` converts a string retrieved
  from a payload JSON path or its default. Both follow the pinned Qdrant/chrono
  parser and convert integer microseconds through F64 before final F32 scoring.
- `{"condition": <Akasha filter>}` produces one or zero, using the documented
  native `condition/all/any/not` filter shape. This wrapper is not the Qdrant
  REST condition representation.

Multiplication returns positive zero immediately on a zero operand; division
with a zero numerator does not evaluate its denominator. Unvisited missing
variables and invalid arithmetic therefore do not fail the query. Other math
errors fail the entire request, including errors in candidates that would not
survive the final limit or threshold. Intermediate sums/products use F64; the
final score must fit finite F32 and is widened to the public Float64 result.
No intermediate nonfinite check is added to sums/products/negation/absolute
value/decays; division and the other math operators follow source checks.

Missing prefetch scores use a numeric default for that score variable, otherwise
zero; a nonnumeric score default also means zero. Missing payload values require
a default. A present nonnumeric payload value raises even if a numeric default
exists. Defaults accept bounded JSON values, retain Int64/UInt64/Float64 precision,
and are not flattened or coerced; bool is not numeric. Duplicate score-default aliases such as `$score` and
`$score[0]` are rejected rather than depending on map iteration order.

Payload retrieval follows Qdrant's authoritative-payload retriever: unless a path
ends in `[]`, retrieved arrays are flattened by exactly one level. Zero retrieved
values use the default; one uses that value; multiple form an array and fail a
numeric expression. For example, `{"a": [3]}` gives `3` for `a` and `a[]`;
`{"a": [[3]]}` gives `3` for `a[0]`, but `a` and `a[]` are nonnumeric.
An empty array at `a` uses the default, while null at `a` is a type error. A default
`[3]` is not unwrapped. A wildcard in the middle, such as `items[].weight`, can
produce one, zero or multiple values according to the same rules. This does not
implement Qdrant's typed-index retriever selection/coercions.

Formula nodes require at least one prefetch, and can themselves be nested
prefetches. Candidates are the visible deduplicated union of child results;
`$score[n]` still refers to each ordered child separately. An empty union yields
no results without evaluating the expression. Ancestor filters apply before
leaf Top-K, as for other query nodes. Results sort by descending score then
ascending native integer ID; threshold and root offset use normal query rules.
All stages use the same target read generation, including payload evaluation.

`max_query_batch` also bounds the combined count of query nodes, formula nodes
and formula defaults. Each formula additionally permits at most 1024 expression
nodes, 1024 defaults and expression depth 64. Default values together are bounded
to 65,536 value nodes and 16 MiB of content including variable names, with at most
64 container levels per value. Native validation and Python conversion enforce
these limits even for unused defaults or an empty candidate set. Each condition retains the 256-node/16-depth
filter bounds; the binding checks these before recursive construction, including
cycles. Formula stages charge their input row count against the shared
`max_candidates` budget; structural limits bound work per candidate. Native
cancellation/deadline checks occur within recursive expression evaluation.

JSON-path parsing and formula variable grammar now follow the pinned Qdrant
source, including Unicode 17 alphanumeric raw keys, `_`/`-`, quoted literal keys,
UInt64 indexes and `[]` wildcard syntax. Full input consumption is required.
Qdrant's quoted keys do not accept backslashes or quote escapes; this is not a
general JSON-string parser. For example, the expression `'"a.b"'` reads a flat
field named `a.b`; the expression `"a.b"` reads key `b` inside object `a`.
Non-alphanumeric keys such as
spaces or Emoji require quotes. `$"score"[0001]` and `$score[1]` are equivalent.
All UInt64 score indexes are accepted; absent slots use normal default/zero
semantics without converting an out-of-range index to a signed machine integer.

Defaults use the same parsed variable identity: `"name"` and `'"name"'` normalize
to the same key and cannot both appear. Default keys describe paths, so they are
not subject to the persisted document-field-name restrictions; quoted empty or
NUL-containing keys may have a default even though those document keys cannot
currently be stored. Native callers use `FormulaDefault(name, PayloadValue...)`
instead of `DocumentField` for defaults. The provisional literal-name parser and
its signed-index limit have been removed.

The shared native `JsonPath` type also provides canonical display, prefix and
wildcard operations and pattern compatibility for subsequent data operations.
Paths are bounded to 65,536 input bytes and 1024 parts. These are native resource
limits, not a claim that Qdrant has identical limits.
Full formula conditions, typed-index retrievers and Qdrant protocol exposure
remain open.
See the [formula source validation](research/2026-10-30-formula-validation.md).
The [JSON-path validation](research/2026-10-30-json-path-validation.md) records
the subsequent grammar and Unicode source checks.
The [rich formula validation](research/2026-10-30-formula-payload-validation.md)
records the subsequent payload/default retrieval port and end-to-end checks.

Geo points remain ordinary JSON payload values; no new durable tag is required.
The source accepts objects with numeric `lon`/`lat` (additional keys are ignored)
or an array `[lon, lat]`. Both coordinates must be finite, longitude in
[-180,180] and latitude in [-90,90]. Strings and bools are not numbers. Origins
are validated when constructing the request, even for an empty candidate set or
a short-circuited expression. Payload values are converted when evaluated;
missing values may use a default, while null/wrong types/invalid coordinates fail.
The usual payload-retriever flattening applies before GeoPoint conversion.
The native Python expression accepts only `origin` and `to` parameters; this
strict request wrapper is not a complete Qdrant REST schema implementation.

Formula results sort descending. Use `neg` on a distance to rank nearby points
first, or compose it with a decay to obtain a positive proximity score:

```python
nearby = QueryRequest(
    "formula",
    prefetch=(QueryRequest(limit=100),),
    formula=Formula({"exp_decay": {
        "x": {"geo_distance": {
            "origin": {"lon": 121.5654, "lat": 25.033},
            "to": "metadata.location",
        }},
        "scale": 1000,
    }}),
)
# 1.0 at the origin, 0.5 at 1 km; rescoring covers the prefetched candidates.
hits = collection.query(nearby)
```

`to` is a JSON path, not a reserved score variable; a literal `$score` payload
key must be quoted. Native callers use `GeoPoint(lon, lat)` and
`FormulaNode("geo_distance", key=path, origin=Optional(point))`. Distance math
uses F64 and the final formula score follows the existing finite-F32 rule. The
source computation is not clamped or replaced with ellipsoidal distance.
Geo filtering/indexes remain separate pending features.
See [geo formula validation](research/2026-10-30-geo-formula-validation.md).

Datetime inputs are strings. A missing timezone means UTC; date-only inputs mean
midnight UTC. Qdrant's parser also accepts naive date/time through minutes or
seconds, RFC3339 and chrono's relaxed forms (including signed extended years,
some whitespace and timezone offsets without a colon). Calendar validation,
leap seconds, fractional seconds and timezone conversion use the pinned chrono
0.4.45 source port. The supported calendar years are -262143 through 262142;
converting an offset must also leave UTC within the source range. Parsing keeps
nanoseconds, discards digits after nine and truncates to whole microseconds for
formula conversion. Inputs are bounded to 65,536 UTF-8 bytes per datetime.

Constants are parsed during request construction, including empty queries and
short-circuited operands. `datetime_key` parses payloads lazily, after the usual
path/flattening/default retrieval. Missing values can use defaults; explicit
null, invalid dates and non-strings fail when evaluated. Defaults must be valid
date strings, not numeric epoch timestamps. Paths are not score variables; quote
a literal `$score` payload key as with geographic formulas.

```python
recent = QueryRequest(
    "formula",
    prefetch=(QueryRequest(limit=100),),
    formula=Formula({"exp_decay": {
        "x": {"datetime_key": "metadata.created_at"},
        "target": {"datetime": "2025-03-19T00:00:00Z"},
        "scale": 86400,
    }}),
)
# 1.0 at the target time, 0.5 one day away, using the existing symmetric decay.
hits = collection.query(recent)
```

Raw datetime scores sort descending and undergo the source final F32 conversion,
so they do not preserve every microsecond. Date arithmetic and decay occur in
F64 before that final conversion. Native callers can use `DateTimeValue.parse`,
`DateTimeValue.from_timestamp` (microseconds), and `.timestamp()` (microseconds),
or construct `FormulaNode("datetime", key=date_string)` /
`FormulaNode("datetime_key", key=payload_path)`. The native type preserves the
source seconds/nanoseconds leap-second representation; invalid construction or
out-of-range timestamps raise. Stored payloads remain their original strings.
Datetime range filters/indexes, full typed-index retrieval and protocol exposure
are still pending. See [datetime validation](research/2026-10-30-datetime-validation.md).
