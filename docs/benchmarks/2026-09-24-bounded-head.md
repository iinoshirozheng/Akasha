# #48: Bounded head over shared dense owners

Date: 2026-09-24. Engine and tests: `8351235`; cost harness: `09fe0ff`.
Platform: Apple M4 Pro, macOS arm64; Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

An accepted write moves its Float32 list into an immutable `ArcPointer` dense owner
in the writer MemTable. Clones, descriptors, runs and the GPU flat table share that
owner; `MemTableEntry.values()` returns a readonly borrow tied to the entry, and no
new escaping span/pointer API was added. Owned `get`/`documents` results still copy.

`ReadGenerationCache` is now the collection publisher, still under the writer lock:

- **Base run**: built once from the writer table (descriptor + payload copies and
  metadata index; dense owners shared).
- **Mutable head**: after each committed dense write, the publisher records the
  latest point-state descriptor for that ID. It is never shared.
- **Rollover**: at 1,024 points or 4 MiB of new dense+payload content, the head is
  moved (not copied) into an immutable sealed run and its metadata index is built.
  A record that would overflow a non-empty head seals the head first, so a legal
  oversized record gets its own run. No new rejection condition exists.
- **Capture**: shares the base and sealed runs. When the head is non-empty, it
  freezes one copy of just the head descriptors, reused by all captures until the
  next write. Per-layer hidden ordinals are shared, replace-on-write lists for sealed
  shadowing plus a bounded per-capture list for the head.
- **Consolidation**: once eight sealed runs exist, the publisher rebuilds the base
  from the writer table in the foreground (dense owners shared) and drops the chain.
  This is the writer stall measured below; #52 moves it to the worker.

Reads resolve head, sealed runs newest first, then base. `find` returns the newest
state, and a tombstone means absent. Exact, filtered, controlled, parallel, batch,
where-batch, sparse-where and hybrid paths remove shadowed and tombstoned rows per
layer **before** filtering and each layer's Top-K. The per-layer heaps merge by the
same total order (score, then lower ID), so the merge is exact. SQ8/PQ training and
`documents` use one id-ordered walk over the resolved locations.

A dense batch is recorded only after the whole staged MemTable/metadata swap, so no
capture can observe a partial envelope; captures see the batch's final sequence.
A sparse-only write replaces only the sparse owner at the next capture; dense runs
remain the same allocations. Validation failures happen before WAL/memtable/publisher
changes, so the old root survives. A publisher fault after a committed write cannot
reject the write: it resets derived state and the next capture rebuilds a base. If
a dense write was never recorded, `acquire` refuses to publish rather than serve a
stale view.

The Mojo-level `ReadSnapshot.capture` was removed, and benchmarks capture through the
same publisher. `MemTableEntry.values` is now a readonly accessor instead of a field.
The collection closes by resetting the publisher, and held roots keep their runs.
No durable format, WAL, Python API or C ABI changed.

## Remaining boundary

- **Sparse (#49)**: the publisher still holds one collection-wide `SparseIndex`. After
  any sparse write, the next capture clones it all (131,072 logical bytes and ~0.7 ms
  at 4,096 points). With dense+sparse writes, this is now nearly all capture time.
- **Payload (#49)**: descriptors still own payload copies. Each recorded write clones
  its payload into the head, and its metadata index clones it again at rollover. The
  base build copies all payload twice (descriptors plus metadata index).
- **Consolidation stall (#52)**: an O(live points) foreground rebuild inside a write
  (2.0 ms at 4,096 points). Rollover is a smaller bounded stall (~0.33 ms per 1,024
  points).
- **GPU flat table (#50)**: a layered snapshot's first device query builds one flat
  descriptor table per handle (dense owners shared, payload omitted). A single
  unshadowed base is reused directly.
- **Batch staging (untracked, writer path)**: `apply_batch` still clones the writer
  MemTable descriptors/payload and rebuilds its metadata index for every batch to
  keep the atomic swap. After #48 this no longer copies dense bytes. It is not a
  capture cost and was not changed here.
- Query latency across up to ten layers was not benchmarked in this slice.

## Capture and writer cost

[Raw results](results/2026-09-24-bounded-head-cost.json): three isolated fresh
processes per cell, 4,096 points, F32 dimension 128, 256-byte text payload, two sparse
elements per point. Every changed point is rewritten (dense+payload, and sparse when
the mode says so) and recorded through the publisher, exactly as the collection does
after its WAL commit. All captures stay alive through the RSS measurement; every one
verifies its dense/payload/sparse values, accepted sequence and visible count, and
zero pins remain after the publisher reset.

`dense_copy_bytes` is an **identity audit**: after each capture, every visible row's
dense owner address is compared with the writer table's accepted owner, and a mismatch
counts that row's bytes. Descriptor, payload and sparse counts come from publisher
stats (logical content: payload names + string bytes, sparse 8 + 12 per element;
padding, index structure and allocator metadata excluded). Time excludes WAL, manifest
I/O, writer-lock acquisition, fixture construction and compilation.

### First base

Identical in every cell (median 2.39–2.63 ms): 4,096 descriptors, 2,129,920 payload
bytes (text into descriptors and again into the metadata index), 131,072 sparse bytes,
and **0 dense bytes**. The 2 MiB of vectors are shared, not copied as before #47/#48.

### Captures after the base

| Writes | Delta per capture | Held snapshots | Capture median (max) ms | Sparse clone ms | Dense bytes | Descriptors | Payload bytes | Sparse bytes | All captures ms | Held RSS increase MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dense+sparse | 0 | 8 | <0.001* (0.001) | — | 0 | 0 | 0 | 0 | 2.472 | 4.531 |
| dense+sparse | 16 | 8 | 0.691 (0.716) | 0.761 | 0 | 16 | 8,320 | 131,072 | 7.295 | 11.516 |
| dense+sparse | 1,024 | 8 | 0.722 (0.741) | 0.770 | 0 | 0 | 0 | 131,072 | 7.550 | 21.266 |
| dense+sparse | 1,024 | 10 | 0.715 (0.741) | 0.759 | 0 | 0 | 0 | 131,072 | 8.931 | 27.141 |
| dense only | 0 | 8 | <0.001* (0.001) | — | 0 | 0 | 0 | 0 | 2.447 | 4.531 |
| dense only | 16 | 8 | 0.007 (0.009) | — | 0 | 16 | 8,320 | 0 | 2.471 | 4.562 |
| dense only | 1,024 | 8 | <0.001* (0.001) | — | 0 | 0 | 0 | 0 | 2.454 | 13.109 |
| dense only | 1,024 | 10 | <0.001* (0.003) | — | 0 | 0 | 0 | 0 | 2.471 | 17.047 |

Copy columns are medians per capture. “All captures” includes the first base.
\* Below the timer's observed 1 µs resolution; not a claim of zero time.
With 1,024 changed points the head seals exactly at the limit during the writes, so
capture has no head to freeze; that work is charged to rollover below, not hidden.
The sparse-clone column is a separate standalone `SparseIndex.clone()` right after the
capture, which attributes the dense+sparse capture time to the sparse owner.

Against the [#47 baseline](2026-09-17-shared-snapshot.md) at 16 changed points × 8
snapshots: repeated capture went from 2.534 ms to 0.691 ms (dense+sparse) and 0.007 ms
(dense only). All captures went from 20.967 ms to 7.295 / 2.471 ms, and held RSS from
38.922 to 11.516 / 4.562 MiB. #47 rebuilt eight bases (24.750 MiB of logical content);
now there is one base, and later captures copy 0 dense bytes.

### Writer side (captures after the base)

| Writes | Delta × captures | Record total ms | Max single write ms | Rollovers (ms) | Consolidations (ms) | Descriptors | Payload bytes |
|---|---|---:|---:|---:|---:|---:|---:|
| dense+sparse | 16 × 7 | 0.039 | 0.009 | 0 | 0 | 112 | 29,120 |
| dense+sparse | 1,024 × 7 | 3.752 | 0.411 | 7 (2.341) | 0 | 7,168 | 3,727,360 |
| dense+sparse | 1,024 × 9 | 6.349 | 2.018 | 9 (2.585) | 1 (2.018) | 13,312 | 6,924,288 |
| dense only | 16 × 7 | 0.043 | 0.010 | 0 | 0 | 112 | 29,120 |
| dense only | 1,024 × 7 | 3.766 | 0.405 | 7 (2.319) | 0 | 7,168 | 3,727,360 |
| dense only | 1,024 × 9 | 6.568 | 2.022 | 9 (2.547) | 1 (2.022) | 13,312 | 6,924,288 |

The first capture's writes precede the base and are excluded (the publisher skips
recording until a base exists). Rollover time counts the writes that sealed a run
without consolidating. Consolidation time is the one write that sealed the eighth run
and rebuilt the base: 1,024 head + 4,096 base descriptors, with dense owners shared.
Per changed point, the writer copies one descriptor and 520 payload bytes (head plus
rollover metadata).

RSS may stay high after owners are released because the allocator keeps freed pages;
RSS alone is not a leak or reclamation proof.

Reproduce with the harness revision above:

```sh
mkdir -p .build/bounded-head-48
pixi run mojo build -I src benchmarks/mojo/phase11_bench.mojo -o .build/bounded-head-48/phase11-bench
pixi run python benchmarks/snapshot_cost.py --binary .build/bounded-head-48/phase11-bench --source 09fe0ff --output docs/benchmarks/results/2026-09-24-bounded-head-cost.json
```

## Validation

[Machine-readable validation](results/2026-09-24-bounded-head-validation.json), run
against `09fe0ff`. All commands exited successfully unless marked as an expected
compiler rejection. Local full logs are under `.build/bounded-head-48/`.

| Gate | Result |
|---|---|
| `pixi run test` | 664 Mojo tests in 84 files; 66 Python tests. The same two deprecation warnings as #47. |
| `pixi run test-crash` | 9 tests in 5 files, including dense batch torn-write, checkpoint and sparse checkpoint ordering. |
| `pixi run test-gpu` | 10 tests in 4 files on Apple M4 Pro, including sibling close with a surviving warm device cache. |
| `pixi run test-c` | C ABI library build and C executable passed. |
| `pixi run build-mojo` | All three examples built; the Python shared library build passed inside `test`. `batch_query`, `gpu_pipeline` and `phase12` benchmarks also compile. |
| `pixi run check-hnsw-quality` | All 6 smoke cells recall 1.0. |
| `pixi run check-post-hnsw-quality` | All 11 cells final recall 1.0 (≥ 0.95); selective queries keep the existing exact fallback. |
| Snapshot cost harness | All 42 fresh-process runs passed visibility, sequence, visible-count and zero-pin checks. |
| Readonly view compile probe | Calling `apply_upsert` on `snapshot._view().run(0).memtable` is rejected as expected. |

`tests/mojo/test_generation_delta.mojo` adds 8 tests:

- **0/16/1,024 deltas**: the base stays the same allocation, `base_builds` stays 1,
  there is no dense copy by owner identity, and untouched IDs keep their dense address.
- **Rollover and consolidation**: a 1,024-point rollover; a legal oversized record
  (4 MiB + 1 KiB payload) gets its own run and first seals the small head; the
  sealed-run and head bounds always hold; consolidation shares dense owners with the
  writer; old roots keep their chains.
- **Old snapshots survive**: replace, delete, reinsert, sparse update, nine
  1,024-point batches with consolidation, and collection close.
- **Sparse-only update**: every layer run is shared, zero descriptors are copied,
  sparse data is isolated, and mutating an owned `get` result changes nothing else.
- **Atomic batch across rollover**: a 1,501-mutation batch that spans a rollover is
  seen whole or not at all, with the correct sequence.
- **Failure before publication**: failed batch and upsert keep the root identity,
  revision and stats. A post-commit publisher fault resets and rebuilds; a missed
  dense write refuses to publish.
- **Close/RAII**: pin release with layered roots.
- **Shadowing before filter/Top-K**: an updated best row or a deleted row never
  appears, and snapshots with the same generation but different sequences give
  different answers. Device tables are per handle and per layout; closing one
  releases only its own table.

Every layered snapshot is compared against a single-base reference view built from
the same writer state. The comparison covers dot/L2/cosine, filtered, parallel,
batch, where-batch, controlled, SQ8, device CPU-fallback, sparse-where, hybrid and
`documents`.
