# Field-aware authority integration checkpoint

Work continues toward the complete single-node plan. These changes are not yet
committed. Public `PersistentCollection`, Python point APIs and typed Arrow paths
are now connected to the new authority. Remaining work includes per-field derived
indexes, cold reopen, broader failure/performance gates and branch integration.
No performance-parity claim is made.

Implemented and observed passing on Mojo 1.0.0 (`ed45d567`):

- `field_catalog.mojo`: v1-to-v2 identity publication compares the exact preflight
  identity, preserves default HNSW configuration, uses write/fsync/rename/directory
  fsync, and makes an identical post-rename retry finish the directory barrier.
  Six tests cover invalid transitions, each publication failure and cleanup errors.
- `point_table.mojo`: only affected point descriptors are staged, repeated IDs
  apply in batch order, validation finishes before one encoded WAL append/fsync,
  and complete states become visible together. An uncertain append prevents more
  writes until reopen. Seven tests cover durability, replay, owner sharing,
  checkpoint boundaries, sparse-only deltas and tombstones. Numeric buffers of
  unmodified fields remain shared; this does not claim zero-allocation staging.
- `legacy_recovery.mojo`: extracted the actual dense/sparse/manifest preflight from
  `PersistentCollection.open_with_config`. Ordinary open now uses this helper.
  A shared legacy-envelope interface also accepts the old prefix of a mixed WAL;
  it does not retain the full dense history. Three new tests check side effects,
  late corruption, original sparse ordering and empty directories. The existing
  16 config-migration, 17 persistent-collection and 8 persistent-sparse cases passed.
- `point_migration.mojo`: recovers both old streams exactly through catalog cutover
  C before applying any v4 patches. Point versions are anchored at C and real
  legacy document versions are retained. Accepted legacy numeric/payload owners are now shared after finite-value
  validation. Six tests cover WAL-only and checkpoint upgrades,
  every truncated new-batch prefix, wrong cutover, late patch failure and an actual
  combined append after identity publication followed by reopen, owner identity
  preservation and rejection of legacy non-finite authority.
- `point_recovery.mojo`: validates complete v4 bases/deltas against the manifest,
  merges complete states, validates retained WAL batches without reapplying them,
  and rejects post-cutover legacy sparse writes. Four tests passed. The first v4
  checkpoint replaces the legacy segment set with a complete base; subsequent
  point checkpoints can append deltas. Segments still use owned file acquisition;
  only WAL acquisition is bounded by one envelope/read-ahead buffer.
- `point_store.mojo`: owns the file lock, immutable catalog and point authority;
  performs new-store creation or legacy upgrade, atomic writes, complete base and
  delta checkpoint publication, full compaction, deferred repair and lease-aware
  retirement. Five storage-level end-to-end tests cover named F32, F16, packed
  binary and multivector persistence, close/lock behavior, schema mismatch and
  corrupt recovery. Native exact field search is now implemented; public collection and binding
  integration remain outstanding.

The first storage checkpoint above had **30 targeted tests**; later additions
are listed separately below. Additional WAL regressions
passed: 10 legacy-stream and 8 mixed-stream tests. Recorded outputs are in
[the validation artifact](2026-10-01-field-authority-validation.json). Counts in
that artifact may include reruns of a test file; they are not unique-suite totals.

Earlier interrupted checks were also completed: persistent sparse (8), config
migration (16), remaining HNSW/sparse/tail crash cases (6+1+1), and the optional
Qdrant adapter test (1, with the pinned dependency added to PYTHONPATH). Combined
with the 11 crash cases observed before interruption, the preceding envelope slice
had 19 crash passes. Those checks precede the subsequent recovery refactor and
must not be relabeled as its final integration gate.

Further integration observed passing:

- Native F32/F16/BF16/I8/U8, sparse, packed Hamming/Jaccard and ragged MaxSim
  scoring use Float64 accumulation/results. No authoritative vector promotion is
  performed. Six numeric tests use independent goldens, integer extremes, large
  finite F32 values and partial binary bytes. Four PointStore query tests cover
  native dense types, filters before Top-K, missing fields, binary/MaxSim and reopen.
  Existing F32 heaps retain their precision/ordering; the heap now accepts an
  explicit score dtype, with a regression for scores beyond F32 integer precision.
- MemTable read descriptors now use the same typed point field owners rather than
  a parallel F32/sparse representation. Four tests verify sharing, missing default
  vectors, document versions, delete/reinsert and old low-level nonfinite bits.
  Read-generation byte budgets account for every native vector field.
- Four typed snapshot tests cover shadowed layers, named field removal, metadata
  filters, default dense presence before ranking, document/point versions, scanner
  ownership after snapshot close, empty sparse values, all-named SQ8/PQ queries and
  a 4 MiB native field forcing a head rollover without copying its buffer.
- Existing committed-compaction capture/build/rebase/publication now accepts v4
  point segments. Four tests cover appended deltas, retained WAL, stale captures,
  corrupt inputs and generation-file leases. The writer refreshes the manifest
  before checkpointing so a completed background rebase is not overwritten.
- Existing streamed backup/restore and storage inspection accept the complete
  catalog and v4 point checkpoint. Three tests cover native field restoration,
  one-byte streaming, corrupt copy without target manifest publication, and a
  conflicting target schema. The backup captures the catalog with its manifest;
  field-aware backup requires the first complete point checkpoint.

- Default-field HNSW projection now omits named-only points. The rebuild journal
  uses the independent document version, so named/sparse-only updates advance
  coverage without reinserting unchanged default vectors; removing the default
  vector is a graph deletion. Two new tests and 28 existing HNSW rebuild and
  publication tests pass. This does not fix the outstanding cold-reopen sidecar
  cost or implement per-named-field HNSW indexes.

Relevant regressions passed after the read-owner change: MemTable 14, generation
fields 3, snapshot 10, segment 8, flat index 10, batch query 4, parallel scan 3,
compaction publication 11, point recovery 4, storage operations 9, native vector
values 4, scanner 4, quantization 11 and product quantization 10. The Python binding
rebuilt successfully and its suite passed 117 tests with the optional Qdrant
adapter skipped (1). Legacy backup/checkpoint crash regressions passed 3 + 7;
new typed migration/checkpoint crash seams still need their own gate. Recorded
outputs are in [the typed-read validation artifact](2026-10-01-typed-read-validation.json).
These are not a new full-suite or M5/M6 result.

Public integration now routes all default and named mutations through the same
point WAL in field-aware collections, publishes immutable snapshots, and uses the
existing synchronous/background compaction worker. Four new public collection
tests cover migration, validation without partial commit, default ANN presence,
snapshot isolation, both compaction modes and backup/restore. The typed checkpoint
crash test covers ten disk states, including catalog and manifest publication,
WAL rotation, recovery, append after recovery and old file retirement.

Python exposes `VectorField`, `PointMutation`, `Point`, `get_point`, `search_field`
and catalog introspection. Twenty-seven tests cover native types, sparse/binary/
MaxSim, NumPy ownership, schema identity, integer bounds, finite conversion,
partial updates, filters and reopen. Typed Arrow adds atomic point batch ingress,
nullable native scanner columns and Float64 named-query scores. Twenty-six tests
cover all native dtypes, BF16 bit metadata, sliced validity/offsets, missing versus
empty values, C Data owner lifetime, invalid components and full-batch rejection.
The old Arrow entry point also commits dense+sparse atomically on a point-format
collection. Legacy-format collections retain their documented separate streams.

Validation after binding integration: `pixi run build-python` succeeded;
`pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` returned
**170 passed, 1 optional Qdrant skip** (7.97 s). The seven existing native Arrow
ABI/lease/error tests also passed. These results precede final CPU/crash/C ABI/
build/performance integration and do not establish Qdrant parity or M5/M6.
