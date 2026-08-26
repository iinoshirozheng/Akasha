# Production HNSW Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Akasha's prototype HNSW with a metric-correct, packed, incremental, filter-aware, persisted, mmap-capable, quantized ANN subsystem with measurable recall and a capability-gated C ABI.

**Architecture:** Keep MemTable/segments as the authoritative F32 record store and make HNSW a rebuildable acceleration layer. Bind each collection to one ANN metric, use canonical lower-is-better distance internally, store mutable graph slots in flat bounded buffers, persist a frozen sidecar through a backward-compatible manifest v3 extension, and overlay post-checkpoint mutations in an owned delta. Exact search remains the compatibility and correctness fallback.

**Tech Stack:** Mojo 1.0.0, Mojo SIMD and FFI, Pixi, existing Akasha binary codecs/WAL/segment/manifest infrastructure, Python 3.11 + pytest/FastAPI, C compiler/linker for the ABI capability gate.

---

## Execution rules

- Work in `/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan` on
  `codex/production-hnsw-plan`.
- Read `docs/plans/2026-08-26-production-hnsw-design.md` before changing code.
- Preserve `PersistentCollection.open(path, dimension)` and existing exact search
  behavior throughout the migration.
- Follow red-green-refactor for every task. Never add implementation before the
  named focused test demonstrates the missing behavior.
- Run `git diff --check` before every commit.
- Do not mix cleanup or unrelated refactors into these commits.
- Run the full suite at the milestone gates in Tasks 14, 22, 27, and 30.
- If a compiler/FFI capability gate fails, record the evidence in the named ADR
  and stop only that optional track. Do not invent a substitute ABI.

## Post-rebase integration constraints (2026-08-27)

The branch was rebased onto `origin/main` after upstream added multi-segment
recovery, derived index caches, manifest v2, SQ8/PQ indexes, parallel scans, GPU
planning/execution, and wider adapter/operations surfaces. Tasks 12 onward must
extend those implementations rather than replace them:

- keep upstream `HnswIndex.encode_cache_payload` / `decode_cache_payload`
  compatibility until the versioned sidecar transition in Tasks 20-22 is
  complete;
- treat `hnsw.cache` as the legacy rebuildable derived-cache path and define one
  explicit transition to the manifest-referenced HNSW sidecar;
- add HNSW references as manifest v3, preserving both v1 single-segment and v2
  multi-segment decoding and publication semantics;
- reuse the existing SQ8/PQ codecs and quality fixtures in Task 26, adding only
  the scalar kinds and graph-vector integration that remain missing;
- make Task 27's HNSW dispatcher compose with the existing parallel-scan and GPU
  planner instead of creating a competing top-level planner;
- extend Task 28 coverage across the current Python, HTTP, operations, snapshot,
  and distributed entry points so configuration identity and stats remain
  consistent on every public surface.

## Milestone A: Measurement and immutable configuration

### Task 1: Add deterministic HNSW quality and work oracles

**Files:**

- Create: `src/akasha/index/hnsw_stats.mojo`
- Modify: `src/akasha/index/__init__.mojo`
- Create: `tests/mojo/test_hnsw_stats.mojo`
- Create: `benchmarks/mojo/hnsw_quality.mojo`
- Modify: `pixi.toml`

**Step 1: Write the failing stats test**

Create `tests/mojo/test_hnsw_stats.mojo` with tests that construct zeroed stats,
record upper/base visits and distance calls, record one fallback reason, and
reset all counters. Use this public shape:

```mojo
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from std.testing import assert_equal, TestSuite

def test_search_stats_reset() raises:
    var stats = HnswSearchStats()
    stats.upper_visited = 3
    stats.base_visited = 7
    stats.distance_evaluations = 11
    stats.fallback_reason = String("metric_mismatch")
    stats.reset()
    assert_equal(stats.upper_visited, 0)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.distance_evaluations, 0)
    assert_equal(stats.fallback_reason, "")

def test_build_stats_reports_active_slots() raises:
    var stats = HnswBuildStats()
    stats.slot_count = 9
    stats.inactive_slots = 2
    assert_equal(stats.active_slots(), 7)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

**Step 2: Run it and verify it fails**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_stats.mojo`

Expected: FAIL because `akasha.index.hnsw_stats` does not exist.

**Step 3: Implement the stats value types**

Create movable/writable structs with explicitly initialized fields. Search stats
must include `requested_ef`, `effective_ef`, `widening_rounds`, `upper_visited`,
`base_visited`, `distance_evaluations`, `retained_candidates`,
`reranked_candidates`, `filtered_rejections`, `inactive_rejections`,
`base_candidates`, `delta_candidates`, `backend_name`, `metric_name`,
`scalar_name`, `storage_name`, and `fallback_reason`. Build stats must include
`slot_count`, `inactive_slots`, `maximum_level`, `directed_edges`,
`distance_evaluations`, and `serialized_bytes`.

Keep `reset()` allocation-free apart from assigning empty strings. Export both
types from `src/akasha/index/__init__.mojo`.

**Step 4: Add a deterministic quality executable**

Create `benchmarks/mojo/hnsw_quality.mojo` with:

- fixed SplitMix64 data generation; no wall-clock seed;
- one uniform and one eight-cluster dataset;
- exact Top-K from `FlatIndex` as ground truth;
- `recall_at_k(expected, actual)` using unique point IDs;
- output fields `dataset`, `points`, `dimension`, `k`, `ef`, `recall`,
  `visited`, and `distances` as one stable `key=value` line per run;
- CLI defaults of 10,000 points, 64 dimensions, 100 queries, `k=10`, and
  `ef=64`, with a smaller `--smoke` mode for CI.

Initially call the existing HNSW API; this benchmark is an oracle and is allowed
to expose the prototype's poor numbers.

Add to `pixi.toml`:

```toml
bench-hnsw-quality = "mojo run -I src benchmarks/mojo/hnsw_quality.mojo"
check-hnsw-quality = "mojo run -I src benchmarks/mojo/hnsw_quality.mojo -- --smoke"
```

**Step 5: Run focused verification**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_stats.mojo
pixi run check-hnsw-quality
```

Expected: PASS; quality output is deterministic across two consecutive runs.

**Step 6: Commit**

```bash
git add src/akasha/index/hnsw_stats.mojo src/akasha/index/__init__.mojo tests/mojo/test_hnsw_stats.mojo benchmarks/mojo/hnsw_quality.mojo pixi.toml
git commit -m "test: add HNSW quality and work oracles"
```

### Task 2: Implement validated collection and HNSW configuration types

**Files:**

- Modify: `src/akasha/common/config.mojo`
- Modify: `src/akasha/common/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`
- Create: `tests/mojo/test_hnsw_config.mojo`

**Step 1: Write failing validation tests**

Cover metric/scalar tags and names, defaults, every invalid integer boundary,
cross-field constraints, and scalar compatibility. The intended API is:

```mojo
var defaults = CollectionConfig.defaults(32)
assert_equal(defaults.dimension, 32)
assert_equal(defaults.ann_metric, MetricKind.L2)
assert_equal(defaults.scalar_kind, ScalarKind.F32)
assert_equal(defaults.m, 16)
assert_equal(defaults.m0, 32)
assert_equal(defaults.ef_construction, 128)
assert_equal(defaults.default_ef_search, 64)
assert_equal(defaults.max_ef_search, 512)
assert_equal(defaults.delta_max_points, 10_000)
defaults.validate()

var cosine = CollectionConfig(
    32,
    ann_metric=MetricKind.COSINE,
    scalar_kind=ScalarKind.BF16,
    m=16,
    m0=32,
    ef_construction=128,
    default_ef_search=64,
    max_ef_search=512,
    max_level=32,
    rebuild_inactive_percent=25,
    delta_max_points=10_000,
    level_seed=UInt64(0xA5A5A5A5A5A5A5A5),
)
cosine.validate()
```

Require errors for dimension <= 0, `m < 2`, `m0 < m`,
`ef_construction < m0`, default ef < 1, max ef < default ef, max level outside
`[1, 63]`, rebuild percentage outside `[1, 90]`, non-positive delta bound,
unknown enum tags, and I8+L2.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_config.mojo`

Expected: FAIL because the types do not exist.

**Step 3: Implement the types**

Replace the placeholder in `src/akasha/common/config.mojo` with:

```mojo
@value
struct MetricKind(Copyable, Movable, EqualityComparable, Writable):
    var tag: UInt8
    comptime DOT = MetricKind(0)
    comptime L2 = MetricKind(1)
    comptime COSINE = MetricKind(2)

@value
struct ScalarKind(Copyable, Movable, EqualityComparable, Writable):
    var tag: UInt8
    comptime F32 = ScalarKind(0)
    comptime BF16 = ScalarKind(1)
    comptime F16 = ScalarKind(2)
    comptime I8 = ScalarKind(3)
```

If Mojo 1.0.0 rejects a comptime instance field initializer, use static
constructors `dot()`, `l2()`, and so on and update tests consistently. Do not use
bare integers outside codec conversion.

Implement `CollectionConfig` with the fields shown in the test, `defaults()`,
`validate()`, `metric_name()`, `scalar_name()`, and a stable
`fingerprint() -> UInt64` over immutable fields. The fingerprint is an identity
check, not a cryptographic checksum.

**Step 4: Export and verify**

Export the types from common and root package initializers. Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_config.mojo
pixi run mojo run -I src tests/mojo/test_public_api.mojo
```

Expected: PASS.

**Step 5: Commit**

```bash
git add src/akasha/common/config.mojo src/akasha/common/__init__.mojo src/akasha/__init__.mojo tests/mojo/test_hnsw_config.mojo
git commit -m "feat: define validated HNSW collection configuration"
```

### Task 3: Add the durable collection configuration codec

**Files:**

- Create: `src/akasha/storage/collection_config.mojo`
- Modify: `src/akasha/storage/__init__.mojo`
- Create: `tests/mojo/test_collection_config_storage.mojo`
- Create: `docs/formats/collection-config-format.md`

**Step 1: Write codec and corruption tests first**

Test `encode_collection_config`, `decode_collection_config_bytes`,
`publish_collection_config`, and `load_collection_config`. Include round trips
for every valid metric/scalar combination and failures for truncation, magic,
version, reserved bytes, enum tags, length, checksum, and invalid cross-fields.
Also verify that publishing twice with an incompatible config fails without
changing the first file.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_collection_config_storage.mojo`

Expected: FAIL because the module does not exist.

**Step 3: Implement the fixed-width v1 codec**

Use `BinaryReader`, `BinaryWriter`, `crc32_range`, `write_file_sync`,
`atomic_replace`, and `sync_directory`. Use magic `AKCF`, version 1, little-endian
fixed-width fields, zeroed reserved bytes, and a trailing CRC32 over all bytes
after magic and before the checksum. Reject extra bytes.

Implement:

```mojo
def encode_collection_config(config: CollectionConfig) raises -> List[UInt8]
def decode_collection_config_bytes(var bytes: List[UInt8]) raises -> CollectionConfig
def publish_collection_config(directory: String, config: CollectionConfig) raises
def load_collection_config(directory: String) raises -> CollectionConfig
def collection_config_exists(directory: String) -> Bool
```

`publish_collection_config` must write `collection.bin.tmp`, fsync, rename to
`collection.bin`, then fsync the directory. It must never silently overwrite an
existing incompatible file.

**Step 4: Document every byte**

In `docs/formats/collection-config-format.md`, add an offset/width/type table,
endianness, checksum coverage, validation limits, compatibility policy, and the
legacy migration rule. Match the code constants exactly.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_collection_config_storage.mojo
git diff --check
```

Expected: PASS.

```bash
git add src/akasha/storage/collection_config.mojo src/akasha/storage/__init__.mojo tests/mojo/test_collection_config_storage.mojo docs/formats/collection-config-format.md
git commit -m "feat: persist immutable collection configuration"
```

### Task 4: Integrate configuration creation and legacy migration

**Files:**

- Modify: `src/akasha/api/collection.mojo`
- Modify: `tests/mojo/test_persistent_collection.mojo`
- Modify: `tests/mojo/test_public_api.mojo`
- Create: `tests/mojo/test_collection_config_migration.mojo`

**Step 1: Write failing lifecycle tests**

Cover:

- new `open(path, 3)` creates a default config before the first WAL mutation;
- `open_with_config(path, config)` persists and returns the chosen metric;
- reopen with a different dimension or immutable field fails;
- a legacy directory containing WAL and/or manifest but no config migrates to
  default L2/F32 without rewriting those files;
- an invalid config does not create `collection.bin`, acquire a long-lived lock,
  append WAL, or consume a sequence;
- `ann_metric()` and `collection_config()` return the durable values.

**Step 2: Run and verify the new tests fail**

Run: `pixi run mojo run -I src tests/mojo/test_collection_config_migration.mojo`

Expected: FAIL because `open_with_config` is absent.

**Step 3: Refactor `PersistentCollection.open`**

Implement this order:

```mojo
@staticmethod
def open(path: String, dimension: Int) raises -> PersistentCollection:
    return PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(dimension)
    )

@staticmethod
def open_with_config(
    path: String, requested: CollectionConfig
) raises -> PersistentCollection:
    requested.validate()
    ensure_directory(path)
    var lock = CollectionLock.acquire(path + "/collection.lock")
    var config = _load_or_migrate_config(path, requested)
    # Recover manifest, segment, WAL, sparse state, and indexes using config.
```

`_load_or_migrate_config` must distinguish an empty new directory from legacy
Akasha files, but both write a durable config before any new mutation. For an
existing `collection.bin`, compare all immutable fields and report the first
mismatch. Store `config` on `PersistentCollection`; derive `dimension` from it.

**Step 4: Verify compatibility**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_collection_config_migration.mojo
pixi run mojo run -I src tests/mojo/test_persistent_collection.mojo
pixi run mojo run -I src tests/mojo/test_public_api.mojo
```

Expected: PASS; existing two-argument open remains source-compatible.

**Step 5: Commit**

```bash
git add src/akasha/api/collection.mojo tests/mojo/test_persistent_collection.mojo tests/mojo/test_public_api.mojo tests/mojo/test_collection_config_migration.mojo
git commit -m "feat: bind collections to durable ANN configuration"
```

### Task 5: Introduce canonical metric semantics and unchecked hot-path kernels

**Files:**

- Create: `src/akasha/compute/metric.mojo`
- Modify: `src/akasha/compute/simd.mojo`
- Modify: `src/akasha/compute/__init__.mojo`
- Create: `tests/mojo/test_metric_dispatch.mojo`
- Modify: `tests/mojo/test_simd_distance.mojo`

**Step 1: Write failing semantic tests**

Test lower-is-better canonical distances, public score conversion, normalized
cosine vectors, zero-norm rejection, and checked/unchecked numerical equality.
Use:

```mojo
var l2 = MetricDispatcher(MetricKind.L2, ScalarKind.F32, 2)
assert_equal(l2.canonical([1.0, 0.0], [3.0, 0.0]), 4.0)

var dot = MetricDispatcher(MetricKind.DOT, ScalarKind.F32, 2)
assert_equal(dot.canonical([1.0, 0.0], [3.0, 0.0]), -3.0)
assert_equal(dot.public_score(-3.0), 3.0)

var cosine = MetricDispatcher(MetricKind.COSINE, ScalarKind.F32, 2)
assert_equal(cosine.canonical([1.0, 0.0], [1.0, 0.0]), 0.0)
```

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_metric_dispatch.mojo`

Expected: FAIL because the module does not exist.

**Step 3: Separate validation from distance loops**

Keep existing public checked functions intact. Add package-internal functions in
`simd.mojo` that assume equal non-empty dimensions and finite inputs:

```mojo
def simd_dot_product_unchecked(lhs: List[Float32], rhs: List[Float32]) -> Float32
def simd_l2_squared_unchecked(lhs: List[Float32], rhs: List[Float32]) -> Float32
```

Implement cosine normalization once in `metric.mojo`; canonical cosine distance
over normalized vectors is `1.0 - dot`. Add `validate_query` and
`prepare_graph_vector` so validation/conversion happens once per public call or
insertion, not per edge.

**Step 4: Implement one-time dispatcher selection**

`MetricDispatcher` stores metric/scalar/dimension and switches once in each
public operation. For now only F32 is executable; constructing other scalar
kinds may succeed for config round trips, but calling distance must raise
`"scalar backend not implemented"` until Task 26. Do not switch metric inside a
dimension loop.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_metric_dispatch.mojo
pixi run mojo run -I src tests/mojo/test_simd_distance.mojo
pixi run bench-distance
```

Expected: tests PASS; benchmark prints a baseline without a correctness change.

```bash
git add src/akasha/compute/metric.mojo src/akasha/compute/simd.mojo src/akasha/compute/__init__.mojo tests/mojo/test_metric_dispatch.mojo tests/mojo/test_simd_distance.mojo
git commit -m "perf: separate HNSW metric validation from distance kernels"
```

## Milestone B: Standard packed HNSW core

### Task 6: Add deterministic binary heaps for HNSW traversal

**Files:**

- Create: `src/akasha/index/hnsw_heap.mojo`
- Create: `tests/mojo/test_hnsw_heap.mojo`

**Step 1: Write failing heap tests**

Cover empty behavior, min-heap candidate order, max-heap worst-result order,
capacity replacement, equal-distance point-ID tie breaks, clear-and-reuse, and
at least 1,000 deterministic push/pop operations compared with a sorted model.

The node type is:

```mojo
@value
struct HnswHeapItem(Copyable, Movable, Writable):
    var slot: UInt32
    var id: Int
    var distance: Float32
```

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_heap.mojo`

Expected: FAIL because the module is absent.

**Step 3: Implement both heap orientations**

Implement `CandidateMinHeap` and `ResultMaxHeap` over flat
`List[HnswHeapItem]`. Candidate ordering is `(distance ASC, id ASC)`. Result root
is the worst item `(distance DESC, id DESC)`. `ResultMaxHeap.offer(item,
capacity)` retains the best `capacity` items and performs no allocation after
capacity has been reserved.

Expose only `clear`, `reserve`, `len`, `peek`, `push`/`offer`, `pop`, and
`take_sorted_best` needed by HNSW. Keep sift operations package-private.

**Step 4: Verify and commit**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_heap.mojo`

Expected: PASS.

```bash
git add src/akasha/index/hnsw_heap.mojo tests/mojo/test_hnsw_heap.mojo
git commit -m "feat: add deterministic HNSW traversal heaps"
```

### Task 7: Add generation-stamped visited state and reusable search scratch

**Files:**

- Create: `src/akasha/index/hnsw_scratch.mojo`
- Create: `tests/mojo/test_hnsw_scratch.mojo`

**Step 1: Write failing scratch tests**

Test growth, first visit/duplicate visit, O(1) query reset, epoch wraparound,
heap/result reuse, and that growing from N to 2N preserves the current epoch's
marks. Add a test-only `force_epoch(UInt32.MAX)` method under a module-level test
helper if Mojo has no conditional test compilation.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_scratch.mojo`

Expected: FAIL because the module is absent.

**Step 3: Implement scratch**

Use this core contract:

```mojo
struct HnswSearchScratch:
    var visited_epochs: List[UInt32]
    var epoch: UInt32
    var candidates: CandidateMinHeap
    var results: ResultMaxHeap

    def begin(mut self, slot_count: Int, ef: Int): ...
    def visit(mut self, slot: UInt32) -> Bool:
        # Return true only for the first visit in the current epoch.
```

`begin()` grows buffers when needed, increments the epoch, clears only heaps,
and clears the visited array only on wrap. Reject a slot outside the prepared
range in debug/test behavior rather than corrupting memory.

**Step 4: Verify and commit**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_scratch.mojo`

Expected: PASS.

```bash
git add src/akasha/index/hnsw_scratch.mojo tests/mojo/test_hnsw_scratch.mojo
git commit -m "perf: reuse HNSW search scratch with visited epochs"
```

### Task 8: Replace ID-derived levels with seeded geometric sampling

**Files:**

- Create: `src/akasha/index/hnsw_level.mojo`
- Modify: `tests/mojo/test_hnsw.mojo`
- Create: `tests/mojo/test_hnsw_level.mojo`

**Step 1: Write failing level tests**

Cover same ID+seed determinism, different seed sensitivity over 100 IDs,
negative IDs, maximum-level cap, order independence, and distribution sanity
over 100,000 IDs: level counts strictly decline through the first few levels
and level 0 contains more than half of samples for default M=16. Do not assert
exact random bucket counts.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_level.mojo`

Expected: FAIL because `sample_level` is absent.

**Step 3: Implement SplitMix64 sampling**

Implement pure `splitmix64(value: UInt64) -> UInt64` and:

```mojo
def sample_level(id: Int, seed: UInt64, m: Int, maximum: Int) -> Int raises:
    if m < 2 or maximum < 0:
        raise Error("invalid HNSW level configuration")
    var bits = splitmix64(UInt64(bitcast=id) ^ seed)
    var u = (Float64(bits) + 1.0) / (Float64(UInt64.MAX) + 2.0)
    var sampled = Int(-log(u) / log(Float64(m)))
    return min(sampled, maximum)
```

Adjust the bitcast expression to Mojo 1.0.0's accepted signed/unsigned conversion
without taking absolute value. Keep `u` strictly inside `(0, 1)`.

**Step 4: Remove the old public helper expectation**

Update `tests/mojo/test_hnsw.mojo` to stop importing `deterministic_level` from
`hnsw.mojo`. Do not yet rewrite graph construction; Task 13 switches it over.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_level.mojo
pixi run mojo run -I src tests/mojo/test_hnsw.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw_level.mojo tests/mojo/test_hnsw.mojo tests/mojo/test_hnsw_level.mojo
git commit -m "feat: sample deterministic geometric HNSW levels"
```

### Task 9: Implement flat bounded mutable graph storage

**Files:**

- Create: `src/akasha/index/hnsw_storage.mojo`
- Create: `tests/mojo/test_hnsw_storage.mojo`

**Step 1: Write failing storage tests**

Test slot append, ID lookup, vector offsets, level-specific capacity, neighbor
read/write/remove, duplicate suppression, active/current flags, replacement ID
mapping, sentinel handling, maximum slot bounds, and structural validation.

Use an API shaped like:

```mojo
var graph = MutableHnswGraph(2, m=3, m0=6)
var first = graph.append(10, [1.0, 2.0], level=2)
var second = graph.append(20, [2.0, 3.0], level=0)
graph.add_neighbor(first, 0, second)
assert_equal(graph.neighbor_count(first, 0), 1)
assert_equal(graph.neighbor_at(first, 0, 0), second)
assert_equal(graph.level_capacity(first, 0), 6)
assert_equal(graph.level_capacity(first, 1), 3)
```

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_storage.mojo`

Expected: FAIL because the module is absent.

**Step 3: Implement append-only packed storage**

Use flat lists for IDs, levels, flags, vector scalars, per-level counts, per-node
neighbor base offsets, level-local offsets, and `UInt32` neighbor slots. Allocate
`m0 + level * m` neighbor capacity exactly once per appended node. Keep public
IDs only in the ID array and `Dict[Int, UInt32]`; store slot ordinals in every
edge.

Required methods:

```mojo
def append(mut self, id: Int, values: List[Float32], level: Int) raises -> UInt32
def current_slot(self, id: Int) -> Optional[UInt32]
def mark_replaced(mut self, id: Int) raises -> UInt32
def mark_deleted(mut self, id: Int) -> Bool
def is_current(self, slot: UInt32) -> Bool
def vector(self, slot: UInt32) -> Span[Float32]
def neighbor_count(self, slot: UInt32, level: Int) -> Int
def neighbor_at(self, slot: UInt32, level: Int, index: Int) -> UInt32
def set_neighbors(mut self, slot: UInt32, level: Int, values: List[UInt32]) raises
def validate_structure(self) raises
```

If a borrow-safe `Span` cannot be returned from the struct on Mojo 1.0.0, expose
`distance_to_slot(dispatcher, query, slot)` and `distance_between(dispatcher,
lhs, rhs)` instead of copying vectors.

**Step 4: Verify and commit**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_storage.mojo`

Expected: PASS with no nested neighbor lists.

```bash
git add src/akasha/index/hnsw_storage.mojo tests/mojo/test_hnsw_storage.mojo
git commit -m "feat: add packed mutable HNSW graph storage"
```

### Task 10: Implement standard greedy descent and base-layer search

**Files:**

- Create: `src/akasha/index/hnsw_core.mojo`
- Create: `tests/mojo/test_hnsw_search_layer.mojo`

**Step 1: Build small graphs by hand in failing tests**

Create line, fork, disconnected, equal-distance, tombstoned-bridge, and
filter-rejected-bridge graphs through `MutableHnswGraph`. Assert:

- upper greedy descent stops at the local minimum with deterministic ties;
- base search returns best-first ordering;
- radius termination stops once the best unexplored item is worse than the
  retained worst item;
- non-current and disallowed slots remain traversable but are absent from
  results;
- stats count visits and distance evaluations exactly on the hand-built cases.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_search_layer.mojo`

Expected: FAIL because `hnsw_core` does not exist.

**Step 3: Implement upper greedy search**

Implement a loop that examines one node's neighbors without copying adjacency,
moves only when `(distance, id)` is strictly better, and repeats at the same
level until stable. Validate the entry slot once before the loop.

**Step 4: Implement heap-based `search_layer`**

Use the reusable scratch from Task 7. Always seed the candidate heap with the
entry point; seed the result heap only when `is_current && allowed`. For each
popped candidate, stop when results are full and its distance is worse than the
worst retained result. Visit every unseen neighbor; offer it to the candidate
heap regardless of filter/current state; offer it to results only if eligible.

The internal result returns slot+distance pairs, not public `SearchResult`.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_search_layer.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_heap.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_scratch.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw_core.mojo tests/mojo/test_hnsw_search_layer.mojo
git commit -m "feat: implement heap-based HNSW layer search"
```

### Task 11: Implement diversity-aware neighbor selection

**Files:**

- Modify: `src/akasha/index/hnsw_core.mojo`
- Create: `tests/mojo/test_hnsw_neighbor_selection.mojo`

**Step 1: Write failing geometry tests**

Create deterministic two-dimensional candidate sets proving that nearest-only
selection chooses redundant collinear points while the diversity heuristic
keeps candidates from different directions. Also cover capacity zero/one,
duplicate slots, excluded self, a fill-to-capacity mode, and point-ID tie breaks.

**Step 2: Run and verify the nearest-only behavior fails the new contract**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_neighbor_selection.mojo`

Expected: FAIL because `select_neighbors_heuristic` is absent.

**Step 3: Implement the heuristic**

Sort candidates by query-to-candidate `(distance, id)`. For each candidate `c`,
accept it when, for every already selected `s`:

```text
distance(c, s) >= distance(c, query)
```

This is the HNSW diversity condition expressed with lower-is-better canonical
distance. Cache candidate-to-query distances from layer search; count only new
candidate-to-selected evaluations in build stats. When `keep_pruned_connections`
is true, append rejected candidates in nearest order until capacity is full.

Return unique slot ordinals with no self link and no more than the requested
capacity.

**Step 4: Verify and commit**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_neighbor_selection.mojo`

Expected: PASS.

```bash
git add src/akasha/index/hnsw_core.mojo tests/mojo/test_hnsw_neighbor_selection.mojo
git commit -m "feat: diversify HNSW neighbor selection"
```

### Task 12: Implement bounded bidirectional linking and pruning

**Files:**

- Modify: `src/akasha/index/hnsw_core.mojo`
- Modify: `src/akasha/index/hnsw_storage.mojo`
- Create: `tests/mojo/test_hnsw_links.mojo`

**Step 1: Write failing graph-invariant tests**

Insert explicit selected-neighbor sets and assert after linking/pruning:

- no self links or duplicates;
- every stored edge has a reverse edge at the same level;
- level 0 degree never exceeds `m0` and upper degree never exceeds `m`;
- evicting an edge from a full reverse adjacency removes the counterpart edge;
- a node is never linked above either endpoint's owned level;
- validation detects a deliberately asymmetric test graph.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_links.mojo`

Expected: FAIL because pruning does not yet repair reverse edges.

**Step 3: Implement link transaction helpers**

Add `contains_neighbor`, `remove_neighbor`, and checked `set_neighbors` to packed
storage. In `connect_bidirectional`:

1. add each proposed edge only once;
2. if an endpoint exceeds capacity, run the Task 11 heuristic around that
   endpoint;
3. compute removed neighbors before replacing its adjacency;
4. remove that endpoint from every evicted neighbor's reverse list;
5. validate all touched levels in debug/test calls.

Do not recursively prune reverse lists: removals cannot increase degree. If an
exception occurs before all touched lists are updated, mark the graph invalid so
the collection routes to exact search; do not expose a partially valid graph.

**Step 4: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_links.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_storage.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw_core.mojo src/akasha/index/hnsw_storage.mojo tests/mojo/test_hnsw_links.mojo
git commit -m "feat: maintain bounded symmetric HNSW links"
```

### Task 13: Rewrite `HnswIndex` around the standard core

**Files:**

- Replace internals: `src/akasha/index/hnsw.mojo`
- Modify: `src/akasha/index/__init__.mojo`
- Modify: `tests/mojo/test_hnsw.mojo`
- Create: `tests/mojo/test_hnsw_invariants.mojo`
- Modify: `benchmarks/mojo/hnsw_bench.mojo`

**Step 1: Write failing public API and invariant tests**

Change construction to require one metric/config while keeping a compatibility
initializer:

```mojo
var config = CollectionConfig.defaults(8)
config.ann_metric = MetricKind.COSINE
var index = HnswIndex(config)
index.add(1, [1.0, 0.0, ...])
var results = index.search([1.0, 0.0, ...], 10, ef_search=64)
```

Keep `HnswIndex(dimension, m=..., max_level=...)` as an L2/F32 compatibility
wrapper during this task. Tests must assert metric-correct dot, L2, and cosine
construction; `m0`/`m` bounds; geometric levels; `ef_construction` affects work;
entry point behavior; public score semantics; deterministic ties; duplicate ID
rejection; and full graph structural validity after every insertion in a seeded
200-point run.

Remove the old contract that one graph searches all metrics. If legacy
`search_dot/search_cosine` is called on an L2 index directly, require a clear
metric-mismatch error. Collection compatibility fallback is added in Task 18.

**Step 2: Run and verify the prototype fails**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_invariants.mojo
```

Expected: FAIL on constructor/API, M0, construction metric, and invariants.

**Step 3: Replace object-per-node internals**

`HnswIndex` must own:

```mojo
var config: CollectionConfig
var metric: MetricDispatcher
var graph: MutableHnswGraph
var scratch: HnswSearchScratch
var entry_slot: Optional[UInt32]
var entry_level: Int
var valid: Bool
var build_stats: HnswBuildStats
var last_search_stats: HnswSearchStats
```

Delete `_HnswNode`, `_NeighborLevel`, `_Candidate`, linear `_find_index`, and the
old full-scan add loop.

Preserve the public signatures and byte compatibility of
`encode_cache_payload` / `decode_cache_payload` while `hnsw.cache` remains an
upstream recovery input. Reimplement those methods against the new packed graph,
and add a legacy-cache round-trip/reopen test. Do not remove the compatibility
codec until Task 22 has published and recovered the replacement sidecar.

**Step 4: Implement standard insertion**

For a non-empty index:

1. sample level using ID+seed;
2. prepare/normalize the graph vector once;
3. greedily descend from entry level through `new_level + 1`;
4. for each shared level down to zero, call `search_layer` with
   `ef_construction`, select diversified neighbors, connect bidirectionally, and
   use the closest result as the next entry;
5. promote entry point when needed.

Append the slot only after public validation succeeds. Construction scratch is
separate from the last public search stats, or its counters are copied before
reuse.

**Step 5: Implement bound-metric search**

Validate query once, prepare it once, run upper descent and base search with
`effective_ef = max(k, ef_search)`, convert canonical distances to public scores,
and return `SearchResult` sorted by public semantics then ID. Add accessors for
stats and structural validation used by tests/benchmarks.

**Step 6: Update benchmark and verify**

Make `hnsw_bench.mojo` print metric, M, M0, efConstruction, efSearch, build
distance count, average visited count, and query latency.

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_invariants.mojo
pixi run bench-hnsw
pixi run check-hnsw-quality
```

Expected: tests PASS; smoke quality completes without a full construction scan.

**Step 7: Commit**

```bash
git add src/akasha/index/hnsw.mojo src/akasha/index/__init__.mojo tests/mojo/test_hnsw.mojo tests/mojo/test_hnsw_invariants.mojo benchmarks/mojo/hnsw_bench.mojo
git commit -m "feat: replace prototype with standard packed HNSW"
```

### Task 14: Establish the F32 recall and build-scaling milestone gate

**Files:**

- Modify: `benchmarks/mojo/hnsw_quality.mojo`
- Create: `tests/mojo/test_hnsw_quality_gate.mojo`
- Create: `docs/benchmarks/hnsw-baseline.md`

**Step 1: Write the failing automated gate**

Run a CI-sized fixed dataset for all three metrics and assert recall@10 >= 0.95
at ef=64. Add a construction-work test at N and 2N that compares recorded
distance evaluations; assert the ratio stays below 3.5 on the fixed dataset so a
complete quadratic regression fails without using unstable wall time.

**Step 2: Run and tune algorithm parameters, not the oracle**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_quality_gate.mojo`

Expected initially: either PASS or a useful FAIL identifying a metric/dataset.
If it fails, fix insertion/search correctness or choose documented default
`ef_construction`/M values. Do not lower the 0.95 gate or make the dataset easier.

**Step 3: Record a reproducible baseline**

Run the non-smoke quality benchmark and existing latency benchmark. Record
hardware/OS, Mojo version, command, dataset seed/shape, configuration, recall,
build distance count, visited count, serialized-size estimate, and latency in
`docs/benchmarks/hnsw-baseline.md`. Create `docs/benchmarks/` first because the
directory is not present at the baseline commit. Label wall-clock values as
local diagnostics, not universal requirements.

**Step 4: Run the Milestone B core suite**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_quality_gate.mojo
pixi run mojo run -I src tests/mojo/test_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_invariants.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_links.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_search_layer.mojo
pixi run mojo run -I src tests/mojo/test_persisted_index_cache.mojo
pixi run test-crash
pixi run build
```

Expected: PASS.

Do not claim the repository-wide Mojo suite passes at this staged boundary.
Task 13 intentionally made the graph metric-bound while collection-level
cross-metric fallback is Task 18, so the legacy collection dot-ANN cases remain
expected metric-mismatch failures until then. Task 18 owns the next fresh full
suite gate after restoring that compatibility contract.

**Step 5: Commit**

```bash
git add benchmarks/mojo/hnsw_quality.mojo tests/mojo/test_hnsw_quality_gate.mojo docs/benchmarks/hnsw-baseline.md
git commit -m "test: enforce HNSW recall and build-scaling gates"
```

## Milestone C: Filtering, mutation, and collection integration

### Task 15: Admit bitmap-filtered results during graph traversal

**Files:**

- Modify: `src/akasha/index/hnsw_core.mojo`
- Modify: `src/akasha/index/hnsw.mojo`
- Create: `tests/mojo/test_hnsw_filtered.mojo`

**Step 1: Write failing filtered-search tests**

Test no-filter equivalence, empty/full/sparse bitmaps, disallowed bridge
traversal, allowed result admission, fewer than k allowed IDs, ID-to-bitmap
ordinal translation, and stats for filtered rejections. A bitmap ordinal belongs
to the metadata index, not a graph slot; pass a small predicate adapter mapping
graph slot -> point ID -> metadata ordinal/current membership.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_filtered.mojo`

Expected: FAIL because public filtered HNSW search is absent.

**Step 3: Add an internal eligibility interface**

Avoid copying the bitmap into a slot-sized list. Add one internal eligibility
type that owns or borrows the metadata `Bitmap` plus an ID-to-ordinal lookup. It
must provide `allows(id: Int) -> Bool`. Keep an `AllowAll` fast path so
unfiltered search does not perform a dictionary lookup per retained candidate.

Add:

```mojo
def search_allowed(
    mut self,
    query: List[Float32],
    k: Int,
    ef_search: Int,
    allowed: HnswEligibility,
) raises -> List[SearchResult]
```

Traversal ignores eligibility; result-heap admission checks current+allowed.

**Step 4: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_filtered.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_search_layer.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw_core.mojo src/akasha/index/hnsw.mojo tests/mojo/test_hnsw_filtered.mojo
git commit -m "feat: filter HNSW result admission during traversal"
```

### Task 16: Implement progressive ef widening and planner reasons

**Files:**

- Modify: `src/akasha/query/planner.mojo`
- Modify: `src/akasha/index/hnsw.mojo`
- Modify: `tests/mojo/test_query_planner.mojo`
- Create: `tests/mojo/test_hnsw_widening.mojo`

**Step 1: Write failing decision tests**

Replace the Boolean-only planner assertion surface with a decision carrying
`use_hnsw`, `initial_ef`, `max_ef`, and a stable reason. Cover small collection,
metric mismatch, graph unavailable, filter matched count <= 2k, high selectivity,
and normal ANN. Test widening `ef -> min(2*ef, max_ef)` with overflow protection,
no duplicate IDs across rounds, and exact fallback after exhaustion.

**Step 2: Run and verify failure**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_query_planner.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_widening.mojo
```

Expected: FAIL on missing decision/reason and widening behavior.

**Step 3: Implement the richer planner**

Add `HnswPlan` and:

```mojo
@staticmethod
def plan_dense(
    total_count: Int,
    matched_count: Int,
    k: Int,
    requested_ef: Int,
    max_ef: Int,
    has_filter: Bool,
    metric_compatible: Bool,
    graph_ready: Bool,
) -> HnswPlan
```

Keep `use_hnsw(...)` as a compatibility wrapper for existing tests/callers until
Task 17 migrates them.

**Step 4: Implement widening orchestration**

Widen only for filtered requests that return fewer than `min(k, matched_count)`.
Each round reruns base search with larger ef and reused scratch; it does not
blindly append prior results. Copy the final stats before exact fallback and set
`fallback_reason = "filtered_ann_exhausted"`.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_query_planner.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_widening.mojo
```

Expected: PASS.

```bash
git add src/akasha/query/planner.mojo src/akasha/index/hnsw.mojo tests/mojo/test_query_planner.mojo tests/mojo/test_hnsw_widening.mojo
git commit -m "feat: plan and widen filtered HNSW search"
```

### Task 17: Add incremental insert, replace, and delete semantics

**Files:**

- Modify: `src/akasha/index/hnsw.mojo`
- Modify: `src/akasha/index/hnsw_storage.mojo`
- Create: `tests/mojo/test_hnsw_mutation.mojo`

**Step 1: Write failing mutation tests**

Cover new insert, replace with the same ID and new vector, delete, repeated
delete, delete/reinsert, old-slot bridge traversal, old-slot result rejection,
ID map pointing only to the newest slot, inactive ratio, entry-point replacement,
and graph validity after 500 deterministic mixed operations.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_mutation.mojo`

Expected: FAIL because duplicate IDs are currently rejected and delete is absent.

**Step 3: Add mutation methods**

Implement:

```mojo
def upsert(mut self, id: Int, values: List[Float32]) raises
def delete(mut self, id: Int) -> Bool
def inactive_count(self) -> Int
def needs_rebuild(self) -> Bool
```

`upsert` validates and prepares the new vector before changing the old slot. For
a replacement, mark the old slot non-current, insert a new slot, and update the
ID map after successful linking. If linking fails, mark the index invalid so the
collection uses exact search; durable collection state remains authoritative.
Delete removes the current mapping and marks that slot non-current without
rewiring neighbors.

Entry point may remain an inactive bridge. Rebuild chooses a live entry point;
an empty live graph returns no results even if inactive slots remain.

**Step 4: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_mutation.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_invariants.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw.mojo src/akasha/index/hnsw_storage.mojo tests/mojo/test_hnsw_mutation.mojo
git commit -m "feat: update HNSW incrementally with tombstones"
```

### Task 18: Remove collection rebuild-on-query and enforce metric fallback

**Files:**

- Modify: `src/akasha/api/collection.mojo`
- Modify: `tests/mojo/test_persistent_hnsw.mojo`
- Modify: `tests/mojo/test_persistent_filters.mojo`
- Create: `tests/mojo/test_collection_hnsw_incremental.mojo`

**Step 1: Write failing collection tests**

Assert:

- upsert immediately increments graph slot/build stats and query does not rebuild;
- replacement/delete update graph state incrementally;
- ANN metric matching the collection uses HNSW;
- requesting a different approximate metric returns exact-equivalent results and
  records `metric_mismatch` fallback;
- small/selective/unavailable graph paths return exact-equivalent results with
  the correct planner reason;
- filtered ANN exact-reranks authoritative MemTable vectors;
- a simulated graph mutation failure leaves exact search available.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_collection_hnsw_incremental.mojo`

Expected: FAIL because `_hnsw_dirty` still triggers a full rebuild.

**Step 3: Integrate mutation order**

After successful validation, WAL append, and MemTable/metadata mutation, call
`_hnsw.upsert` or `_hnsw.delete`. Replace `_hnsw_dirty` with graph availability
state. If HNSW mutation raises, retain the committed data mutation, set graph
unavailable with a reason, and make all approximate requests exact fallback.

Do not let an HNSW failure change sequence, WAL, MemTable, metadata, or sparse
semantics.

**Step 4: Replace approximate query orchestration**

Use `QueryPlanner.plan_dense`. For compatible ANN, pass the metadata eligibility
bitmap into HNSW, widen as planned, and exact-rerank returned IDs from MemTable.
For mismatch/selective/unready cases call the existing exact path directly.
Delete `_ensure_hnsw` and any query-time full rebuild.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_collection_hnsw_incremental.mojo
pixi run mojo run -I src tests/mojo/test_persistent_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_persistent_filters.mojo
pixi run test
pixi run test-crash
pixi run build
```

Expected: PASS.

```bash
git add src/akasha/api/collection.mojo tests/mojo/test_persistent_hnsw.mojo tests/mojo/test_persistent_filters.mojo tests/mojo/test_collection_hnsw_incremental.mojo
git commit -m "feat: integrate incremental metric-bound HNSW"
```

### Task 19: Add deterministic rebuild and maintenance policy

**Files:**

- Modify: `src/akasha/index/hnsw.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Create: `tests/mojo/test_hnsw_rebuild.mojo`
- Modify: `tests/mojo/test_collection_hnsw_incremental.mojo`

**Step 1: Write failing rebuild tests**

Verify threshold boundaries, explicit rebuild from live records, stable graph for
the same config/insertion order, no inactive slots after rebuild, live result
equivalence before/after rebuild, invalid graph recovery, and no automatic
rebuild during a query. Test that `flush()` rebuilds only when the inactive or
delta threshold is met.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_rebuild.mojo`

Expected: FAIL because explicit rebuild/threshold behavior is absent.

**Step 3: Implement rebuild from an iterator-like live entry list**

Add `HnswIndex.rebuild(config, live_entries)` or a package helper that constructs
a new index, inserts records in ascending sequence then ID order, validates the
complete graph, and swaps it into place only after success. Avoid `live_entries()`
vector clones by adding a MemTable iteration callback/accessor if Mojo borrowing
allows it; otherwise document and measure this one maintenance-time copy.

**Step 4: Wire maintenance rules**

`needs_rebuild()` returns true when invalid, inactive percentage reaches config,
or slot count approaches the safe UInt32 bound. Queries only observe this state;
`flush()` and an explicit `rebuild_hnsw()` method may perform the rebuild.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_rebuild.mojo
pixi run mojo run -I src tests/mojo/test_collection_hnsw_incremental.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw.mojo src/akasha/api/collection.mojo tests/mojo/test_hnsw_rebuild.mojo tests/mojo/test_collection_hnsw_incremental.mojo
git commit -m "feat: rebuild HNSW at explicit maintenance thresholds"
```

## Milestone D: Versioned sidecar persistence

### Task 20: Define and implement the frozen HNSW sidecar codec

**Files:**

- Create: `src/akasha/storage/hnsw_store.mojo`
- Modify: `src/akasha/storage/__init__.mojo`
- Create: `tests/mojo/test_hnsw_store.mojo`
- Create: `docs/formats/hnsw-format.md`

**Step 1: Write failing round-trip and corruption tests**

Build empty, single-node, multi-level, tombstoned, tombstone-free rebuilt, and
all-metric F32 graphs. Verify byte-for-byte deterministic encoding, round-trip
graph structure,
query equivalence after owned decode, and failure for truncated headers/sections,
bad magic/version/flags/checksum, mismatched sequence/config/dimension,
overflowing offsets/counts, invalid entry slot/level, out-of-range neighbors,
duplicate/self/asymmetric links, and nonzero reserved bytes.

Also preserve a fixture produced by the existing `hnsw.cache` payload codec and
test the transition policy: legacy cache data remains readable/rebuildable, but
new sidecar publication never writes a second independently authoritative graph.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_store.mojo`

Expected: FAIL because `hnsw_store` is absent.

**Step 3: Implement an explicit sectioned v1 format**

Use magic `AKHG`, format version 1, little endian, fixed-width header, 64-bit
section offsets/lengths, configuration fingerprint, checkpoint sequence,
dimension, metric/scalar, point/edge counts, entry slot/level, and a whole-file
CRC32. Encode every allocated slot plus its current flag; live point count is
separate from slot count and only current public IDs must be unique.

Implement:

```mojo
struct HnswSnapshotInfo(Movable): ...
def encode_hnsw_snapshot(index: HnswIndex, sequence: UInt64) raises -> List[UInt8]
def decode_hnsw_snapshot_owned(
    var bytes: List[UInt8], config: CollectionConfig, sequence: UInt64
) raises -> HnswIndex
def write_hnsw_snapshot(path: String, index: HnswIndex, sequence: UInt64) raises -> HnswSnapshotInfo
def read_hnsw_snapshot_owned(path: String, config: CollectionConfig, sequence: UInt64) raises -> HnswIndex
```

All `count * width` and `offset + length` arithmetic must be checked before
allocation or indexing. Persist slot flags and historical tombstoned slots so a
checkpoint does not force a rebuild below the maintenance threshold. Require at
most one current slot per public ID, store both slot count and live point count,
and validate structure after decode. A freshly rebuilt graph naturally contains
no tombstones.

**Step 4: Document the format**

Add exact header/section tables, alignment, checksum range, limits, validation
order, filename convention `hnsw-<sequence>.bin`, and compatibility policy to
`docs/formats/hnsw-format.md`.

Document that the sidecar supersedes `hnsw.cache` only after the manifest v3
commit point in Task 22. Until then, the cache is derived and optional; after a
v3 sidecar is committed, recovery must not prefer a stale cache over it.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_store.mojo
git diff --check
```

Expected: PASS.

```bash
git add src/akasha/storage/hnsw_store.mojo src/akasha/storage/__init__.mojo tests/mojo/test_hnsw_store.mojo docs/formats/hnsw-format.md
git commit -m "feat: encode validated HNSW snapshot sidecars"
```

### Task 21: Upgrade manifest v2 to optional HNSW references in v3

**Files:**

- Modify: `src/akasha/storage/manifest.mojo`
- Modify: `tests/mojo/test_manifest.mojo`
- Modify: `docs/formats/manifest-format.md`
- Create: `tests/mojo/test_manifest_v1_v2_compat.mojo`

**Step 1: Preserve v1 and v2 fixtures and write failing v3 tests**

Before changing the codec, preserve representative v1 single-segment and v2
multi-segment bytes in the compatibility test. Test that both decode with
`hnsw_name = None` and retain their existing segment/sparse descriptors. Add v3
round trips for multi-segment manifests with and without an HNSW reference,
deterministic bytes, filename validation, and corruption of each new
length/checksum/fingerprint/count field.

**Step 2: Run and verify v3 tests fail**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_manifest.mojo
pixi run mojo run -I src tests/mojo/test_manifest_v1_v2_compat.mojo
```

Expected: v1/v2 compatibility PASS; new v3 assertions FAIL.

**Step 3: Implement version-dispatched decoding**

Extend `Manifest` with optional HNSW name, checksum, config fingerprint, and
point count. Keep v1 and v2 decode byte-for-byte compatible. New publishes use
v3 only when HNSW reference fields are present; ordinary upstream multi-segment
publishes remain v2 until Task 22 integrates the sidecar commit point.
Dispatch on the decoded version before applying version-specific fixed-size and
length rules. Reuse one safe-filename validator for segment/sparse/HNSW names.

Do not require the HNSW file in generic `load_manifest`; return its reference so
collection recovery can distinguish missing/stale acceleration data from a
missing authoritative segment.

**Step 4: Update format documentation**

Add separate v1/v2/v3 tables and state that the HNSW reference is optional and
rebuildable while every manifest segment reference is authoritative and
required.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_manifest.mojo
pixi run mojo run -I src tests/mojo/test_manifest_v1_v2_compat.mojo
pixi run mojo run -I src tests/mojo/test_segment_v1_compat.mojo
```

Expected: PASS.

```bash
git add src/akasha/storage/manifest.mojo tests/mojo/test_manifest.mojo tests/mojo/test_manifest_v1_v2_compat.mojo docs/formats/manifest-format.md
git commit -m "feat: reference HNSW sidecars from manifest v3"
```

### Task 22: Integrate sidecar checkpoint, owned recovery, and crash ordering

**Files:**

- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/storage/filesystem.mojo`
- Modify: `tests/mojo/test_persistent_hnsw.mojo`
- Create: `tests/crash/test_hnsw_checkpoint_order.mojo`
- Create: `tests/mojo/test_hnsw_checkpoint_cleanup.mojo`

**Step 1: Write failing recovery and cleanup tests**

Cover flush publishing an HNSW reference; reopen using the sidecar without a
rebuild; v1/no-sidecar rebuild; stale sequence/config/point count rebuild;
missing sidecar rebuild; checksum-corrupt committed sidecar reporting corruption;
query equivalence before/after reopen; and cleanup removing only the prior
manifest-named HNSW file, never similarly named unreferenced user files.

**Step 2: Add crash-window tests before implementation**

Use the existing crash-test pattern to stop after each checkpoint boundary:

1. data temporaries written, manifest old;
2. data files renamed, manifest old;
3. manifest v3 published, WAL old;
4. WAL rotated, old sidecars present;
5. old sidecars removed.

Each reopen must recover the exact acknowledged records. A state with an old
manifest must ignore unreferenced new files; a published new manifest must open
its segment and compatible HNSW or safely rebuild.

**Step 3: Run and verify failures**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_persistent_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_checkpoint_cleanup.mojo
pixi run mojo run -I src tests/crash/test_hnsw_checkpoint_order.mojo
```

Expected: FAIL on missing sidecar integration.

**Step 4: Implement checkpoint ordering**

During `flush()`:

- rebuild first only when Task 19 policy requires it;
- write segment, sparse, and HNSW temporary files;
- fsync and rename all data files, then sync the directory;
- publish manifest v3 as the commit point;
- rotate dense and sparse WALs;
- remove only prior valid manifest references that differ from current names.

Extend filesystem helpers only with narrowly named operations needed by this
ordering. Never use a directory glob for cleanup.

**Step 5: Implement recovery classification**

After authoritative segment+WAL recovery, accept the sidecar only when file
exists and sequence, config fingerprint, dimension, metric/scalar, checksum, and
live point count match. Missing or stale metadata triggers a rebuild. Unsafe
layout or checksum corruption in the committed matching file raises a storage
error. Replay newer WAL mutations incrementally into the loaded owned graph.

**Step 6: Run the Milestone D gate**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_persistent_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_checkpoint_cleanup.mojo
pixi run test-crash
pixi run test
pixi run build
```

Expected: PASS.

**Step 7: Commit**

```bash
git add src/akasha/api/collection.mojo src/akasha/storage/filesystem.mojo tests/mojo/test_persistent_hnsw.mojo tests/mojo/test_hnsw_checkpoint_cleanup.mojo tests/crash/test_hnsw_checkpoint_order.mojo
git commit -m "feat: checkpoint and recover HNSW sidecars"
```

## Milestone E: Memory-mapped frozen base and mutable delta

### Task 23: Prove and wrap platform memory mapping safely

**Files:**

- Create: `src/akasha/storage/mapped_file.mojo`
- Modify: `src/akasha/storage/__init__.mojo`
- Create: `tests/mojo/test_mapped_file.mojo`
- Create: `docs/adr/0004-memory-mapped-storage.md`

**Step 1: Write a compile/run capability probe as the failing test**

The test writes a temporary page-sized fixture with existing filesystem helpers,
opens it read-only, checks length and first/last bytes, closes twice safely, and
tests empty file, nonexistent file, invalid range, and lifetime cleanup. Run it
on the current macOS ARM64 environment before writing the wrapper.

Run: `pixi run mojo run -I src tests/mojo/test_mapped_file.mojo`

Expected: FAIL because `MappedFile` is absent.

**Step 2: Implement RAII FFI ownership**

Use `external_call`/FFI definitions for POSIX `open`, `fstat`, `mmap`, `munmap`,
and `close`. Store an opaque/raw base pointer, byte length, file descriptor, and
closed flag. Map read-only/private. The destructor calls an idempotent internal
close path and never raises.

Required interface:

```mojo
struct MappedFile(Movable):
    @staticmethod
    def open_readonly(path: String) raises -> MappedFile
    def byte_length(self) -> Int
    def byte_at(self, offset: Int) raises -> UInt8
    def checked_slice(self, offset: UInt64, length: UInt64) raises -> MappedBytes
    def close(mut self)
```

Validate `offset + length` without overflow before pointer arithmetic. Do not
construct typed graph pointers here.

**Step 3: Document platform and fallback behavior**

Record exact signatures/constants used on `osx-arm64` and `linux-64`, ownership,
empty-file behavior, and the rule that mmap failure falls back to owned load
only after normal file validation. If Linux cannot be executed locally, add a
CI command and explicitly mark it pending rather than claiming verification.

**Step 4: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_mapped_file.mojo
pixi run mojo run -I src tests/mojo/test_storage_checksum.mojo
```

Expected: PASS on macOS ARM64.

```bash
git add src/akasha/storage/mapped_file.mojo src/akasha/storage/__init__.mojo tests/mojo/test_mapped_file.mojo docs/adr/0004-memory-mapped-storage.md
git commit -m "feat: add validated read-only memory mapping"
```

### Task 24: Add a validated immutable HNSW graph view

**Files:**

- Create: `src/akasha/index/hnsw_view.mojo`
- Modify: `src/akasha/storage/hnsw_store.mojo`
- Modify: `src/akasha/index/hnsw_core.mojo`
- Create: `tests/mojo/test_hnsw_view.mojo`

**Step 1: Write failing owned-versus-view equivalence tests**

For every metric and several graph levels, encode one graph, decode owned, map
the same bytes, and assert identical IDs, levels, vector values, adjacency,
structural validation, candidate ordering, public results, and non-timing stats.
Add misalignment, offset aliasing, out-of-order section, truncated mapping, and
use-after-close prevention tests.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_hnsw_view.mojo`

Expected: FAIL because the immutable view is absent.

**Step 3: Introduce a narrow graph-access contract**

Replace core functions' dependency on `MutableHnswGraph` with a trait or
parameterized contract supplying slot count, ID, level, current flag, vector
distance, neighbor count, and neighbor ordinal. Implement it for both mutable
storage and the frozen view. Keep mutation/linking functions specialized to
mutable storage.

**Step 4: Build the view only after complete validation**

`open_hnsw_snapshot_view` must validate header, checksum, config, all section
ranges/alignment, entry point, IDs, levels, counts, and neighbor ordinals before
returning `HnswGraphView`. The view owns the `MappedFile`, so borrowed addresses
cannot outlive it. If Mojo's ownership model cannot express safe interior
borrows, keep offsets and derive checked reads from the owned mapping instead of
storing escaped pointers.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_hnsw_view.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_store.mojo
```

Expected: PASS.

```bash
git add src/akasha/index/hnsw_view.mojo src/akasha/storage/hnsw_store.mojo src/akasha/index/hnsw_core.mojo tests/mojo/test_hnsw_view.mojo
git commit -m "feat: search validated memory-mapped HNSW views"
```

### Task 25: Overlay WAL mutations in a bounded owned delta

**Files:**

- Create: `src/akasha/index/segmented_hnsw.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Create: `tests/mojo/test_segmented_hnsw.mojo`
- Modify: `tests/mojo/test_persistent_hnsw.mojo`

**Step 1: Write failing base/delta tests**

Cover base-only, delta-only, merged Top-K, base ID replaced in delta, base ID
deleted after checkpoint, delta delete/reinsert, candidate deduplication, exact
rerank, stats split by base/delta, delta threshold, and reopen replaying WAL into
delta without rebuilding/mutating the mapped base.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_segmented_hnsw.mojo`

Expected: FAIL because segmented search is absent.

**Step 3: Implement source-of-current-ID tracking**

`SegmentedHnsw` owns a frozen base view or owned base, a mutable delta index, and
a current-source map. New/replaced IDs go to delta; deletes make the ID absent;
the base remains traversable but base results are rejected when the source map
does not point to that base slot.

Search both indexes with enough candidates (`max(k, ef)` per source), merge by
ID, and exact-rerank from MemTable. If one source is empty, take its fast path.
Record base and delta candidate counts.

**Step 4: Integrate open and maintenance**

Open a compatible sidecar as mapped base when possible, then replay WAL records
newer than its checkpoint into delta. When delta count reaches the configured
maintenance bound, planner may continue to use it, but `needs_rebuild` becomes
true and the next explicit rebuild/flush emits a new base.

**Step 5: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_segmented_hnsw.mojo
pixi run mojo run -I src tests/mojo/test_persistent_hnsw.mojo
pixi run test-crash
```

Expected: PASS.

```bash
git add src/akasha/index/segmented_hnsw.mojo src/akasha/api/collection.mojo tests/mojo/test_segmented_hnsw.mojo tests/mojo/test_persistent_hnsw.mojo
git commit -m "feat: overlay HNSW checkpoint with mutable delta"
```

## Milestone F: Compact vectors and distance backend selection

### Task 26: Extend existing quantization with compact graph vectors

**Files:**

- Modify: `src/akasha/index/quantization.mojo`
- Create: `src/akasha/compute/quantization.mojo`
- Modify: `src/akasha/compute/__init__.mojo`
- Modify: `src/akasha/index/hnsw_storage.mojo`
- Modify: `src/akasha/index/hnsw_view.mojo`
- Modify: `src/akasha/storage/hnsw_store.mojo`
- Create: `tests/mojo/test_quantization.mojo`
- Create: `tests/mojo/test_hnsw_quantized.mojo`

**Step 1: Write failing conversion tests**

For BF16, F16, and I8 cover zero, signs, representative values, finite extremes,
rounding boundaries, deterministic bytes, accumulation into F32, normalized
cosine vectors, magnitude-preserving dot vectors, zero-norm rejection,
per-vector scale, and saturation. Verify I8+L2 remains a configuration error.

**Step 2: Run and verify failure**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_quantization.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_quantized.mojo
```

Expected: existing SQ8/PQ tests PASS; new graph-scalar conversion/storage tests
FAIL because BF16/F16 and bound-metric graph integration are absent.

**Step 3: Implement typed conversion kernels**

Provide encode/decode or direct-distance kernels for each scalar kind. BF16/F16
storage uses native scalar bit widths and F32 accumulation. I8 cosine normalizes
vectors and uses a documented symmetric scale of 127. I8 dot stores
`max(abs(value))/127` as one F32 scale per vector, prepares one query scale, and
multiplies the integer accumulation by both scales so vector magnitude remains
part of approximate ordering. Accumulate integer products in a width proven safe
for the maximum supported dimension, then convert to F32. Enforce the
dimension/accumulator bound in config validation.

Reuse the existing `Sq8Codebook`, `Sq8Index`, `PqCodebook`, and `PqIndex`
training, encoding, and deterministic Top-K behavior. Extract shared rounding,
saturation, accumulator-bound, and quality-fixture helpers instead of adding a
second incompatible I8 codec. PQ remains an optional coarse/rerank index unless
the graph format explicitly gains and tests a PQ scalar tag.

Do not quantize MemTable, WAL, segment, or exact-search values.

**Step 4: Generalize owned and mapped vector sections**

Store graph vector bytes according to `scalar_kind`; compute offsets using the
encoded scalar width. The sidecar header already carries the tag. Decode/view
must reject length mismatches before distance access.

**Step 5: Add quality gates per scalar**

On the same fixed datasets and graph settings, compare recall@10 with F32. Assert
loss <= 0.02 and assert encoded vector bytes per point are 2x smaller for
BF16/F16 and 4x smaller for I8, excluding fixed metadata.

If one scalar fails quality, leave its config tag readable but reject creating a
new index with it; record its failing numbers in the benchmark document. Do not
weaken the gate.

**Step 6: Verify and commit**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_quantization.mojo
pixi run mojo run -I src tests/mojo/test_hnsw_quantized.mojo
pixi run check-hnsw-quality
```

Expected: PASS for each enabled scalar kind.

```bash
git add src/akasha/index/quantization.mojo src/akasha/compute/quantization.mojo src/akasha/compute/__init__.mojo src/akasha/index/hnsw_storage.mojo src/akasha/index/hnsw_view.mojo src/akasha/storage/hnsw_store.mojo tests/mojo/test_quantization.mojo tests/mojo/test_hnsw_quantized.mojo
git commit -m "feat: add compact HNSW vector storage"
```

### Task 27: Select and report a distance backend once per index

**Files:**

- Create: `src/akasha/compute/dispatch.mojo`
- Modify: `src/akasha/compute/metric.mojo`
- Modify: `src/akasha/index/hnsw.mojo`
- Modify: `benchmarks/mojo/distance_bench.mojo`
- Modify: `benchmarks/mojo/hnsw_bench.mojo`
- Create: `tests/mojo/test_distance_dispatch.mojo`
- Create: `docs/adr/0005-distance-dispatch.md`

**Step 1: Write failing selection tests**

For every enabled metric/scalar pair, assert the selected backend name, numerical
agreement with the scalar reference, and no metric/scalar branch counter inside
the dimension loop. The latter can be a test-only dispatcher call counter: one
selection at index creation, zero selections per neighbor distance.

**Step 2: Run and verify failure**

Run: `pixi run mojo run -I src tests/mojo/test_distance_dispatch.mojo`

Expected: FAIL because backend selection is not explicit.

**Step 3: Implement construction-time dispatch**

`select_distance_backend(config)` returns a dispatcher specialized to one
metric/scalar combination and reports `portable-simd-<width>`. Use concrete
method branches outside graph traversal; if Mojo cannot store function pointers
with the required ownership/calling convention, use a small tagged dispatcher
whose tag is switched once by public `search`/`insert` entry points, then call a
parameterized core. Never switch inside a scalar loop or neighbor loop.

Expose this as the HNSW distance-kernel layer beneath the existing query
execution policy. The current parallel scan and GPU planner keep ownership of
CPU/GPU and batch/fallback decisions; they consume the same metric names and
stats vocabulary. Add integration tests proving exact scalar, parallel, GPU
fallback, and HNSW paths report compatible backend/reason fields without
recursively dispatching or silently changing score semantics.

**Step 4: Document the runtime-dispatch boundary**

Record what is compile-time native SIMD versus true runtime multi-ISA dispatch.
Add a future backend interface but do not label it implemented. Include current
platform/compiler evidence and how an optional NumKong/plugin backend would be
validated.

**Step 5: Run the Milestone F gate**

Run:

```bash
pixi run mojo run -I src tests/mojo/test_distance_dispatch.mojo
pixi run test
pixi run test-crash
pixi run build
pixi run bench-distance
pixi run bench-hnsw
pixi run check-hnsw-quality
```

Expected: PASS; output identifies metric, scalar, and real backend.

**Step 6: Commit**

```bash
git add src/akasha/compute/dispatch.mojo src/akasha/compute/metric.mojo src/akasha/index/hnsw.mojo benchmarks/mojo/distance_bench.mojo benchmarks/mojo/hnsw_bench.mojo tests/mojo/test_distance_dispatch.mojo docs/adr/0005-distance-dispatch.md
git commit -m "perf: dispatch HNSW distance backend once"
```

## Milestone G: Adapters and native ABI capability gate

### Task 28: Expose configuration and search stats through Python and HTTP

**Files:**

- Modify: `src/bindings/python_module.mojo`
- Modify: `python/akashadb/models.py`
- Modify: `python/akashadb/database.py`
- Modify: `python/akashadb/operations.py`
- Modify: `python/akashadb/distributed/cluster.py`
- Modify: `python/akashadb/distributed/protocol.py`
- Modify: `python/akashadb/distributed/replica.py`
- Modify: `apps/server/schemas.py`
- Modify: `apps/server/main.py`
- Modify: `tests/python/test_package.py`
- Modify: `tests/python/test_server.py`
- Modify: `tests/python/test_operations.py`
- Modify: `tests/python/test_distributed_protocol.py`
- Modify: `src/akasha/api/snapshot.mojo`

**Step 1: Write failing adapter tests**

Test creating/opening with optional ANN configuration, legacy dimension-only
open, mismatch errors, config round trip, approximate metric fallback, and a
query-stats response containing planner reason/backend/metric/scalar/ef/visited/
distance counts. Keep existing response items compatible; expose stats through a
separate method/endpoint or optional response field rather than changing list
elements unexpectedly.

Cover backup/restore, immutable snapshots, maintenance/operations wrappers, and
distributed routing already present after the rebase. Each path must either
preserve the full collection fingerprint and stats or explicitly reject an
unsupported option before creating durable state.

**Step 2: Run and verify failure**

Run: `pixi run test-python`

Expected: FAIL on absent configuration/stats adapter surface.

**Step 3: Bind Mojo configuration without moving semantics into Python**

Extend the CPython `Collection` initializer to accept an optional dict. Parse it
into `CollectionConfig` in the Mojo binding, call `validate`, then
`open_with_config`. Add bound `collection_config()` and `last_search_stats()`
methods returning copied primitive dictionaries.

Python Pydantic/dataclass models validate user shape for friendly errors, but
Mojo remains authoritative. Update `KernelCollection` protocol and
`LocalDatabase.open` compatibility checks.

**Step 4: Extend HTTP schemas and routes**

`OpenCollectionRequest` gains optional `ann_metric`, `scalar_kind`, M/M0,
efConstruction/default/max ef, rebuild percentage, and seed. Search stats are
available from the response or a collection stats route. Preserve the current
defaults and status/error mapping.

**Step 5: Verify and commit**

Run:

```bash
pixi run test-python
pixi run mojo run -I src tests/mojo/test_public_api.mojo
```

Expected: PASS.

```bash
git add src/bindings/python_module.mojo python/akashadb/models.py python/akashadb/database.py apps/server/schemas.py apps/server/main.py tests/python/test_package.py tests/python/test_server.py
git commit -m "feat: expose HNSW configuration and stats to adapters"
```

### Task 29: Gate and, if supported, implement the opaque-handle C ABI

**Files:**

- Create: `tools/abi_probe.mojo`
- Create: `tests/c/abi_probe.c`
- Create: `docs/adr/0006-c-abi-capability.md`
- Conditionally create after gate passes: `src/bindings/c_api.mojo`
- Conditionally create after gate passes: `include/akasha.h`
- Conditionally create after gate passes: `tests/c/test_akasha_c_api.c`
- Modify after gate passes: `pixi.toml`

**Step 1: Add the smallest compiler capability probe**

Try the installed Mojo 1.0.0 syntax documented by the current compiler for one
exported addition function. The candidate source is:

```mojo
@export("akasha_abi_probe_add")
def akasha_abi_probe_add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b
```

If this exact combination is rejected, consult `mojo build --help` and the
installed standard-library examples; adjust only to syntax supported by the
pinned compiler. Build a native shared library with `mojo build --emit
shared-lib`, inspect the symbol, compile `tests/c/abi_probe.c` with the host C
compiler, link it, and run it expecting 42.

**Step 2: Record the gate result before any API implementation**

Run commands equivalent to:

```bash
mkdir -p .build/abi-probe
pixi run mojo build --emit shared-lib tools/abi_probe.mojo -o .build/abi-probe/libakasha_probe.dylib
nm -gU .build/abi-probe/libakasha_probe.dylib
cc tests/c/abi_probe.c -L.build/abi-probe -lakasha_probe -o .build/abi-probe/probe
DYLD_LIBRARY_PATH=.build/abi-probe .build/abi-probe/probe
```

Use `.so`, `nm -D`, and `LD_LIBRARY_PATH` on Linux. Expected: exported unmangled
symbol and process exit 0.

Write compiler version, accepted syntax, exact commands, symbol output,
ownership limits, and platform result in `docs/adr/0006-c-abi-capability.md`.

**Step 3A: If the gate fails, commit the evidence and stop this task**

Do not create `c_api.mojo` or claim a C ABI. Commit:

```bash
git add tools/abi_probe.mojo tests/c/abi_probe.c docs/adr/0006-c-abi-capability.md
git commit -m "docs: record Mojo C ABI capability gap"
```

Continue to Task 30 with CPython as the supported native adapter.

**Step 3B: If the gate passes, write failing C contract tests**

Define opaque `akasha_collection_t`; fixed-width `akasha_status_t`; POD config,
search-options, result, stats, and caller-owned error structs with explicit
`struct_size`/version; and functions for open, close, upsert, delete, flush,
search, and stats. Tests must cover null pointers, bad sizes/versions, invalid enum tags,
dimension mismatch, caller output capacity, returned count, deterministic IDs/
scores, idempotent close behavior, copied error strings, and reopen persistence.

No Mojo `String`, `List`, exception, or compiler-layout struct crosses the ABI.
All buffers remain caller-owned; Akasha copies input before returning. Search
accepts result capacity and writes actual/required count without overrunning.

**Step 4B: Implement the handle registry and status boundary**

Add `include/akasha.h` first as the contract, then implement every function in
`src/bindings/c_api.mojo`. Catch all Mojo errors at the export boundary and
translate them to status codes plus a message copied into the caller-provided
fixed-layout error output. Use an
opaque registry token or pointer only if lifetime and alignment were proven by
the capability probe. Closing invalidates the handle and releases the collection
lock exactly once.

**Step 5B: Add portable build/test tasks**

Add `build-c` and `test-c` Pixi tasks with a small platform-selecting script only
if TOML cannot express dylib/so differences. Cross-platform release builds may
emit an object and use the target host linker; do not claim Mojo linked
shared-library cross compilation.

**Step 6B: Verify and commit the supported ABI**

Run:

```bash
pixi run build-c
pixi run test-c
pixi run test-python
```

Expected: PASS.

```bash
git add tools/abi_probe.mojo tests/c/abi_probe.c docs/adr/0006-c-abi-capability.md src/bindings/c_api.mojo include/akasha.h tests/c/test_akasha_c_api.c pixi.toml
git commit -m "feat: expose a capability-verified Akasha C ABI"
```

## Milestone H: Final verification and handoff

### Task 30: Complete documentation, benchmarks, and release gates

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/benchmarks/hnsw-baseline.md`
- Modify: `docs/plans/2026-08-26-production-hnsw-design.md`
- Modify: `examples/persistent_collection.mojo`
- Create: `examples/configured_hnsw.mojo`
- Modify: `pixi.toml`

**Step 1: Add a final user-visible example test target**

Create `examples/configured_hnsw.mojo` that opens a cosine/BF16 collection,
upserts a seeded small dataset, performs approximate and mismatched-metric
queries, prints planner/stats fields, flushes, closes, reopens, and verifies the
same result IDs. If BF16 was disabled by Task 26's quality gate, use the most
compact enabled scalar and explain the choice in the example.

Add `example-hnsw` to Pixi. Run it before updating prose and verify any current
documentation/API mismatch fails visibly.

**Step 2: Update architecture and README**

Document:

- metric-bound collection behavior and exact fallback;
- M, M0, efConstruction, efSearch, seed, scalar, and rebuild guidance;
- packed graph, tombstones, explicit maintenance, persisted sidecar, mmap base,
  and delta overlay;
- filter traversal versus result admission;
- authoritative F32 reranking and compact graph vectors;
- actual backend and ABI support, including any failed capability gate;
- all format links and backward compatibility rules;
- operational disk/memory sizing and when flush/rebuild work occurs.

Mark completed design stages accurately; do not mark gated/disabled scalar or C
ABI work as shipped.

**Step 3: Capture final benchmark evidence**

Run the exact same commands/datasets recorded at Task 14. Add a before/after
table for recall, construction distance calls/time, query visited/distance calls,
latency, owned serialized bytes, mapped resident behavior where measurable, and
each enabled scalar. State machine, compiler, OS, CPU, date, and commands.

**Step 4: Run every release gate from explicit build outputs**

Use the existing build tasks, which overwrite their explicit generated outputs;
do not delete source, repository data, or user collection directories. Then run:

```bash
pixi install
pixi run test
pixi run test-crash
pixi run build
pixi run smoke
pixi run example-persistent
pixi run example-hnsw
pixi run check-hnsw-quality
```

If Task 29 passed, additionally run `pixi run test-c`. Expected: every command
exits 0. Record the command results in the final commit message/body or delivery
notes, not as generated repository noise.

**Step 5: Review scope and repository hygiene**

Run:

```bash
git status --short
git diff --check
git log --oneline --decorate -30
```

Confirm there are no generated shared libraries, benchmark dumps, temporary
collection directories, or unrelated user changes staged. Confirm every new
public type is exported deliberately and every new binary format is documented.

**Step 6: Commit final documentation**

```bash
git add README.md docs/architecture.md docs/benchmarks/hnsw-baseline.md docs/plans/2026-08-26-production-hnsw-design.md examples/persistent_collection.mojo examples/configured_hnsw.mojo pixi.toml
git commit -m "docs: complete production HNSW delivery guidance"
```

**Step 7: Request final code review before integration**

Invoke the `requesting-code-review` skill against the full branch diff from its
merge base. Address correctness, data-format, crash-ordering, unsafe-pointer,
and benchmark-gate findings with new focused tests and separate commits. Re-run
Step 4 after any code change.

## Completion checklist

- [ ] Existing exact, sparse, hybrid, metadata, persistence, Python, and HTTP
      behavior remains compatible.
- [ ] ANN construction and traversal use one bound metric consistently.
- [ ] Build no longer scans every prior point at every level.
- [ ] M0, efConstruction, two heaps, radius termination, diversity pruning, and
      symmetric bounded links are tested.
- [ ] Query scratch does not allocate/clear an O(N) visited bitmap per query.
- [ ] Insert/replace/delete are incremental; query never triggers full rebuild.
- [ ] Filtered HNSW admits eligible results during traversal and exact-fallbacks
      when required.
- [ ] Collection config, manifest v2, and HNSW formats are versioned,
      checksummed, bounded, and documented.
- [ ] Owned recovery and mmap view are result-equivalent; WAL mutations live in
      a bounded delta.
- [ ] Every enabled compact scalar passes the stated recall-loss and size gates.
- [ ] Backend reporting distinguishes native compiled SIMD from true runtime
      multi-ISA dispatch.
- [ ] C ABI is either proven by a native C integration test or explicitly
      recorded as unavailable for the pinned compiler.
- [ ] Recall, work, latency, memory, and crash-ordering evidence is reproducible.
- [ ] Full tests, crash tests, builds, examples, and quality gate pass.
