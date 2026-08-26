# Production HNSW Design

## Status

- Date: 2026-08-26
- Scope: single-node Akasha dense approximate search
- Reference implementation studied: USearch v2.26.1 at local commit `0ef97e1`
- Akasha baseline: branch point `2d54d61`
- Decision: approved planning baseline; implementation has not started

## Context

Akasha already exposes a small in-memory HNSW index and persistent collection
approximate-search methods. The current implementation is useful as a behavior
prototype, but it is not yet a production HNSW implementation:

- insertion scans every existing node at every eligible level, so index build is
  approximately quadratic in collection size;
- construction and pruning always use L2 even when a query requests dot product
  or cosine similarity;
- node level is derived from factors of two in the public point ID rather than a
  seeded geometric distribution;
- the base layer has the same degree as upper layers instead of `M0 = 2 * M`;
- construction has no independent `ef_construction` breadth;
- neighbor selection keeps only the closest points and omits HNSW's diversity
  heuristic;
- pruning one adjacency list can leave the reverse edge inconsistent;
- search repeatedly scans a linear candidate list and stops after a fixed number
  of expansions rather than using candidate/result heaps and the HNSW radius
  termination condition;
- every query allocates and clears a `List[Bool]` whose length is the number of
  indexed nodes;
- collection mutation marks the graph dirty and the next approximate query
  rebuilds the complete graph;
- HNSW vectors duplicate live MemTable vectors and recovery clones all live
  vectors before rebuilding;
- filtering is implemented as blind over-fetch followed by filtering and an
  exact fallback, so selective filters waste work and can produce unstable
  latency;
- the graph is not persisted, cannot be memory-mapped, and has no compact vector
  representation;
- there is no recall oracle, graph invariant suite, build-scaling benchmark, or
  query-work telemetry.

USearch separates these concerns more effectively. Its `index.hpp` owns the
generic graph algorithm and packed member layout; `index_dense.hpp` owns dense
vectors, scalar conversion, quantization, and persistence; and
`index_plugins.hpp` owns optional optimized distance backends. Akasha should
adopt that separation without copying USearch's template-heavy C++ architecture.

## USearch-to-Akasha comparison map

The local reference tree is intentionally read as three layers rather than as
one 5,000-line header:

| Research item | USearch code to follow | Akasha state at baseline | Planned Akasha destination |
| --- | --- | --- | --- |
| Node layout | `index.hpp`: `node_t`, `neighbors_ref_t`, `node_neighbors_bytes_`, separate base/upper neighbor byte sizes | `_HnswNode` owns a vector and nested lists per level | Tasks 9 and 13: append-only slot arrays, flat vector tape, fixed `M0 + level*M` neighbor tape |
| Graph levels | `index.hpp`: level-bearing node tape, `search_for_one_`, insertion descent | public ID's trailing factors of two choose level | Task 8: seeded SplitMix64 geometric sampling; Tasks 10/13: standard greedy descent |
| Neighbor pruning | `index.hpp`: `select_neighbors_`/diversity selection and reverse connection path | nearest-only L2 prune; reverse links may become asymmetric | Tasks 11-12: metric-bound diversity heuristic plus symmetric eviction repair |
| Visited set and candidates | `index.hpp`: `visits_hash_set_t`, reusable search context, candidate/result priority queues | allocates `List[Bool](N)` and linearly scans candidates | Tasks 6-7/10: two heaps and generation-stamped reusable scratch |
| Filter predicate | `index.hpp`: search accepts a member predicate while graph traversal continues | over-fetch `max(ef, 4k)`, post-filter, then exact fallback | Tasks 15-16: bitmap eligibility at result admission, progressive ef, planned exact fallback |
| Metric/SIMD dispatch | `index_plugins.hpp`: `metric_punned_t`, selected routed function, compiled/available ISA reporting | metric branch and checked distance calls occur throughout; construction is always L2 | Tasks 5/27: canonical metric, unchecked kernels, one-time honest backend selection/reporting |
| Dense/quantized vectors | `index_dense.hpp`: scalar-kind metadata, cast scratch, vector tape | HNSW duplicates F32 `List` vectors; no compact representation | Task 26: F32/BF16/F16/I8 graph cache with F32 authoritative rerank and recall gates |
| Save/load/view | `index.hpp` and `index_dense.hpp`: explicit serialized headers and separate load/view paths | graph rebuilt from MemTable on every open | Tasks 20-22/24: checksummed sidecar, owned load first, validated view second |
| Memory mapping | `index_dense.hpp`: memory-mapping allocator and `view` ownership | no mmap primitive | Tasks 23-25: RAII read-only mapping, immutable view, mutable WAL delta |
| Stable language boundary | USearch's C library under `c/` and language wrappers above it | CPython-specific Mojo extension and HTTP only | Task 29: compiler-proven opaque-handle C ABI; no wrappers until the gate passes |

One USearch behavior is deliberately not copied: its update path contains an
explicit TODO around removing reverse links from the old neighborhood. Akasha's
first production mutation model instead tombstones the old slot and appends a
new one, making the invariant and recovery story testable before attempting
in-place graph surgery.

## Goals

1. Make graph construction and query faithful to the core HNSW algorithm.
2. Bind graph construction and traversal to one explicit collection ANN metric.
3. Replace object-per-node adjacency with bounded packed storage.
4. Make common mutations incremental and reclaim tombstones through explicit
   rebuild policy rather than rebuild-on-next-query.
5. Make filter-aware ANN traverse the graph while admitting only eligible live
   results.
6. Persist a checksummed graph sidecar and open it without rebuilding when valid.
7. Add a read-only memory-mapped graph view with a mutable delta overlay.
8. Add staged compact vector storage while keeping authoritative F32 values for
   exact results and reranking.
9. Select the metric/scalar distance implementation once per index, outside the
   traversal hot loop.
10. Add a capability-gated C ABI after proving the installed Mojo compiler can
    export a stable C-callable surface.
11. Measure recall, build cost, query work, latency, and memory before claiming
    an optimization.

## Non-goals

- distributed shards, replication, consensus, or multi-writer transactions;
- GPU construction or query;
- deleting arbitrary graph slots in place and perfectly repairing the graph;
- online background compaction in the first implementation;
- a new remote protocol;
- wrappers for Rust, Swift, Go, Java, or Node before the C ABI is stable;
- pretending that one compiled SIMD width is runtime multi-ISA dispatch;
- replacing exact search or the durable vector/document formats as the source of
  truth.

## Core decisions

### One ANN metric per collection

Each collection binds its graph to exactly one `MetricKind`: dot product, squared
L2, or cosine. Graph construction, neighbor pruning, upper-level descent, and
base-layer search all use that same metric.

`PersistentCollection.open(path, dimension)` remains compatible and creates or
migrates a collection with L2 as its bound ANN metric. A new
`open_with_config(path, config)` creates or validates an explicit configuration.
Exact search continues to accept any supported metric. If an approximate query
requests a metric other than the bound ANN metric, the query planner routes it
to exact search instead of traversing a graph built under incompatible geometry.

Alternatives rejected:

- Building three graphs preserves query flexibility but roughly triples graph
  and vector-cache memory.
- Keeping one L2 graph for every query metric is fast to implement but has no
  defensible recall contract for dot or cosine search.
- Rejecting mismatched approximate queries would break existing callers that
  currently choose a metric per request. Exact fallback preserves semantics.

### Canonical internal distance

HNSW uses a lower-is-better distance internally:

- L2: squared Euclidean distance;
- dot: negative dot product;
- cosine: `1 - cosine_similarity`.

The public `SearchResult.score` keeps Akasha's current semantics: raw dot and
cosine scores are larger-is-better; squared L2 is smaller-is-better. Conversion
between canonical distance and public score occurs only at the query boundary.
Ties remain deterministic by ascending point ID.

For cosine collections, graph vectors are normalized once on insertion. Zero
norm vectors are rejected for the cosine ANN path. The authoritative stored F32
vector remains unmodified and exact search retains its existing validation and
score semantics.

### Durable collection configuration

Configuration must survive when a collection contains only WAL records and has
not produced a manifest yet. It therefore lives in a dedicated immutable
`collection.bin`, not only in the checkpoint manifest.

Version 1 contains:

```text
magic = "AKCF"
version = 1
dimension: u32
ann_metric: u8
scalar_kind: u8
m: u16
m0: u16
ef_construction: u32
default_ef_search: u32
max_ef_search: u32
max_level: u16
rebuild_inactive_percent: u8
delta_max_points: u32
level_seed: u64
reserved: fixed zero bytes
crc32: u32
```

The file is validated before WAL or segment recovery. It is written through a
temporary file, fsynced, atomically renamed, and followed by a directory fsync.
Creation validates all cross-field constraints, including `m0 >= m`,
`ef_construction >= m0`, `max_ef_search >= default_ef_search`, a positive delta
bound, and an allowed scalar/metric combination.

When opening legacy data without `collection.bin`, Akasha validates the caller's
dimension and writes a default L2/F32 configuration without rewriting existing
WAL or segments. Subsequent opens must match the durable dimension. Explicit
configuration passed for an existing collection must match every immutable
field.

### Packed mutable graph

The mutable graph uses stable append-only slot ordinals. Public point IDs are
looked up through `Dict[Int, UInt32]`; graph links never store public IDs.

Each slot stores:

```text
id: Int
level: UInt16
flags: live/current bits
vector_offset: UInt64
neighbor_offset: UInt64
neighbor_counts: one UInt16 per owned level
neighbor_slots: fixed M0 capacity at level 0, fixed M at each upper level
```

All vector scalars are held in one flat typed buffer. All neighbor slots are
held in one flat `UInt32` buffer with `UInt32.MAX` as the unused sentinel. A
node's complete neighbor capacity is allocated once when its level is chosen, so
ordinary insert/link/prune operations mutate counts and slots in place without
allocating nested lists.

This is less compact than a frozen CSR-like graph but is straightforward and
safe for incremental insertion. Checkpoint serialization converts it into a
read-only layout whose offsets and counts can be memory-mapped.

### Seeded geometric levels

Point IDs must not control graph shape. The implementation hashes
`bitcast(id) XOR level_seed` with SplitMix64 and maps the result to a uniform
open interval. Level is sampled as:

```text
floor(-ln(u) / ln(M))
```

and capped by `max_level`. This gives stable recovery for the same configuration
and insertion order, does not allocate a mutable RNG, and avoids pathological ID
patterns. Tests verify determinism, seed sensitivity, bounds, and a broad
distribution sanity check without relying on exact bucket counts.

### Standard HNSW construction

Insertion follows these phases:

1. Validate and encode the vector once.
2. Starting at the current entry point, greedily descend through levels above
   the new node's level.
3. At each shared level, run `search_layer` with `ef_construction`.
4. Select at most the level capacity with the diversity heuristic: accept a
   candidate when it is closer to the new node than to every already-selected
   neighbor; optionally fill remaining capacity by nearest distance.
5. Add forward and reverse edges.
6. If a reverse adjacency exceeds capacity, reselect it with the same heuristic
   and remove every evicted reverse link from its counterpart.
7. Promote the new slot to entry point when its level is higher.

Level 0 uses `M0`; upper levels use `M`. Construction uses the collection's
canonical distance and never exact-scans all prior points.

### Heap-based search and reusable scratch

`search_layer` uses two binary heaps:

- a min-heap of unexplored candidates ordered by canonical distance then point
  ID;
- a max-heap of retained results ordered by worst canonical distance then
  reverse point ID.

Once the result heap contains `ef` items, traversal stops when the best
unexplored candidate is worse than the current worst retained result. Deleted or
filter-rejected slots may still be traversed because they can connect eligible
regions, but they never enter the returned-result heap.

Per-query scratch owns both heaps, a result buffer, and a generation-stamped
visited array. Marking a slot writes the current `UInt32` epoch. Beginning a
query increments the epoch in O(1); wraparound clears the array once. Capacity
grows only when the graph grows. This removes an O(N) allocation and clear from
normal queries.

Akasha currently promises a single writer and does not promise simultaneous
mutation/query on one value. The first implementation may keep one reusable
scratch object inside `HnswIndex`. A future read-concurrency design must provide
one scratch object per reader rather than adding locks to the hot loop.

### Filter-aware traversal

Metadata expressions are still evaluated into an Akasha `Bitmap` before vector
search. The bitmap is passed into HNSW as an allow predicate:

- every visited neighbor remains traversable;
- only live, current, allowed slots may enter the result heap;
- returned IDs are exact-reranked using authoritative F32 MemTable vectors;
- `ef_search` widens geometrically when too few eligible results are found, up
  to a configured cap;
- highly selective filters and exhausted widening route to exact prefiltered
  search.

The planner considers total live count, allowed count, `k`, metric compatibility,
graph readiness, and estimated HNSW work. It no longer relies on a single blind
`k * 4` over-fetch. Correctness is preserved because the exact path remains the
fallback whenever the ANN path cannot fill `k` results.

### Mutation and tombstones

- New ID: append one graph slot and insert it incrementally after the WAL and
  MemTable mutation succeeds.
- Replace existing ID: mark the old slot non-current, append and insert a new
  slot, then atomically update the ID-to-slot map.
- Delete: mark the current slot non-current and remove the ID mapping.
- Traversal may cross non-current slots; result admission always rejects them.

This avoids risky local graph surgery on replacement and deletion. A synchronous
rebuild is scheduled at the next explicit maintenance point when inactive slots
reach the configured percentage, the mutable delta exceeds its bound, or slot
ordinals approach `UInt32.MAX`. `flush()` may rebuild before snapshotting when a
threshold is exceeded, but an ordinary query never triggers an unbounded full
rebuild.

### Persisted HNSW sidecar

Manifest version 2 adds an optional HNSW sidecar reference:

```text
hnsw_name
hnsw_checksum
hnsw_config_fingerprint
hnsw_point_count
```

The sidecar header contains magic, format version, checkpoint sequence,
configuration fingerprint, dimension, metric/scalar tags, counts, entry slot,
entry level, section offsets/lengths, and a whole-file checksum. Sections contain
IDs, levels/flags, vector data, neighbor offsets/counts, and neighbor slots. All
integer widths and byte order are documented and every offset/length is bounds
checked before allocation or pointer construction.

Checkpoint order is:

```text
write + fsync segment temporary
write + fsync sparse sidecar temporary
write + fsync HNSW sidecar temporary
rename all completed data files + directory fsync
publish + fsync manifest v2 (commit point)
rotate WALs
remove only superseded files named by the previous valid manifest
```

A v1 manifest or a v2 manifest without a compatible HNSW sidecar rebuilds the
graph from authoritative live records. A checksum, sequence, configuration,
point-count, or structural validation failure never produces partial ANN
results: open rebuilds when the file is merely stale/missing and rejects files
whose corruption could indicate a damaged committed checkpoint.

### Memory-mapped frozen graph plus delta

Owned deserialization ships first. Memory mapping is added only after the binary
format and validation suite are stable.

`MappedFile` wraps POSIX `open`, `fstat`, `mmap`, `munmap`, and `close` through
Mojo FFI with RAII ownership. `HnswGraphView` borrows validated immutable slices
from the mapped region. No typed pointer is constructed until byte ranges,
alignment, element counts, and overflow are validated.

Mutations after open go into a small owned `HnswIndex` delta. Approximate queries
search both frozen base and delta, union IDs, reject stale base versions through
the current ID-to-source map, and exact-rerank the merged candidates. When the
delta reaches its configured bound, explicit rebuild/flush emits a new frozen
base. This keeps mapped pages read-only and avoids mutating persisted adjacency.

The first mmap implementation supports macOS ARM64 and Linux x86-64, matching
the Pixi platforms. Unsupported targets fall back to owned loading.

### Compact vector storage

The graph vector cache is independently configurable from authoritative segment
vectors:

- `F32`: baseline and reference implementation;
- `BF16`: first compact representation because Mojo supports native conversion;
- `F16`: enabled after conversion/accumulation tests pass;
- `I8`: enabled only for dot/cosine in the first release. Cosine uses normalized
  vectors with a fixed symmetric scale; dot preserves magnitude with one F32
  symmetric scale per stored vector and one per prepared query. L2 + I8 is
  rejected until its error behavior has an explicit design.

Distance accumulates into F32. Search always exact-reranks the ANN candidate set
against authoritative F32 vectors before returning public scores. Persistence
records the scalar kind and rejects a sidecar whose scalar tag differs from the
collection configuration.

Quality gates compare each compact representation with the F32 graph on fixed
seeded datasets. A scalar kind is not considered available merely because it
round-trips; it must also meet the recall-loss and memory-footprint gates.

### Distance dispatch

Traversal must not switch on metric and scalar kind for every distance. Index
construction selects a concrete backend once and stores a small dispatcher that
exposes query-to-member and member-to-member canonical distance operations.

The portable backend uses Mojo SIMD with the compile-time native SIMD width.
Backend/scalar/metric names are exposed in query stats and benchmarks. True
runtime multi-ISA dispatch is a later optional backend that must prove compiler
and packaging support; it is not represented as complete by a runtime string
switch around the same compiled function.

### Capability-gated C ABI

Mojo 1.0.0 is installed in the project. The implementation must first compile
and run a minimal C program against a shared library exporting one C-callable
function. The probe tests the compiler syntax, symbol visibility, calling
convention, ownership boundary, and host linking command actually available in
this pinned environment.

Only after that probe passes does Akasha add an opaque-handle C API. The proposed
surface uses fixed-width C types, caller-owned input buffers, caller-sized output
buffers, integer status codes, and a caller-owned fixed-layout error output on
every fallible call. No Mojo `String`, `List`, exceptions, thread-local error
state, or layout-dependent struct crosses the boundary.

Representative operations are create/open/close, upsert, delete, exact/ANN
search, flush, and query stats. Every function documents pointer lifetime and
whether output length is input capacity or actual count. A C integration test
builds and runs outside Mojo. If the probe fails, the task records an ADR with
the missing capability and stops there; the existing CPython adapter remains the
supported native integration.

## Query data flow

```text
request
  -> validate dimension, finite values, k, ef, metric
  -> evaluate metadata expression to allowed bitmap (when present)
  -> planner
       exact when small/selective/incompatible/unready
       ANN otherwise
  -> normalize/quantize query once for ANN
  -> greedy upper descent
  -> filtered heap search at base (base view + mutable delta)
  -> authoritative-F32 exact rerank and public score conversion
  -> deterministic Top-K by score then point ID
```

## Failure and recovery policy

- Invalid public input fails before WAL append or sequence consumption.
- Failure after WAL append but before graph mutation leaves the durable mutation
  authoritative; the collection marks ANN unavailable and rebuilds only during
  explicit recovery/maintenance, while queries use exact search.
- A stale or absent graph sidecar causes rebuild, not data loss.
- A committed sidecar with an invalid checksum or unsafe layout is reported as
  storage corruption; Akasha never maps unchecked offsets.
- Mmap failure falls back to validated owned loading when bytes are valid.
- Quantized graph incompatibility falls back to rebuild from F32 records.
- A full result set is never fabricated when filter-aware ANN is exhausted;
  exact search completes the request.

## Observability

`HnswSearchStats` records:

- backend, metric, scalar kind, and whether the graph was owned or mapped;
- requested/effective `ef_search` and widening rounds;
- upper-level and base-layer visited counts;
- distance evaluations;
- candidates retained and exact-reranked;
- filtered and tombstoned candidates rejected;
- base/delta candidate counts;
- exact-fallback reason;
- elapsed time reported by benchmarks, not by the index hot loop.

`HnswBuildStats` records point count, active/inactive slots, maximum level,
directed edge count by level, distance evaluations, elapsed benchmark time, and
serialized bytes.

## Verification strategy

### Correctness

- deterministic unit tests for heaps, levels, packed adjacency, diversity
  selection, bidirectional-edge invariants, tombstones, filters, score
  conversion, persistence validation, and mmap bounds;
- property-style seeded datasets comparing ANN result IDs with FlatIndex exact
  results;
- replacement/delete/reinsert tests where old slots remain traversable but
  cannot be returned;
- v1 manifest and legacy no-config migration tests;
- crash tests for every checkpoint boundary involving the graph sidecar;
- byte-corruption tests for header, counts, offsets, checksums, and truncation;
- C integration tests only after the ABI probe passes.

### Quality gates

- F32 recall@10 at `ef_search = 64` is at least 0.95 on the checked-in seeded
  clustered and uniform datasets;
- filtered ANN followed by exact fallback is result-equivalent to exact search
  for all existing filter semantics;
- doubling dataset size does not exhibit the approximately 4x build-work growth
  of a complete quadratic scan; distance-evaluation counts are the primary gate,
  wall-clock time is diagnostic;
- query visited count is independent of an O(N) visited-array clear in the
  steady state;
- owned and mmap graph views return identical candidate ordering and stats,
  excluding timing;
- BF16/F16/I8 each document memory use and may ship only when recall@10 loses no
  more than two percentage points relative to the same F32 graph at the selected
  `ef_search`;
- all existing Mojo, Python, crash, build, smoke, and persistent examples pass.

## Delivery stages

1. Establish recall/build/query-work oracles and immutable configuration.
2. Replace the graph core with packed storage, heaps, reusable visited state,
   standard construction, and consistent metric semantics.
3. Integrate filter-aware traversal and incremental mutation into the
   collection, retaining exact fallback.
4. Add sidecar persistence and manifest v2 compatibility.
5. Add validated owned load, then mmap view plus mutable delta.
6. Add compact vector kinds and per-index distance dispatch.
7. Run the C ABI capability gate and implement the ABI only if it passes.
8. Expose configuration/stats through Python and HTTP, run all quality gates,
   and update architecture/format documentation.

Each stage is independently testable and keeps the exact path operational. A
later stage must not be used to hide a correctness or performance regression in
an earlier one.
