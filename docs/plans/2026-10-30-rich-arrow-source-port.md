# Rich Arrow payload source port

Continue D01/A03 after D03f. The full feature-first product ledger remains open.
This work completes typed Arrow payload ingress/projection for the existing
native JSON data model before Lance table/schema/history layers. Dynamic JSON
extension interop remains an explicit subsequent part of D01, not replaced by
stringifying nested data or a claim of Lance-format compatibility.

## Source and contracts

- Inspect pinned Lance `rust/lance-arrow/src/{struct,list}.rs` for parent null
  masking and independent parent/child slices. Inspect its Arrow dependency
  array, buffer and schema implementations before translating traversal.
- Arrow 58.4.0 array/schema and 58.3.0 JSON are fixed by the local Lance lock;
  retain checksums, original units, licenses and executable reference results.
- PyArrow 21 supplies C Data ownership and type/buffer descriptors only. Mojo
  owns schema validation, recursive values, type checks, bounds, materialization
  and atomic submission. No Python list/dict payload staging or hidden evaluator.
- Support native JSON-compatible Arrow null, bool, signed/unsigned integer,
  float, UTF-8, struct, list, large-list and fixed-size-list types, including
  slices and masked child garbage. Preserve the existing vector columns.
- Follow Arrow/Lance null semantics: a supplied null cell becomes explicit
  native null, including top-level cells. Update the former scalar-null omission
  contract and tests together, following the user's upstream-behavior preference.
  An absent column remains absent; point upsert still replaces the entire point.
- Typed projections map missing and explicit null to Arrow null, as Arrow's
  fixed schema does. This intentional projection is not a lossless schemaless
  JSON representation. The later standard `arrow.json` extension must distinguish
  missing storage null from JSON `null` and support heterogeneous values.
- Projection schema accepts real PyArrow data types plus existing scalar names.
  Keep the schema stable for empty/filtered results, without collection scans or
  type inference. Wrong stored types, numeric overflow, required missing values,
  duplicate struct keys and unsupported types are errors.
- A null parent masks child values; valid parents must enforce child nullability.
  Containers preserve explicit null elements and declared struct field order.
  Schema selection intentionally projects selected object keys; undeclared keys
  are not inferred. Keep payload depth/node/byte bounds and scanner buffer limits.

## Implementation sequence

1. Pin/read source and make independent array/schema/null/slice fixtures.
2. Add one bounded native payload schema and borrowed input descriptor traversal;
   integrate both Arrow ingestion APIs atomically and remove scalar `.as_py()`
   payload loops. Preserve imported owners and post-conversion close guards.
3. Extend the native Arrow exporter with recursive owned buffers, shared budget,
   null masking and existing release callbacks. Use one payload path for legacy
   scalar and rich typed projections, removing obsolete scalar-only branches.
4. Verify original-source fixtures, public native-backed input/output, independent
   child offsets, UInt64 bounds, empty/null/required fields, parent masks, Unicode,
   failure atomicity, WAL/checkpoint reopen, snapshots/close, release ownership,
   cancellation and resource limits. Run related native tests, build and Python
   regressions serially. Update docs, provenance and full ledger before commit.

No persistent format change, new runtime dependency or optimization is planned.
Complete D01 still requires dynamic JSON/missing interop and remaining durable
key/schema work; all ID/index/protocol/Lance/SQL/UI/security/cluster/operations
and existing quality/platform gates remain open.

## Implementation checkpoint

- D01c1 implements sequence steps 1–2: one bounded native schema/value reader
  for both Arrow upsert APIs, including explicit nulls, all integer widths,
  finite F16/F32/F64, UTF-8/large UTF-8 and nested structs/lists. The former
  `.as_py()` payload loops are removed. Existing scalar export now maps explicit
  null to Arrow null. This is an independently usable ingress slice.
- The source oracle uses actual Arrow Rust arrays/IPC/JSON and unchanged Lance
  list/struct modules. It confirms null masking, garbage-list removal and sliced
  children. No new runtime dependency is introduced.
- Verification discovered that Arrow C Data truncates NUL-containing schema
  names. Direct RecordBatch input now rejects these before capsule export.
  Nested empty keys remain valid; typed C Data cannot represent NUL in names.
  Schemaless JSON extension interop must preserve those keys inside values.
- D01c2 implements recursive native **export**, real PyArrow projection types and
  fields, stable nested schemas/metadata, numeric bounds, shared output buffers,
  bounded null-only expansion, cancellation and recursive release/snapshot
  ownership. The old scalar-only column kinds and export branch are removed;
  public scalar aliases use the same typed path. The shared C Data owner is
  extracted unchanged into `bindings/arrow_buffers.mojo`.
- Source comparisons found four F16 midpoint differences: Arrow's half NumCast
  passes through F32 first. Mojo folds inline F64→F32→F16 into one conversion;
  a no-inline F32 boundary preserves the source's double rounding. Verification
  includes an independent 2,126-row Arrow cast fixture for both output widths.
  Dynamic JSON extension, durable table schema/history and the full product
  ledger remain open. Typed Arrow does not encode schemaless missing/null/key
  distinctions or claim Lance file/schema compatibility.
