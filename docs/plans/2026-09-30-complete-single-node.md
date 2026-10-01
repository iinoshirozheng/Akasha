# Complete the remaining single-node work

> **For Codex:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Finish the user-authorized #54–#63 work, the compaction stability issue,
and named/native-scalar/binary/multivector support, with durable migration and
end-to-end verification. Completion of one slice does not complete this goal.

**Architecture:** Extend ADR 0007's immutable read roots and independent field
owners. Use existing Mojo/Python/PyArrow interfaces; isolate durable schema changes
from index-cache and buffer changes. Keep `tasks/todo.md` as the execution checklist.

**Tech Stack:** Project-pinned Mojo 1.0.0/MAX 26.5.0, Python 3.11, NumPy, PyArrow,
native pthread worker, Pixi; local references under the main checkout's `reference/`.

## Delivery order and evidence

Each implementation slice starts with a failing behavioral test, then implementation,
targeted verification, its measurement where required, documentation, and a separate
commit. Preserve established format readers and public APIs. Continue authorized work
across checkpoints without requesting permission again.

1. **#54 SQ8:** inspect existing uncommitted implementation and recorded gates;
   run `pixi run mojo run -I src tests/mojo/test_quantized_search.mojo`, then commit.
2. **#55 PQ:** root-owned artifacts keyed by all actual training parameters
   (subquantizers, centroids, iterations; current initialization is deterministic,
   with no seed parameter). Reuse one ready artifact across metrics, k, and rerank.
   Use the existing `ArtifactState` and official `Dict`. Add cooperative query/build
   cancellation through existing `QueryControl`; never publish partial builds.
   Files: `index/artifact_state.mojo`, `storage/read_generation.mojo`,
   `api/snapshot.mojo`, `index/quantization.mojo`, `test_product_quantization.mojo`.
   Test repeated/concurrent queries, all key parameters, root freshness, cancellation,
   build failures, close, and oracle parity; measure cold and warm separately.
3. **Compaction stability + #56:** inspect real conflict transitions and reproduce
   the race before changing coordination. Pin graph inputs, build outside the writer
   lock, bounded catch-up, validate config/source, publish and retire sidecars safely.
   Files: `api/collection.mojo`, `index/segmented_hnsw.mojo`, maintenance/retirement
   modules as callers require; compaction/HNSW publication and crash tests.
4. **#57 direct Arrow results:** `src/bindings/python_module.mojo`,
   `python/akashadb/arrow.py`, `tests/python/test_arrow_c_data.py`, ingress benchmark.
   Output I64 IDs/F32 scores to official typed buffers without per-row Python objects;
   test empty/ties/slices/closed-source ownership and account for copies.
5. **#58 scanner:** prove real Mojo C Data callback/owner lifetime on the pinned
   compiler, then implement bounded run/chunk scanning with borrowed contiguous
   buffers and owned gather/cast output. Test release, close, cancel, slices and
   projection using real Arrow consumers. Files per #58 in `tasks/todo.md`.
6. **#59 comparison:** fixed commits/hardware/data checksums; synthetic 128/high-D
   plus real embeddings; compare equivalent service boundaries at matched recall.
   Add reproducible `benchmarks/qdrant_compare.py`, raw results and report. Failed
   recall cells remain failed; do not claim parity without measured acceptance.
7. **#60/#61 primitives:** inspect the pinned official comparator/sort/heap APIs;
   adapt one component per commit only after semantic and scaling gates. Preserve
   measured rejection evidence if an official API is not suitable.
8. **#62 WAL decode:** bounded owner-backed reader and record decoding; retain CRC,
   overflow/bounds/old-version/torn-tail/append-repair behavior. Measure peak memory.
9. **#63 read-only copies:** borrow fingerprint inputs and check sparse liveness
   without materializing documents; verify unchanged bytes and failure sequences.
10. **Field schema + named F32 + atomic combined mutation:** first commit durable
    catalog/record specifications and fixtures, then reader-first migration,
    writer/API and search/reopen slices. Preserve legacy data and unknown-version
    rejection; test torn writes, rollback/forward recovery and field independence.
11. **Native F16/BF16/I8/U8:** implement each authority dtype with ingress bounds,
    exact distance oracles, persistence, bindings, query and reopen tests.
12. **Binary:** native packed bits with bit dimension/padding and Hamming/Jaccard;
    own format migration and full write/read/search/reopen tests.
13. **Multivector:** ragged offsets, empty-row semantics and MaxSim/late interaction;
    persistence, named-field/filter integration, bindings and reference oracle.
14. **Integration:** reconcile stale README/architecture docs; CPU/Python, crash,
    C ABI, build/examples and quality gates; actual-device GPU only for changed GPU
    behavior. Audit every task and typed-field matrix cell against current evidence,
then integrate the completed branch without overwriting unrelated user edits.

## Test commands

Targeted: `pixi run mojo run -I src tests/mojo/<test_file>.mojo`.
Python Arrow: `pixi run build-python`, then
`pixi run env PYTHONPATH=python:. pytest tests/python/test_arrow_c_data.py -q`.
Integration: `pixi run test`, `pixi run test-crash`, `pixi run test-c`,
`pixi run build`, `pixi run check-hnsw-quality`, `pixi run check-post-hnsw-quality`.
Reuse successful unchanged gates; record command, source revision, results and limits.

## Completion audit

The authoritative requirements are this goal's full scope, #54–#63 in
`tasks/todo.md`, ADR 0007, the M2/M4/M5/M6 contracts in
`2026-09-07-single-node-lifecycle-zero-copy.md`, and format/API compatibility.
No checkbox is evidence by itself. Inspect implementation, tests and measured
artifacts for each requirement before marking the overall goal complete.

## #56 implementation findings (2026-09-30)

- `_build_hnsw` orders rows by accepted row sequence then point ID, not physical
  ordinal or ID alone. A pinned root's `dense_run()` produces shared dense
  descriptors suitable for this existing builder outside the writer lock; keep
  its deterministic ordering and existing rebuild tests.
- `_record_read_state(ids, sequence)` is the centralized accepted-write hook.
  A bounded rebuild catch-up journal must cover all accepted mutation paths,
  including batches/deletes/reinserts and unavailable-graph recovery. Do not scan
  the entire live table under the publish lock to discover changes. Journal
  overflow must invalidate the candidate and trigger bounded recapture/retry.
- Before #56, manifest v3 explicitly required `hnsw-<last_sequence>.bin` in both
  `storage/manifest.mojo:_validate_descriptors` and the canonical
  `docs/formats/manifest-format.md`. Job-unique sidecar filenames require a
  versioned reader-first migration; do not silently relax the v3 contract.
  `formats/manifest-format.md` is a stale placeholder, not the detailed spec.
- Before #56, flush removed/replaced sidecar paths directly, and #53 backup omitted
  HNSW for that reason. Sidecars must retire through pins before backup can copy
  them safely. Cover same-sequence rebuild, downgrade/upgrade, build/publish crash
  boundaries, stale config, and restore after deleting the original source.
- The separate compaction job lock is now implemented and tested. Preserve the
  job → writer order and keep the HNSW build outside both the writer and any
  unnecessary full-compaction exclusion.
- The pinned HNSW builder and bounded journal are now implemented. Measurements
  rejected doing even a bounded 1,024-row catch-up under writer (about 125 ms in
  the exploratory 128D run). The final path rotates the journal in O(1), applies
  it outside writer, and publishes only after observing an empty journal under
  the same lock. Four catch-up passes per capture and four captures bound retries.
  Keep the 18 publication regressions, including writes during catch-up, batch
  updates while ANN is unavailable, overflow, close and retry-budget exhaustion.
  See `docs/benchmarks/2026-09-30-hnsw-rebuild.md` for measured phases and limits.
  The #56 durable slice now implements v4 reader/writer, unique sidecar creation,
  pin-based retirement and captured backup copying. Backup owns a share of the
  source advisory lock through collection close. Narrow format, backup and crash
  tests and integration gates pass: 752 Mojo, 66 Python, 19 crash tests, build,
  C ABI, three examples and both existing quality gates. See
  `docs/benchmarks/2026-09-30-hnsw-sidecar-publication.md`. Keep #59 and all later
  work in scope. The follow-up exact-file-lease implementation now reclaims
  unreferenced job outputs at any generation and retires files after the last
  reader release, including readers surviving collection close or a replacement
  writer. Nine lifecycle tests include an independent reader process and directory
  replacement. All 94 CPU files (761 tests), 66 Python and 19 crash tests plus C ABI
  passed; see `docs/benchmarks/2026-09-30-file-retirement.md` for scope and costs.
  The #56 worktree changes remain uncommitted; #59's matched-recall baseline is
  now recorded below, with speed parity and cold/open costs remaining in M5/M6.

## #57 binding capability findings (2026-09-30)

An isolated compiled extension on the pinned Mojo 1.0.0 accepts
`def_method[Probe.results[False]]` and `def_method[Probe.results[True]]` for the
same parametric method. A native `List[SearchResult]` can write I64 IDs and F32
scores through mutable `from_numpy_array` spans into two `numpy.empty` owners.
Installed NumPy 2.4.6 and PyArrow 21.0.0 reuse those primitive buffers when
constructing a RecordBatch: both pointer identities matched in the probe. After
dropping the producer, arrays and parent batch, a slice retained both ndarray
owners; weak references cleared after deleting the last slice and collecting.
This established the necessary binding and output lifetime mechanism before the
complete #57 integration described below.

Use one native result exporter specialized for row objects or typed columns,
and share the existing Python SearchRequest dispatch so filtered, approximate,
sparse and hybrid searches retain their validation and result semantics. Add a
direct `search_record_batch(collection, request)` Arrow entry point. Preserve the
existing public `results_to_record_batch(Sequence[SearchResult])` converter for
callers that already own Python rows. Count the native AoS-to-column copy as
12 bytes/result; do not call the complete result path zero-copy.

The full implementation now passes 46 Arrow and 92 Python tests after rebuilding
the extension. All SearchRequest modes share the dispatch and exporter; pointer,
allocation and final-slice release checks pass. The 4096×16 measurement covers
k=32/1024/4096 and records the small-result overhead as well as the large-result
improvement. See `docs/benchmarks/2026-09-30-arrow-results.md`. #57 is implemented
and verified in the worktree; #58's leased scanner is described below.

## #58 implementation findings (2026-09-30)

The pinned Mojo 1.0.0 compiled a real `abi("C")` ArrowArray release callback.
An isolated extension exports Mojo-owned F32 memory to PyArrow 21.0.0; two Python
tests verify pointer identity, Arrow moving the producer header, a slice retaining
the native allocation until its last release, and unconsumed producer cleanup.
The release state is located through `private_data`, independently of the header.
Production export will keep the integer address internal to the binding, import
it immediately with PyArrow, and use RAII to release an unconsumed array on error.
PyArrow owns schema construction and its public capsule protocol; Akasha implements
only buffer/child ownership and the native release bridge. See the
[Arrow C Data contract](https://arrow.apache.org/docs/format/CDataInterface.html).

Current immutable dense owners contain one row each. A one-row vector can be
borrowed with a retained root; multi-row batches gather directly into final
column buffers. IDs, sparse AoS-to-column conversion, payload values, offsets and
validity are materialized and counted. Do not claim packed multi-row storage or
zero-copy gathering. Scanner selection memory is bounded by batch size and scans
visible slots in run order without a whole-snapshot ordinal list.

Payload is presently schemaless, including different types for a name in different
rows. The streaming API therefore accepts an explicit typed payload projection;
missing fields yield Arrow nulls and present type mismatches fail, closing the
scanner. Its schema stays fixed without a preliminary full-dataset scan. Default
columns cover IDs, vectors and sparse state; named-field catalog work remains in
the later schema lane. Existing owned document export remains available.

The kernel cursor, Arrow buffer/release bridge and Python facade are now
implemented and verified as separate interface slices in the worktree. Ten new
Mojo tests and 19 new Python/ABI cases prove the ownership, visibility and buffer
contracts. The full 111-test Python suite, 35 targeted Mojo tests, build, C ABI and
three examples passed. Four batch-size cells record real peak RSS and explicit
gather/borrow costs. See `docs/benchmarks/2026-09-30-arrow-scanner.md`. #59 and all
later work remain open; no commit or overall completion is claimed.

## #59 baseline findings (2026-09-30, implemented and verified)

The real native Edge wheel is installed only under `.build/qdrant-compare/deps`.
Version 0.8.0 is bound to its official release commit and checked wheel hash;
the loaded native libraries are hashed in every engine result. The runner uses
equal Python list/request/result boundaries, independent Float64 truth on shared
Float32 data, serial one-thread trials, explicit ef/recall failure gating and
fresh-process open measurements. Raw archives include exact as-run benchmark
source, oracle IDs, per-query samples and configurations.

Three-trial 128D and 1536D uniform F32 plus real DBpedia 1536D cosine comparisons
are complete (36 selected filter/trial pairs pass Recall@10 >= 0.95). They
demonstrate speed gaps, not parity. Real data was downloaded from a fixed revision
and source SHA-256. The dedicated F16 curve exactly reproduces the old 0.684375
minimum at ef=128 and exceeds 0.98 in all ANN modes at ef=512. Full
Python validation passes 118 cases, and a compiled Mojo probe checks six native
generator/Python input parity cases. No core-engine change was made for this
baseline. See `docs/benchmarks/2026-09-30-qdrant-comparison.md`.

The complete goal must also resolve the measured cold/open lifecycle gap: after
below-threshold replacements/deletes and flush, a segmented graph with delta is
not `checkpoint_ready`, so the manifest has no HNSW sidecar and recovery rebuilds
the graph. At 8192 × 1536 this costs about 75–76 seconds. The baseline records
that cost; adding unmeasured pre-close maintenance is not a valid fix. Keep this
finding in the M5/M6 completion audit along with warm-query performance, typed
field coverage, mixed writes/maintenance and non-resident behavior.

## #60 official-sort findings (2026-10-01, implemented and verified)

The pinned official stable sort now replaces the three metadata heapsorts.
Comparable entries reuse their existing ordering and the copy probe confirms
zero entry copies through insertion/merge paths. Default quicksort was rejected
based on organ-pipe timing and its unbounded partition-depth behavior. Stable
sorting introduces one temporary descriptor array, 72 bytes/keyword entry or
40 bytes/numeric entry, with the numeric arrays allocated sequentially.

The final 60 paired cells across three trials preserve encoded entry checksums;
median sort time is 0.298–0.974 of the original. End-to-end 100,000-point metadata
build improves from 37.892 to 31.000 ms. Long-string keyword peak RSS increases
by 6.891 MiB at that count. All 62 targeted Mojo tests, 118 Python tests, 21 copy
probe cases, the full build and three examples pass. See
`docs/benchmarks/2026-10-01-metadata-sort.md`. Changes remain uncommitted. Continue
with #61 heap suitability, #62/#63, typed-field migration and M5/M6; the warm
query and delta/checkpoint reopen gaps measured by #59 are still unresolved.

## #61 official-heap findings (2026-10-01, evaluation complete)

Retain all three production heaps. The compiled public-API Top-K candidate
preserves the 16-byte entry and passes 60 oracle/bit/reuse cases. It is faster
in 28 of 32 matrix cells, but four k=1 replacement-heavy cells regress. The
larger five-trial confirmation remains 12.7–14.2% slower, so the explicit
no-latency-regression adoption gate fails. The existing HNSW scratch contract
also requires reserve on an existing heap and actual retained capacity, while
bounded results use direct root replacement. These are absent from the pinned
public API, as confirmed by source and three negative compiler probes.

The reproducible benchmark, 232 raw timing runs, source hashes and 24 passing
existing tests are in `docs/benchmarks/2026-10-01-official-heap.md` and its JSON
artifact. No engine change or custom fallback was introduced. This completes
#61's conditional evaluation, not M5/M6 performance. Continue with #62 bounded
WAL decoding, #63 read-only copies, typed fields and the full remaining goal.

## #62 recovery and API findings (2026-10-01, implemented and verified)

Before #62, dense preflight read the complete WAL, cloned it for decoding,
cloned every envelope and payload range, and could clone the entire valid prefix
for tail repair. Collection open traversed `dense_wal.records` three ways:
apply dense authoritative mutations (copying values/fields into the MemTable),
merge dense deletes by sequence with sparse WAL, and replay newer mutations into
a committed HNSW sidecar. A streaming replacement must preserve all three;
merely replacing the first full-file read does not finish the recovery work.

`test_collection_config_migration.mojo` explicitly requires a later corrupt
sparse source to leave the torn dense WAL and collection identity untouched.
Keep all durable repair/config publication after successful complete preflight.
Old-version, invalid-header/length, CRC, sequence, torn-v3-envelope and append
repair semantics must stay aligned with the existing decoder. The v3 format's
256 MiB envelope limit is a real bound, not permission to call an entire-WAL
allocation bounded. The public owned replay/decode APIs still need owned output;
separate that output cost from transient decoding memory in measurements.

The pinned compiler successfully compiles an origin-parameterized byte reader,
zero-copy subspans with pointer identity, and `String(from_utf8=span)`; subtraction
based bounds reject negative/Int.MAX requests without offset overflow. A returned
local-owner view cannot be converted to a static-origin reader. However, a List
`clear()` while a stored view remains live is *not* rejected by this compiler;
that unsafe mutation probe was compiled, not run. Do not assume origins freeze
an owner's allocation. Decode inside a scoped immutable borrow and finish every
view before resizing/refilling its buffer; do not expose a record view across
cursor advance. See `docs/research/2026-10-01-borrowed-wal-api-probe.mojo` and its
JSON evidence.

The Mojo 1.0 FileHandle source supports `read(Span)` with short reads, seek and
rw mode, but no public truncate. The compiled I/O probe verifies bounded read/
EOF, POSIX descriptor ftruncate plus the existing fsync helper, and append after
repair. Production repair must open the existing WAL without accidental create,
validate the accepted lengths, and remain deferred until all authoritative
sources and matching sidecars pass recovery. Local RocksDB reference commit
`6dbb6f30e604e0047db29f06fe1c28c348074c98`, `db/log_reader.h:77`, provides the
matching buffer-lifetime pattern: a returned record view expires before the
reader/scratch is mutated. Do not adopt its CRC polynomial or block format.

Implement #62 as working interface slices: (1) shared primitive reads plus an
origin-backed reader and span payload decode, preserving owned entry points;
(2) bounded envelope I/O, borrowed record decode and length-based deferred tail
repair with compatibility/crash tests; (3) integrate the three recovery consumers
without retaining every historical dense payload, then measure large-WAL peak
memory and recovery time. This expands the original file estimate because the
actual callers include document codec and collection recovery. Keep #62 unchecked
until the final integration and required measurements are complete.

The three #62 interfaces are now implemented. Dense recovery merges bounded
envelopes with sparse mutations, moves accepted vector/payload allocations into
authority, and re-reads a bounded pass for matching HNSW sidecars. The fixed
64 KiB read-ahead removes the small-record regression of the initial two-read
cursor. Forty-two paired runs and 1,853 before/after malformed/valid corpus cases
pass. All 98 CPU files (789 Mojo tests), 118 Python, 19 crash, C ABI, build,
three examples and both quality gates pass. See
`docs/benchmarks/2026-10-01-borrowed-wal.md` for measurements and limits. #62 is
complete in the worktree, still uncommitted. #63, typed-field migration and
M5/M6 remain in the full goal; this does not close the missing-sidecar open gap.

## #63 current-call-path findings (2026-10-01, implemented and verified)

Before #63, `authoritative_index_checksum` called `MemTable.entry_at`, but #49 changed
`MemTableEntry.clone` to share immutable field owners. It no longer copies all
dense/payload bytes at that call: the remaining cost is a descriptor copy,
reference-count traffic and temporary empty Arc allocations through
`dense_descriptor`. Use the existing immutable `entry_ref_at` and keep the exact
fingerprint byte order. Full fingerprint serialization and payload encoding are
separate costs; do not report their removal for this slice.

Before #63, `_upsert_sparse_unlocked` called the owned `MemTable.get` just to test
existence. That path creates vector/payload Lists; the pinned String implementation
shares heap string data with COW, so payload content length is not physical copied
bytes. `ordinal_for` plus
`is_live_at` already provides the needed lookup under the existing writer lock.
Preserve validation order, failure sequence, negative IDs and tombstone behavior.
The #39 large-payload flush workload and a direct sparse-update workload can
measure the two changes separately. No new lookup structure or format is needed.

Both substitutions are now implemented. All 49 targeted Mojo and 118 Python tests
pass after rebuilding the binding. Independent frozen checksums and all seven
flush pairs preserve durable bytes. The 48 direct timing runs and six instrumented
runs confirm removal of both call paths without a broad sparse throughput claim;
String COW explains why logical payload size is not a memcpy count. See
`docs/benchmarks/2026-10-01-readonly-copies.md`. #63 is complete in the worktree,
uncommitted. Continue with the field catalog/named-F32 durable contract and
reader-first migration; native scalar, binary, multivector, M5/M6 and final
integration remain in scope.

## Named-field migration entry (2026-10-01, in progress)

Current caller and local Qdrant-reference findings, the selected point/field
boundary and migration publication requirements are recorded in
[the migration design](2026-10-01-named-vector-migration-design.md). In particular,
legacy sparse updates do not advance dense entry sequences, and a catalog-only
side file would not prevent an old writer from opening the collection. The catalog
metadata specification, independent fixtures and standalone codec/file reader are
now implemented: 10 new catalog tests plus 28 existing identity/migration tests
pass. See [the reader checkpoint](../research/2026-10-01-field-catalog.md).
Production collection open and writers remain unchanged. The next slice must
resolve point/WAL/segment bytes and replay ordering, add independent record
fixtures, and implement record readers before enabling new writers. No complete
named/native type support or runtime format migration is claimed by this checkpoint.

The next reader-first slice now supplies the immutable typed field/point model,
pure partial-mutation transition, and complete point record codec. It preserves
legacy document sequence independently of the point-wide migration watermark.
Six independent fixtures preserve all native scalar bits, packed binary and
variable-row matrices. All 19 new tests and 21 existing catalog/payload/sparse
tests pass; compiler probes reject mutation through both vector and payload views.
See [the point record checkpoint](../research/2026-10-01-point-records.md).
This is not runtime type support or durable combined writes. Field-aware WAL and
segment envelopes, bounded mixed replay, publication, APIs/search and full M5/M6
remain required before final integration.
