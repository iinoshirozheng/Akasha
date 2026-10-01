# Typed point model and complete record codec

The point-model/record-body slice is implemented and verified on pinned Mojo
1.0.0 (`ed45d567`), MAX 26.5.0. It remains uncommitted and is **not imported by
collection open, WAL/segment readers, Python bindings or search**. Runtime
migration and combined durable mutation are still outstanding.

## Implemented behavior

- `document/vector_value.mojo`: immutable owned dense, sparse, multivector and
  packed-binary values. Concrete F32/BF16/F16/I8/U8 Lists use the standard Variant;
  native authority is not promoted to F32 or hidden in an opaque byte buffer.
  Typed moves retain allocation identity. Floating values are finite; sparse
  terms are ordered/nonnegative with finite nonzero weights. Present empty sparse
  and zero-row matrices are distinct from missing fields. Binary dimensions and
  unused high padding bits are checked. Legacy sparse API behavior is unchanged.
- `document/point_state.mojo`: each vector field and payload has an immutable
  shared owner. Pure merge/create, patch-existing and deletion prepare a complete
  replacement; invalid later fields leave the previous state unchanged. Changed
  fields get new owners, unmentioned fields keep their owners, and delete/reinsert
  cannot resurrect old fields. Named-only/payload-only points allocate no default
  dense data. Public legacy document projection remains an owned copy.
- Point sequence covers all changes; document sequence covers the legacy default
  dense/payload projection. Migration assigns point watermark C while preserving
  actual document sequence D, because legacy sparse snapshots cannot reconstruct
  per-point update times. No extra accepted user sequence is allocated by migration.
- `document/point_codec.mojo`: bounded complete-state record and concrete typed-body
  codecs, borrowing encoded input and owning decoded data. Size/count/shape checks
  precede data allocation. Scalar bits, including negative zero and subnormals,
  round-trip exactly; lengths and row counts cannot trigger overflow-based reserves.

The [wire contract](../formats/point-record-format.md) defines the 40-byte point
header, payload-v1 reuse and catalog-driven field bodies. A future durable envelope
must supply format version, catalog binding and CRC validation. This record codec
has no independent checksum and does not make arbitrary scalar corruption detectable.

## Evidence

The pinned official Variant source and a compiled probe were inspected before
adopting the typed union. Its typed-arm accessor borrows an immutable List without
copying the underlying allocation, including behind a shared Arc. Separate negative
compiler probes reject assigning through a dense view and clearing a payload view.
This is evidence for these tested accessor boundaries, not a general claim that
all possible unsafe/private-field accesses are prevented by the language.

Local Qdrant `named_vectors.rs` uses typed dense/sparse/multidense arms and
contiguous flattened matrices; `segment/entry.rs` flushes point versions after
field storage to preserve replay correctness (local commit
`74f3e85b9473c62560006c043e13737ce6b48412`). Akasha retains its own atomic envelope
and complete-state segment design rather than copying Qdrant's persistence layout.

All **40 targeted tests** pass:

- 4 vector-value tests: all five numeric types, direct allocation transfer,
  shape/finite checks, sparse validation, empty fields and bit padding.
- 8 point-state tests: partial/combined preparation, owner identity, snapshot
  independence, legacy owned projection/version, named-only state, payload clearing,
  field removal/readdition, deletion/reinsertion, invalid later fields and payload,
  sequence/cutover boundaries and malformed complete states.
- 7 point-codec tests: six independent golden records, exact byte re-encoding,
  decoded ownership after source release, every truncated prefix both with original
  and adjusted outer length, trailing bytes, malformed headers/descriptors,
  all dense/matrix scalar combinations, overflow tags, bad numeric values,
  unknown/duplicate fields, catalog mismatch and 1,024-field boundary.
- 10 existing field-catalog, 6 existing payload-codec and 5 existing sparse tests.

Tests were added before their source modules: each initially failed to import the
missing implementation, then passed after implementation. The
[validation artifact](2026-10-01-point-records-validation.json) contains command
outputs, source/fixture hashes and the negative compiler probes. The independent
fixture generator reproduces all six files exactly. Mojo formatting and
`git diff --check` pass.

No existing runtime paths changed in this slice. Prior full CPU/Python/crash/C ABI,
build and quality results were not rerun or relabeled as validation of new durable
behavior. GPU behavior was unchanged. No new throughput claim is made.

## Remaining integration

Next: define and read the catalog-bound, checksummed field-aware WAL patch and
segment envelopes; reuse bounded envelope I/O and merge legacy replay through the
cutover. Then wire the point model into collection authority, staging/publication,
checkpoint/compaction and migration crash recovery. Named/scalar/binary/multivector
APIs, exact/search oracles, bindings/Arrow, M5/M6 and final integration remain in
scope. The existing slow post-update HNSW reopen is also still unresolved.
