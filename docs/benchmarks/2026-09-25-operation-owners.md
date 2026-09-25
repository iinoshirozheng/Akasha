# #50: Operation owners, close and root-owned device state

Date: 2026-09-25. Engine, tests and cost bench: the #50 working tree on
`feat/48-bounded-generation-head` (on top of `e530f69`).
Platform: Apple M4 Pro, macOS arm64; Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

- **Operation owner**: every public `ReadSnapshot` method first calls `_acquire()`. It
  copies the root's `ArcPointer` under the handle's lock, releases the lock, and
  then reads only through that copy. Private helpers take the root as a
  `ReadGeneration` argument. The handle's borrowed `_view()` is removed, so no
  query reads through a borrow of the handle's slot.
- **Handle slot**: the root owner and its `BlockingSpinLock` share one heap slot
  (`ArcPointer[_RootSlot]`). A first version kept both inline in the handle. There,
  a close racing 15 query tasks read a freed run once per test run
  ("candidate bitmap does not align with run slots", with a garbage slot count).
  With the slot on the heap, the same test passed every repeated run.
- **Close**: `ReadSnapshot.close()` takes the owner out under the lock and drops it
  after releasing the lock. Close is idempotent, and later calls fail with
  "snapshot is closed". `PersistentCollection.close()` takes the cached root out
  under the writer lock and drops it after, next to the existing maintenance
  drain outside the lock. Whoever releases the last owner frees the rows, the
  device state and the generation pin.
- **Collection queries**: exact, filtered, where, sparse, sparse-where, hybrid and
  device queries no longer read the writer's live `MemTable`, `MetadataIndex` or
  `SparseIndex` without the writer lock. They first run the collection's own
  validation, with unchanged error messages, then run on `self.snapshot()`. The
  now-dead live paths (`_search_sparse_where`, `_search_hybrid`,
  `_search_hybrid_where`) are deleted. The locked approximate-search fallbacks
  still scan live tables under the writer lock.
- **Device state**: `ReadGeneration.device` holds one `GpuSnapshotState` (lock,
  flat table, device cache) per root. Every handle and operation on a root shares
  it, and it lives exactly as long as the root. The collection's own
  `_GpuReadSnapshot` and its resets on flush and invalidation are removed. A newer
  sequence at the same generation gets a new root and a new state. The existing
  budget trim, scratch reuse, readback lock and discard on failure are unchanged.
- **Formats**: no durable format changed.

## Remaining limits

- **Device key**: the key is the root, which fixes layout, config and the single
  dense field. It covers the device only because the process has one default
  device context. A second device would need one state per device on the root.
- **Capture per collection query**: each collection query now captures the root, and
  a capture reads `manifest.bin` to learn the generation. See the table below.
  Keeping the generation in memory at every manifest publish would remove that read.
  It touches every publish path, so it is left out of this slice.
- **Layered read cost**: on a root with sealed runs and a head, a collection where
  or sparse query now pays the #49 resolver cost that snapshot queries already
  paid. #49 did not benchmark this.

## Per-operation cost

[Raw results](results/2026-09-25-operation-owners-cost.json): new
`benchmarks/mojo/operation_owner_bench.mojo`, which uses only public API, so the
same source also builds against `e530f69`. The fixture is 4,096 points, F32
dimension 128, one boolean payload field and one sparse element per point, after
a flush. Each value is the median over 7 rounds of the mean µs per call
(200 calls per round). Values below are medians of three fresh processes, with
the process range in brackets. "Layered" runs after 1,400 alternating writes, so
the root has a base, a sealed run and a head.

| Case | Root | `e530f69` µs | #50 µs | Change |
|---|---|---:|---:|---:|
| `collection.search_dot` | base | 402.1 [400.4–412.5] | 425.0 [421.5–431.7] | +22.9 |
| `collection.search_dot_where` | base | 215.1 [214.5–218.3] | 234.3 [234.0–235.7] | +19.2 |
| `collection.search_sparse_dot` | base | 3.1 [3.1–3.2] | 18.6 [18.5–18.8] | +15.5 |
| `snapshot.search_dot` | base | 417.8 [409.9–423.6] | 411.6 [404.8–413.0] | noise |
| `snapshot.search_dot_where` | base | 218.6 [216.5–223.4] | 217.1 [216.8–219.3] | noise |
| `snapshot.search_sparse_dot` | base | 4.4 [4.3–4.4] | 4.3 [4.3–4.4] | noise |
| `collection.snapshot()` + close | base | 15.3 [14.8–15.8] | 14.6 [14.5–14.6] | noise |
| `collection.search_device_dot_batch[True]`, warm | base | 1,713.8 [1,508.5–1,883.3] | 1,552.0 [1,520.2–1,597.1] | noise |
| upsert, then `collection.search_dot` | — | 862.5 [861.5–878.5] | 970.9 [965.5–1,113.8] | +108.4 |
| `collection.search_dot` | layered | 410.4 [404.1–410.9] | 439.0 [434.7–440.3] | +28.6 |
| `collection.search_dot_where` | layered | 215.0 [213.9–218.6] | 330.0 [329.8–340.8] | +115.0 |
| `collection.search_sparse_dot` | layered | 3.1 [3.0–3.1] | 25.2 [24.9–27.0] | +22.1 |
| `snapshot.search_dot_where` | layered | 316.4 [316.1–317.9] | 319.0 [312.3–325.0] | noise |
| `snapshot.search_sparse_dot` | layered | 9.2 [9.1–9.4] | 9.2 [9.1–9.5] | noise |

What the numbers show:

- **The operation owner is free at this resolution**: snapshot queries, which now
  take the handle lock and copy an `ArcPointer` per call, did not change.
- **Collection queries pay one capture**: about 15 µs on a cached root. Of that,
  14.2 µs is `path_exists` plus `load_manifest` (a separate 2,000-call probe).
  The capture itself existed before; batch and device queries already paid it.
- **Layered where and sparse**: a collection query on a layered root costs the
  capture plus the snapshot resolver (319 + 15 ≈ 330 µs for where;
  9 + 15 ≈ 25 µs for sparse). The old live `MetadataIndex` and `SparseIndex` were
  cheaper because they read writer state without the writer lock.
- **Writes then queries**: each query after a write captures a new root (it
  freezes the head's descriptors). That adds about 108 µs per write/query pair,
  +13%.
- **Device**: the warm device batch stays a cache hit; the difference is within
  the run-to-run spread.

Reproduce:

```sh
mkdir -p .build/operation-owner-50
pixi run mojo build -I src benchmarks/mojo/operation_owner_bench.mojo -o .build/operation-owner-50/after
.build/operation-owner-50/after /tmp/akasha-50-bench
```

For the baseline, build the same source against a checkout of `e530f69` (`-I <checkout>/src`).

## Validation

| Gate | Result |
|---|---|
| `pixi run test` | 673 Mojo tests and 66 Python tests pass (the same two deprecation warnings). |
| `pixi run test-crash` | 9 tests in 5 files pass. |
| `pixi run test-c` | The C ABI build and C executable pass. |
| `pixi run build-mojo` | Passes. |
| `pixi run test-gpu` | 12 tests in 4 files pass on Apple M4 Pro, including the three #50 lifecycle tests below. |

New `tests/mojo/test_generation_close.mojo` (5 tests):

- **Acquired operation**: an owner acquired before the snapshot and the collection
  close (each closed twice) still reads all 16 rows and holds the pin. The pin is
  released when that owner is dropped.
- **Handle close racing queries**: 15 tasks run dense-where, sparse and device
  queries on the handle while task 0 closes it. The handle is the root's only
  owner. Every result is exact or "snapshot is closed", and no pins remain.
- **Collection close racing queries and writers**: 12 tasks run collection dense,
  sparse and device queries and 4 tasks upsert, while task 0 closes the collection
  in its ninth round. Every result is exact or "collection is closed".
- **Worker errors**: a zero cosine query, an invalid worker count, a cancelled
  control and a mismatched device where-batch each fail on the snapshot or the
  collection. Afterwards the handle still answers, and pins drop to 1, then 0.
- **Root-owned device state**: sibling handles share `root.device`, and closing
  one keeps the table. An upsert at the same generation makes a new root and a
  new state with 17 rows, while the old handle still returns its own top-1.

`tests/gpu/test_gpu_cache.mojo` (real device):

- **Sibling sharing**: sibling handles now share the device cache. The second
  handle's first query is a cache hit with no upload, and the cache survives
  closing the other handle and the collection. Before #50 each handle had its
  own cache.
- **Close during device queries**: 7 tasks run GPU queries while one closes the
  only owning handle. Each result is exact on the GPU or "snapshot is closed",
  and no pins remain.
- **Same G, newer S**: after an upsert, the first device query uploads the new
  root and returns the new top-1. The old handle stays a cache hit with its old
  top-1.

`test_snapshot`, `test_generation_delta`, `test_generation_fields`, `test_concurrency`
and `test_gpu_cache` now read the root through the handle slot. The per-handle
device assertions in `test_generation_delta` became per-root assertions.
