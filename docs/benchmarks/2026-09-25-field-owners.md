# #49: Independent payload/sparse owners and one field resolver

Date: 2026-09-25. Engine, tests and cost harness: the #49 working tree on
`feat/48-bounded-generation-head` (on top of `04569ad`).
Platform: Apple M4 Pro, macOS arm64; Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

- **Point state**: `MemTableEntry` holds three shared owners: dense
  `ArcPointer[List[Float32]]`, payload `ArcPointer[List[DocumentField]]` and an
  optional sparse `ArcPointer[List[SparseElement]]`. `fields()` and `sparse()` are
  readonly borrows. A sparse write replaces only the sparse owner. A document or
  vector write replaces dense and payload and keeps sparse. A delete clears the
  whole point, so a reinsert starts with no sparse field.
- **Runs**: the base and each sealed run build a `RunIndex` (a metadata index plus a
  sparse index) over their own slots, once, at build or seal time. The frozen head
  has no index: capture copies only its descriptors.
- **Resolver**: `ReadGeneration.filtered_ordinals`, `conditioned_ordinals` and
  `sparse_hits` are the only field paths. Indexed runs evaluate the index and then
  drop non-visible slots. The head is evaluated directly (the linear filter evaluator
  and a term merge). Both sum sparse products in ascending query-term order, so a row
  scores bit-identically in any run. Filtered, NOT, where-batch, device where-batch,
  sparse, sparse-where and hybrid all go through the resolver. Sparse hits from every
  run merge into one `BoundedTopK` (score first, smaller ID on ties).
- **Publisher**: records every accepted operation, sparse-only writes included, with
  the collection's accepted sequence. It refuses to publish a root when that sequence
  does not match. It no longer holds or clones a collection-wide `SparseIndex`.
- **Durability fix**: before this change, a reopen revived the old sparse field of a
  deleted and reinserted point. It came back both from the WAL tail and from a sparse
  checkpoint. Now recovery merges dense WAL deletes into sparse WAL replay by
  sequence, and a runtime delete queues a sparse delete record for the next sparse
  checkpoint. The dense and sparse WAL formats are unchanged.

## Remaining limits

- **Writer-side sparse duplicate**: the writer keeps its own `SparseIndex` for sparse
  checkpoints next to the entry owners. That costs one extra element copy per sparse
  write. It is not a capture cost.
- **No public payload-only write**: adding one would need a WAL record kind. Payload
  owner independence is tested at the publisher by replacing only the payload owner.
- **Rollover and consolidation cost more**: they now also build a sparse index, and
  consolidation rebuilds the base's metadata and sparse indexes. See the writer table;
  #52 tracks moving consolidation off the writer path.
- **Query latency** across up to ten layers with direct head evaluation was not
  benchmarked in this slice.

## Capture and writer cost

[Raw results](results/2026-09-25-field-owners-cost.json): same harness, cells and
fixture as [#48](2026-09-24-bounded-head.md): three fresh processes per cell, 4,096
points, F32 dimension 128, 256-byte text payload, two sparse elements per point.
Each dense or sparse operation is now recorded separately, as the collection does.
There is one new audit, `field_owner_copies`: visible rows whose payload or sparse
owner address differs from the writer table's. Sparse bytes are now
12 bytes per element copied into a run index; before, they were 8 + 12 per element
of the whole cloned index.

### First base

Every cell has a median of 2.15–2.34 ms: 4,096 descriptors, 1,064,960 payload bytes
(into the metadata index only, down from 2,129,920) and 98,304 sparse bytes. Dense
bytes are 0 and field-owner copies are 0.

### Captures after the base

| Writes | Delta per capture | Held snapshots | Capture median (max) ms | Dense bytes | Field-owner copies | Descriptors | Payload bytes | Sparse bytes | All captures ms | Held RSS increase MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dense+sparse | 0 | 8 | <0.001* (0.001) | 0 | 0 | 0 | 0 | 0 | 2.311 | 3.391 |
| dense+sparse | 16 | 8 | 0.003 (0.005) | 0 | 0 | 16 | 0 | 0 | 2.212 | 3.406 |
| dense+sparse | 1,024 | 8 | 0.003 (0.008) | 0 | 0 | 4 | 0 | 0 | 2.351 | 15.344 |
| dense+sparse | 1,024 | 10 | 0.003 (0.005) | 0 | 0 | 5 | 0 | 0 | 2.321 | 20.766 |
| dense only | 0 | 8 | <0.001* (0.001) | 0 | 0 | 0 | 0 | 0 | 2.267 | 3.391 |
| dense only | 16 | 8 | 0.003 (0.004) | 0 | 0 | 16 | 0 | 0 | 2.193 | 3.406 |
| dense only | 1,024 | 8 | 0.001 (0.001) | 0 | 0 | 0 | 0 | 0 | 2.331 | 14.797 |
| dense only | 1,024 | 10 | 0.001 (0.001) | 0 | 0 | 0 | 0 | 0 | 2.349 | 20.016 |

\* Below the timer's observed 1 µs resolution.

Copy columns are medians per capture. With dense+sparse writes at 1,024 points, a
few sparse operations land after the seal, so a small head remains to freeze.

Compared with #48 at 16 changed points × 8 snapshots, dense+sparse:

| Metric | #48 | #49 |
|---|---:|---:|
| Repeated capture | 0.691 ms | 0.003 ms |
| All captures | 7.295 ms | 2.212 ms |
| Held RSS | 11.516 MiB | 3.406 MiB |
| Sparse bytes copied per capture | 131,072 | 0 |
| Payload bytes copied per capture | 8,320 | 0 |

Dense-only capture is unchanged within noise (0.007 → 0.003 ms).

### Writer side (captures after the base)

| Writes | Delta × captures | Record total ms | Max single write ms | Rollovers (ms) | Consolidations (ms) | Descriptors | Payload bytes | Sparse bytes |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| dense+sparse | 16 × 7 | 0.091 | 0.013 | 0 | 0 | 224 | 0 | 0 |
| dense+sparse | 1,024 × 7 | 8.270 | 0.657 | 7 (3.942) | 0 | 14,336 | 1,863,680 | 172,032 |
| dense+sparse | 1,024 × 9 | 12.844 | 2.933 | 9 (4.329) | 1 (2.933) | 22,528 | 3,462,136 | 319,488 |
| dense only | 16 × 7 | 0.057 | 0.014 | 0 | 0 | 112 | 0 | 0 |
| dense only | 1,024 × 7 | 5.626 | 0.560 | 7 (3.397) | 0 | 7,168 | 1,863,680 | 172,032 |
| dense only | 1,024 × 9 | 9.716 | 2.881 | 9 (3.877) | 1 (2.881) | 13,312 | 3,462,144 | 319,488 |

Recording no longer copies payload. Payload is copied once, into a run's metadata
index at seal, which halves the per-point payload copies: 1,024 × 9 dense-only went
from 6,924,288 to 3,462,144 bytes. The costs moved to
rollover and consolidation:

- **Rollover**: 7 rollovers take 3.4–3.9 ms, against 2.3 ms in #48. The extra time
  is the per-run sparse index build.
- **Consolidation**: 2.9 ms, against 2.0 ms, because the base is now rebuilt with its
  sparse index.
- **Descriptors**: dense+sparse doubles the descriptor records, because each sparse
  operation is recorded as its own point state.

All of these costs are bounded per operation and sit on the writer path, not on
capture.

Reproduce:

```sh
mkdir -p .build/field-owners-49
pixi run mojo build -I src benchmarks/mojo/phase11_bench.mojo -o .build/field-owners-49/phase11-bench
pixi run python benchmarks/snapshot_cost.py --binary .build/field-owners-49/phase11-bench --source <revision> --output docs/benchmarks/results/2026-09-25-field-owners-cost.json
```

## Validation

| Gate | Result |
|---|---|
| `pixi run test` | 668 Mojo tests and 66 Python tests pass (the same two deprecation warnings). |
| `pixi run test-crash` | 9 tests in 5 files pass, including sparse checkpoint ordering. |
| `pixi run test-gpu` | 10 tests in 4 files pass on Apple M4 Pro (the device where-batch now uses the resolver). |
| `pixi run test-c` | The C ABI build and C executable pass. |
| `pixi run build-mojo` | Passes. `phase11`, `phase12`, `phase13_gpu`, `batch_query`, `gpu_pipeline` and `lookup` benchmarks compile. |
| Snapshot cost harness | All 42 runs pass visibility, sequence, payload, sparse and zero-pin checks, with 0 dense and 0 field-owner copies. |

HNSW quality gates were not rerun: no HNSW code changed.

New `tests/mojo/test_generation_fields.mojo` (3 tests):

- **Owner identity**: sparse-only, payload-only and full replacement each replace
  exactly the expected owners. Delete plus reinsert has no sparse owner. Five roots
  coexist, each with its own scores and filter results.
- **Owned oracle**: 1,600 points, IDs −800…799. Some points have no payload, and
  sparse weights are chosen for exact Float32 ties and multi-term accumulation.
  Three rounds of payload/dense replacement, sparse-only updates, deletes and
  reinserts (more than 2 × 1,024 writes) give roots with a base, sealed runs and a
  frozen head. Every captured root is checked against its own copy of the oracle:
  - sparse Top-K (25 and all)
  - sparse where and NOT
  - dense where, NOT and filtered
  - hybrid, and hybrid with NOT
  - `sparse_records`

  All are compared exactly (IDs and Float32 scores). The same checks run again after
  flush, and after close and reopen.
- **Failed sparse writes**: a write to a missing ID, an empty vector or unsorted
  terms leaves the sequence, the root identity and the publisher revision unchanged.

`test_persistent_sparse.mojo` adds delete → reinsert → reopen from both the WAL tail
and a sparse checkpoint, plus a second flush/reopen. Before the recovery fix it
failed on the first reopen. `test_generation_delta.mojo` now asserts that a
sparse-only update refreezes only the head and keeps the dense and payload owners.
