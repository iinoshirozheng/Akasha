# #47: Shared roots for unchanged snapshots

Date: 2026-09-17. Engine, tests and cost harness: `dc858ab`.
Platform: Apple M4 Pro, macOS arm64; Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

`PersistentCollection.snapshot()` now uses a collection-local `ReadGenerationCache`
under the existing writer lock. A `ReadGeneration` records accepted sequence,
manifest generation, configuration and local revision, and owns an immutable
`ReadBase` containing aligned MemTable, metadata and sparse state. The base has a
separate owner so subsequent bounded head/sealed runs can sit alongside it as
specified by [ADR 0007](../adr/0007-generation-field-ownership.md).

Unchanged captures retain the same root allocation. Writes invalidate the cache;
manifest publications invalidate it even when sequence is unchanged. Background
compaction shares the publisher and drops its cached owner before retiring input
files. Each collection open has a separate publisher; root allocation identity
uses the official `is` operation, not value equality.

A root owns one generation pin. The collection cache and snapshot handles each
hold a strong owner. Closing a handle immediately drops that handle's owner;
remaining snapshots continue to work after replacements, deletion/reinsertion,
flush, compaction, or collection close. The last root owner releases its pin.
Closing every snapshot while leaving the collection open intentionally retains
one cached base until a write, layout publication, or collection close.

Read methods borrow the base immutably and still return independent owned documents
and exports. The compile-only negative probe rejects calling `apply_upsert` through
`ReadSnapshot._base()`. This does not claim safety for arbitrary concurrent close
of the same handle; operation/export leases are #50/#58.

Ownership uses [official Mojo ArcPointer](https://mojolang.org/docs/std/memory/arc_pointer/ArcPointer/).
No custom reference counter, allocator, dependency, or durable-format change was
introduced. GPU state remains per snapshot handle, with the existing collection
GPU cache and scratch locking. A new real-device regression verifies that closing
a sibling and the collection does not release the surviving handle's warm cache.

## Remaining boundary

The first capture after a write still clones the complete MemTable/SparseIndex
and rebuilds metadata. #47 does not implement bounded delta capture, independent
field sharing, an exported zero-copy buffer API, or Qdrant speed parity. #48/#49
implement the head/delta and field visibility work; #50 handles operation leases
and the next GPU ownership boundary. Public `ReadSnapshot.capture` remains a
standalone base capture; repeated collection captures use the shared publisher.

## Capture cost

[Raw results](results/2026-09-17-shared-snapshot-cost.json): three isolated fresh
processes per cell, 4,096 points, F32 dimension 128, 256-byte text payload, two sparse
elements per point; all captures stay alive through the RSS measurement. Every
capture verifies its old dense/payload/sparse values and accepted sequence.

This isolates `ReadGenerationCache.acquire`, the publisher used by the collection,
and snapshot-handle construction. It excludes collection manifest I/O, writer-lock
acquisition, fixture construction and compilation. Per-handle bookkeeping/device
state still allocates; “0 copied bytes” means no additional authoritative base copy.

| Delta per capture | Held snapshots | Base builds | First capture (ms) | Repeated capture median (ms) | All captures (ms) | Logical content copied (MiB) | Held RSS increase (MiB) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | 1 | 2.865 | — | 2.865 | 3.094 | 5.453 |
| 0 | 8 | 1 | 2.807 | <0.001* | 2.808 | 3.094 | 5.453 |
| 16 | 1 | 1 | 2.700 | — | 2.700 | 3.094 | 5.469 |
| 16 | 8 | 8 | 2.911 | 2.534 | 20.967 | 24.750 | 38.922 |

\* The timer returned zero for the median warm sample at its observed 1 µs
resolution. This is below that measurement resolution, not a claim of zero time.
The eight-capture total includes the first base build. Copy bytes are the source-
derived logical-content lower bound (vectors + text + sparse values), excluding
metadata/index duplication, padding and allocator bookkeeping.

At zero delta, eight held captures now copy one base (3.094 MiB), versus eight bases
(24.750 MiB) in the [pre-#47 baseline](../research/2026-09-07-generation-costs.md).
Each subsequent unchanged capture adds **0 authoritative copied bytes**. At 16
changed points per capture, eight bases are still built: 24.750 MiB copied and
20.967 ms total. This explicitly remains the #48/#49 problem.

Closing snapshot handles leaves the collection-style publisher's one cache owner.
The harness then invalidates that cache and asserts zero active pins. RSS may remain
high after all owners are released because the allocator retains freed pages;
RSS alone is not a leak or reclamation proof.

Reproduce with the engine/harness revision above:

```sh
mkdir -p .build/shared-snapshot-47
pixi run mojo build -I src benchmarks/mojo/phase11_bench.mojo -o .build/shared-snapshot-47/phase11-bench
pixi run python benchmarks/snapshot_cost.py --binary .build/shared-snapshot-47/phase11-bench --source dc858ab --output docs/benchmarks/results/2026-09-17-shared-snapshot-cost.json
```

## Validation

[Machine-readable validation](results/2026-09-17-shared-snapshot-validation.json).
All commands exited successfully unless marked as an expected compiler rejection.
Local full logs are under `.build/shared-snapshot-47/`.

| Gate | Result |
|---|---|
| `pixi run test` | 656 Mojo tests in 83 files; 66 Python tests. Two deprecation warnings: Starlette/httpx and `Collection.__module__`. |
| `pixi run test-crash` | 9 tests in 5 files; dense batch torn-write, checkpoint and sparse checkpoint ordering preserved. |
| `pixi run test-gpu` | 10 tests in 4 files on Apple M4 Pro, including shared-root sibling close with a surviving warm device cache. |
| `pixi run test-c` | C ABI library build and C executable passed. |
| `pixi run build-mojo` | All three examples built. Python shared library build already passed in `test`; that unchanged result is reused. |
| `pixi run check-hnsw-quality` | All 6 smoke cells recall 1.0. |
| `pixi run check-post-hnsw-quality` | All 11 cells satisfy recall ≥ 0.95; selective queries retain the existing exact fallback, so this is not an ANN-only speed comparison. |
| Snapshot cost harness | All 12 fresh-process runs passed old-view visibility, sequence and final pin checks. |
| Readonly base compile probe | Mutation through the returned base reference rejected, as expected. Source and diagnostic are recorded in validation JSON. |

New CPU regressions cover same-allocation sharing and owner counts, owned-get
independence, sibling/collection close, equal generation with changed sequence,
replacement/sparse update/delete/reinsert, layout-only publication, separate
collection opens, RAII release, failed capture, concurrent unchanged captures,
and background publication releasing the cached pin. Existing batch/concurrency,
filter/sparse/hybrid, backup and durable-format tests remain passing.
