# Reader-first vector field catalog

The catalog metadata slice is implemented and verified on Mojo 1.0.0
(`ed45d567`), MAX 26.5.0. It is uncommitted. Collection open/publication still uses
the existing v1 path; named point storage, field-aware WAL/segments and runtime
migration are not enabled by this change.

`document/vector_schema.mojo` describes independently configured vector fields,
keeps authority dtype separate from graph encoding, and provides validated ID/name
lookup through the existing standard Dict. The two legacy fields have reserved
IDs; named IDs can have gaps. `storage/field_catalog.mojo` decodes borrowed bytes
into owned metadata, reuses the exact 60-byte HNSW config validator, and reads only
`collection.bin` through bounded file acquisition. Its low-level encoder preserves
v1 bytes when given a decoded v1 catalog; it never silently upgrades or publishes.

The [v2 wire contract](../formats/field-catalog-format.md) defines header, tags,
lengths, limits, CRC, legacy mapping and the migration cutover sequence. The
independent [fixture generator](../../tests/fixtures/field-catalog/generate.py)
reproduces all three checked-in fixtures byte-for-byte. Metadata includes the
agreed native/binary/multivector kinds, but parsing such metadata is not an
implementation of its data or search path.

Validation passes **38 targeted tests**:

- 10 new catalog tests: independent golden bytes and exact re-encoding, old-reader
  rejection of v2, sparse/default mapping, noncontiguous IDs, every truncation and
  single-byte corruption across the three fixtures, CRC-valid malformed metadata,
  duplicate IDs/names, UTF-8/NUL and schema constraints, owned input independence,
  UInt32/UInt64/name/count boundaries, and file reads that preserve both a stale
  identity temp file and a torn WAL.
- 12 existing collection-config storage tests.
- 16 existing legacy collection-config migration tests.

The decoder tests first failed on an unimplemented decoder. The new file-reader
test also failed with its implementation absent, then passed with bounded loading.
Commands, complete outputs, source hashes and fixture hashes are in the
[validation artifact](2026-10-01-field-catalog-validation.json). Formatting and
`git diff --check` pass. No existing production call path imports these new modules;
unchanged full CPU/Python/crash/C ABI/GPU/quality gates were not rerun for this slice.

Next is the field-aware point/WAL/segment contract and independent fixtures, then
record readers, migration publication, combined writes, named-F32 APIs/search and
bindings. The later native-type, binary, multivector and M5/M6 work remains open.
