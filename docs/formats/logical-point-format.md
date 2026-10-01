# Logical point NDJSON, version 1

Field-aware collections export one UTF-8 JSON header line followed by exactly
`count` complete point lines, in ascending signed point ID order. Every line is
an object. Duplicate JSON keys, NaN/Infinity, unknown versions, unknown fields,
duplicate point IDs and truncated row counts are rejected. The frozen fixture is
[`tests/fixtures/logical-points/v1.ndjson`](../../tests/fixtures/logical-points/v1.ndjson).

The header has exactly these keys:

| Key | Meaning |
|---|---|
| `format` | Exactly `"akashadb.points"` |
| `version` | Integer `1` |
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
`fields` is the complete typed payload array of `{ "name", "type", "value" }`.

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
