# Preserve typed points in logical export/import

**Status: implemented and validated.** Version 1 typed NDJSON and its legacy
reader are covered by 22 new tests; the rebuilt binding passes all 339 Python
tests. See the [delivery evidence](../research/2026-10-02-named-logical-export.md).

The existing binding exports `snapshot.documents()`, which deliberately includes
only default-dense documents. It then joins legacy sparse values. A public probe
created point 1 with only an F16 named field and point 2 with default dense plus
that field: NDJSON contained only point 2, without its named field. This is a
logical-export data loss bug; physical backup/restore and typed Arrow already
cover different paths.

Use the existing immutable snapshot/read-generation owners and point conversion
helpers to capture every visible point, its schema and values together. Preserve
the existing unversioned legacy export API/format for legacy collections and its
reader. Add an explicit versioned point-format header for field-aware collections,
including an immutable schema, default collection identity and point count.
Represent binary values as explicitly tagged hexadecimal bytes; finite native
floating values, integers, ragged rows and sparse values use standard JSON types.
Absent values and present empty sparse/multivector fields must remain distinct.
Sequences describe source versions and are not restored as target WAL sequences.

Read and validate the complete input, format version, schema, row count, unique
IDs, field presence and resource limits before mutation. A field-aware import
requires a compatible target catalog and uses one existing `apply_point_batch`
commit for all rows and modalities. Replacing an existing point must clear fields
that are absent in the exported complete state. Schema must not be silently
coerced; use the already maintained Python JSON and kernel validators, with no new
dependency or persistence change. Keep legacy input compatibility explicit.

Add a documented frozen logical-format fixture and tests for every native dtype,
binary padding, ragged/empty/missing fields, named-only and payload-only points,
negative IDs, overwritten target points, close/reopen, malformed/version/schema
mismatches, late invalid values, and unchanged target sequence/WAL on failure.
Verify snapshot consistency and legacy export/import regressions, Python binding
tests and CLI behavior. Do not mix this change into the mapped-reader integration
checkpoint currently running; first finish and archive that checkpoint.
