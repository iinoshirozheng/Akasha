# Logical point NDJSON, versions 1, 2 and 3

Field-aware collections export one UTF-8 JSON header line followed by exactly
`count` complete point lines, in ascending signed point ID order. Every line is
an object. Duplicate JSON keys, NaN/Infinity, unknown versions, unknown fields,
duplicate point IDs and truncated row counts are rejected. The frozen fixture is
[`tests/fixtures/logical-points/v1.ndjson`](../../tests/fixtures/logical-points/v1.ndjson).

The header has exactly these keys:

| Key | Meaning |
|---|---|
| `format` | Exactly `"akashadb.points"` |
| `version` | Integer `3` for new exports; frozen versions `1` and `2` remain readable |
| `config` | Default collection identity, as listed below |
| `vectors` | Named field name to schema object |
| `count` | Nonnegative integer number of following point records |
| `source_sequence` | Unsigned 64-bit accepted sequence of the captured root |

`config` contains `dimension`, `ann_metric`, `scalar_kind`, `m`, `m0`,
`ef_construction`, `default_ef_search`, `max_ef_search`, `max_level`,
`rebuild_inactive_percent`, `delta_max_points`, and unsigned `level_seed`.
The derived fingerprint is excluded. A named schema contains exactly
`dimension`, `dtype`, `kind`, `metric`, and `hnsw`. `hnsw` is null or a full
configuration with the same keys as `config`. Field names are nonempty strings
without NUL. Reserved default dense/sparse fields are implicit in the default
collection identity and never appear as named fields.

Each point has exactly `id`, `sequence`, `document_sequence`, `vector`, `sparse`,
`vectors`, and `fields`. IDs are signed 64-bit integers. `sequence` is positive
and no greater than `source_sequence`; `document_sequence` is between zero and
that point's sequence. They describe the source and are not assigned to the
destination's WAL: importing allocates new consecutive target sequences.

`vector` is the default F32 array or null for absence. `sparse` is null for
absence or an array of `{ "term_id": ..., "weight": ... }` objects, including
an empty array for a present empty value. `vectors` contains only present named
fields; a present null named value is invalid. Native dense values are numeric
arrays, multivectors are arrays of equal-width rows (including zero rows), and
sparse fields use the same element objects. Binary values use exactly
`{ "encoding": "hex", "data": "0101" }`: two hexadecimal characters per
packed byte, with the schema's bit dimension and zero high padding bits.
For v1/v2, `fields` is the complete payload array of `{ "name", "type", "value" }`.
V1 restricts field types to string/int/float/bool. V2 also permits null/array/object/
uint. Arrays and objects contain ordinary recursive JSON values; keys retain
insertion order and may be empty or contain escaped NUL. Null is a present field,
not field absence. The root `uint` tag retains unsigned identity; nested JSON
numbers retain their value and signed floating zero, while JSON itself does not
label small positive integers as signed vs unsigned. Native integer range and
value depth/node/byte limits are validated before any batch commit. A v1 header
containing v2 field tags is rejected, not silently upgraded.

V3 fields have exactly `{ "name", "type", "value", "encoding": "typed" }`.
The field type is string/int/uint/float/bool/null/array/object/jsonb. The value
body follows this table; every nested child has exactly `{ "type", "value" }`:

| Type | Body |
| --- | --- |
| `string` | JSON string |
| `bool` | JSON boolean |
| `null` | JSON null |
| `float` | finite JSON number converted to Float64; signed zero retained |
| `int`, `uint` | Field roots only: signed Int64 or unsigned UInt64 JSON integer |
| `integer` | Nested values and typed updates: JSON integer in Int64/UInt64 union range |
| `array` | Array of typed child nodes |
| `object` | Object mapping arbitrary JSON member names to typed child nodes |
| `jsonb` | Even-length hexadecimal string containing a complete source JSONB body |

The existing ordinary Python/JSON numeric contract remains: nested integers
retain value but have no small-positive signed/unsigned identity. V3 uses the
`integer` tag to make this explicit, and rejects nested `int`/`uint` tags rather
than silently discarding a declared label. A field's explicit root int/uint
identity is retained. This restriction does not affect the exact source bytes
inside a JSONB body, including its compact integers and nonfinite F64 values.

Hex output is lowercase; input accepts either case, with no spaces or prefix.
Native Mojo checks all decoded JSONB bytes and aggregate payload resource limits
before the complete import can commit. Storage null is a `null` node; JSONB null
is a `jsonb` node with body `2000000000000000`. They remain distinct at any depth.
No ordinary object is interpreted as a marker based on its keys. The same
explicit field encoding is used by the Akasha HTTP API. This is an Akasha wire
format, not Qdrant REST or Lance file compatibility.

V3 requires typed encoding on every field. V1/v2 reject JSONB and v3 encoding
members; there is no content-dependent version fallback. Independent v2 and v3
fixtures accompany the frozen v1 fixture. Older clients reject the new header.

Numeric values retain native precision: the exporter expands finite native
scalars to exact Python numbers and the importer applies the destination's
matching native type. Signed zero and native subnormals survive. Native bounds,
dimensions, sparse ordering and binary padding are validated by the existing
kernel before WAL append. Non-numeric JSON values are never dtype conversions.

Schema and every point are captured from one immutable root. Replacing the export
file is atomic; a failed publication preserves the previous destination and
removes the unique temporary file. The entire input is validated before its
single point-batch mutation. The public importer requires a field-aware target
with exactly matching default identity and named schema. Imported IDs replace
their complete field state, clearing absent fields; unrelated target IDs remain.
Empty versioned exports are valid and cause no mutation. Row limits still apply.

Legacy collections continue to write the original unversioned document lines;
the existing reader and default dense/sparse import semantics remain available.
An explicit point header is never interpreted as a legacy document. Physical
database formats, version migrations, backup and restore are unchanged.
