# AkashaDB

AkashaDB is an experimental embedded vector database kernel written in Mojo. It
provides validated CPU-SIMD exact search, metric-bound production HNSW with
compact graph vectors, and a crash-recoverable single-writer storage engine
built from a binary WAL, latest-state MemTable, immutable base/delta segments,
generation manifests, and crash-safe compaction.

## Requirements

- macOS Apple Silicon or Linux x86-64
- Pixi
- A C compiler and linker (`xcode-select --install` on macOS or GCC on Linux)

The toolchain is pinned to Mojo 1.0.0 and MAX 26.5.0, the latest stable releases
verified on 2026-09-07. Pixi locks both macOS ARM64 and Linux x86-64 packages.
Nightly releases are not part of this stability baseline.

## Get started

```bash
pixi install
pixi run test
pixi run build
pixi run build-python
pixi run smoke
pixi run test-crash
```

Run the persistent collection example:

```bash
pixi run example-persistent
pixi run example-hnsw
```

CI runs CPU tests, crash recovery, the C ABI integration test, builds, all three
examples, and `check-hnsw-quality` on both operating systems. The matrix uses
`fail-fast: false`, so a failure on one OS does not cancel the other. A native C
probe also checks the mmap ABI against Mojo's layout constants, and macOS runs
the mapping tests with a generic ARM64 CPU target without AMX. GPU validation
remains the separate `pixi run test-gpu` gate on actual GPU hardware.

Store a vector with a flat typed document payload, then retrieve the complete
document through a search result ID:

```mojo
from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)

var collection = PersistentCollection.open("/tmp/my-vectors", 3)
var fields = List[DocumentField]()
fields.append(
    DocumentField("chunk_text", PayloadValue.string("Vector database notes"))
)
fields.append(DocumentField("page", PayloadValue.integer(7)))
fields.append(DocumentField("verified", PayloadValue.boolean(True)))
collection.upsert_document(42, [1.0, 0.0, 0.0], fields^)
collection.flush()
collection.close()

var reopened = PersistentCollection.open("/tmp/my-vectors", 3)
var query: List[Float32] = [1.0, 0.0, 0.0]
var conditions = List[FilterCondition]()
conditions.append(
    FilterCondition.greater_or_equal("page", PayloadValue.integer(5))
)
var results = reopened.search_cosine_filtered(query, 10, conditions)
var document = reopened.get(results[0].id)
var chunk = document.value().get_field("chunk_text").value().as_string()
```

`upsert(id, vector)` remains available for vector-only records. The document
API accepts at most 1,024 unique, non-empty field names and a 16 MiB encoded
payload. Values are explicitly tagged as `String`, `Int64`, finite `Float64`,
or `Bool`. `get(id)` returns an owned record containing its vector, sequence,
and fields; deleted or unknown IDs return `None`.

Typed metadata filters are available for dot-product, squared-L2, and cosine
search through `search_*_filtered`. Conditions are combined with AND and run
before vector scoring. String and Bool support `==` and `!=`; Int64 and finite
Float64 additionally support `<`, `<=`, `>`, and `>=`. Missing fields and type
mismatches do not match, including inequality. Phase 4.2 performs a linear
migration-compatible API; Phase 9 evaluates it through the derived metadata
index.

For Boolean logic, build a bounded expression and use `search_*_where`:

```mojo
var alternatives = List[FilterExpression]()
alternatives.append(
    FilterExpression.condition(
        FilterCondition.equal("kind", PayloadValue.string("article"))
    )
)
alternatives.append(
    FilterExpression.negate(
        FilterExpression.condition(
            FilterCondition.equal("archived", PayloadValue.boolean(True))
        )
    )
)
var expression = FilterExpression.any(alternatives^)
var results = reopened.search_cosine_where(query, 10, expression)
```

`FilterExpression.all`, `any`, and `negate` form an owned flat-arena tree.
Empty All matches and empty Any does not. Expressions are limited to 16 levels
and 256 nodes. The Phase 4.2 `search_*_filtered` AND-list methods remain
supported.

Approximate dense search is available through `search_dot_approx`,
`search_l2_approx`, and `search_cosine_approx`; each accepts `ef_search` after
`k`. Boolean-filtered variants use the `_approx_where` suffix. The planner uses
exact scan for collections smaller than 64 live points, for selective filters,
and when the requested metric differs from the graph metric. Otherwise it
searches a deterministic HNSW graph with heap-based traversal. Filtered search
traverses every reachable graph node but admits only live IDs in the filter
bitmap, progressively widens `ef_search`, and exact-falls back when the candidate
set is insufficient. ANN candidates are always reranked against authoritative
Float32 vectors, including when the graph stores BF16, F16, or I8 values.

Each collection persists one immutable ANN metric and scalar kind in
`collection.bin`. Use `PersistentCollection.open_with_config` to choose them;
the legacy `open(path, dimension)` entry point creates the L2/F32 defaults.
`M` limits upper-layer degree, `M0` limits base-layer degree,
`ef_construction` controls build breadth, and query `ef_search` trades work for
recall up to `max_ef_search`. `level_seed` makes graph levels reproducible and
is collection identity, not a per-run random seed. BF16 or F16 halves graph
vector bytes; I8 quarters them before its optional per-vector scale, but I8 is
supported only for dot and cosine. Start with the defaults, raise
`ef_construction` for build quality, and raise `ef_search` for query recall.
The runnable cosine/BF16 configuration is in
[`examples/configured_hnsw.mojo`](examples/configured_hnsw.mojo).

Acknowledged writes update a bounded owned delta only after WAL, MemTable, and
metadata mutation succeeds. Replacements and deletes tombstone old graph slots;
they remain traversable but can never be returned. `flush()` writes a
versioned, checksummed `hnsw-<sequence>.bin` sidecar and rebuilds first when the
inactive-slot or delta threshold requires it. `rebuild_hnsw()` is the explicit
operator control for an immediate rebuild; queries never rebuild. Reopen
validates and memory-maps the immutable base, then overlays newer WAL mutations
in owned memory. Mapping acquisition failure uses validated owned loading;
committed checksum or layout corruption fails recovery rather than serving an
unchecked graph. Missing or stale derived state is rebuilt from authoritative
records.

For sizing, authoritative vectors still cost `dimension * 4` bytes per live
point independently of HNSW. Graph vector payload is `dimension * 4` for F32,
`dimension * 2` for BF16/F16, or approximately `dimension` for I8; graph IDs,
slot metadata, and bounded adjacency add storage proportional to `M0` and `M`.
Mapped base pages are file-backed and demand-paged, while only the mutable delta
is heap-owned. Flush may therefore include graph rebuild and sidecar I/O when a
threshold is crossed; provision disk for a new sidecar plus the previous
manifest-referenced generation until publication and reader-pin reclamation
complete.

The shipped CPU backend is selected once per graph and reported honestly in
query stats (for example `portable-simd-4` on the recorded Apple M4 Pro). This
is the compiler-selected portable SIMD width, not runtime multi-ISA dispatch.
See [`docs/adr/0005-distance-dispatch.md`](docs/adr/0005-distance-dispatch.md).
Durable compatibility is specified by
[`collection.bin`](docs/formats/collection-config-format.md),
[`manifest.bin`](formats/manifest-format.md),
[`segment`](formats/segment-format.md), and [`WAL`](formats/wal-format.md)
formats; legacy readers are retained only where those contracts say so, while
new checkpoints publish the current versions.

Immutable snapshots also expose deterministic Phase 12 execution paths:

```mojo
var snapshot = collection.snapshot()
var parallel = snapshot.search_l2_parallel(query, 10)
var sq8 = snapshot.search_sq8_l2(query, 10, rerank_k=50)
var pq = snapshot.search_pq_l2(
    query, 10, subquantizers=4, centroids=16, rerank_k=50
)
var device = snapshot.search_device_l2_batch[use_accelerator=True](
    queries, 10, GpuExecutionOptions(enabled=True)
)
```

SQ8 uses per-dimension affine byte codes. PQ uses deterministically trained
subvector centroids. `rerank_k=0` returns approximate scores; a value at least
`k` rescores those candidates against the snapshot's original Float32 vectors.
Single-query parallel scan uses fixed ordinal ranges and deterministic heap
merge, so worker scheduling cannot alter ties.

GPU execution is opt-in: `GpuExecutionOptions()` defaults to CPU execution.
The measured Apple M4 Pro workloads still favor CPU after GPU optimization;
`enabled=True` permits the existing work/memory checks and actual-device path.
Run `pixi run bench-gpu-crossover` on your hardware and compare cold and resident
costs separately. Results expose the planner reason, cache hit, allocation/upload
counts and optional stage timings. See [the measured results](docs/benchmarks/post-hnsw-performance.md).

Caller-provided sparse vectors use ascending `(term_id, weight)` elements:

```mojo
collection.upsert_sparse(
    42, [SparseElement(7, 1.0), SparseElement(99, 0.5)]
)
var sparse = collection.search_sparse_dot(
    [SparseElement(7, 0.8)], 10
)
var hybrid = collection.search_hybrid_cosine(
    query, [SparseElement(7, 0.8)], 10, 50
)
```

Sparse state has its own checksummed WAL and a full sidecar committed at the
dense manifest sequence. Hybrid search retrieves dense and sparse rankings
independently and combines them with deterministic reciprocal-rank fusion.
`search_sparse_dot_where` and `search_hybrid_*_where` evaluate Boolean metadata
before candidates enter their rankings.

Run the exact-search microbenchmarks:

```bash
pixi run bench-distance
pixi run bench-flat
pixi run bench-hnsw
pixi run bench-hnsw-quality
pixi run check-hnsw-quality
pixi run bench-metadata
pixi run bench-compaction
pixi run bench-batch
pixi run bench-phase11
pixi run bench-phase12
pixi run test-gpu
pixi run bench-phase13-gpu
```

Operational validation and recovery are available through:

```bash
pixi run build-python
PYTHONPATH=python:. python -m akashadb.admin scan ./data/demo 384
PYTHONPATH=python:. python -m akashadb.admin backup ./data/demo 384 ./backups/demo
```

See [`docs/operations.md`](docs/operations.md) for backup/restore, logical
NDJSON export/import, conservative orphan quarantine, limits, cancellation,
metrics, tracing, and graceful shutdown semantics.

`test-gpu` is an actual-device gate, not a skip-capable portability test. Apple
silicon requires Xcode 16+ and may require
`xcodebuild -downloadComponent MetalToolchain`. The regular `pixi run test`
always verifies the compile-time CPU fallback and does not require a GPU.

Use the compiled in-process Python adapter:

```python
from akashadb import Collection, SearchRequest

collection = Collection("/tmp/python-vectors", 3)
collection.upsert(1, [1.0, 0.0, 0.0])
results = collection.search(
    SearchRequest("cosine", 10, vector=[1.0, 0.0, 0.0])
)
collection.close()
```

Parallel batches may carry one Boolean filter expression per query:

```python
filters = [
    {
        "kind": "condition",
        "name": "kind",
        "operator": "eq",
        "type": "string",
        "value": "chunk",
    }
]
results = collection.search_batch(
    "cosine",
    [[1.0, 0.0, 0.0]],
    10,
    num_workers=4,
    filters=filters,
)
```

`pixi run build-python` compiles `src/bindings/python_module.mojo` into the
ignored, platform-local `python/akashadb/_kernel.so`. Python models translate
typed payload, sparse, Boolean-filter, approximate, and hybrid requests; the
extension owns the Mojo collection and performs every database operation.
See [`docs/python-api.md`](docs/python-api.md) for atomic batch and filtered
batch examples.

### Native C ABI

`include/akasha.h` exposes ABI version 1 for native hosts. It uses an opaque
collection handle, fixed-width versioned structs, caller-owned path/vector/
result/error buffers, and integer status codes; no Mojo layout or exception
crosses the boundary. The surface covers configured open, upsert, delete,
flush, metric-bound ANN search, last-search stats, and close. Close accepts a
handle pointer, releases once, and clears the caller's slot. Build and execute
the external C11 contract test with:

```bash
pixi run build-c
pixi run test-c
```

The export/link/runtime-initialization capability was proven on macOS arm64
with Mojo 1.0.0. Linux build/link commands are encoded in Pixi but require a
Linux host gate; no cross-platform binary claim is made. See
[`ADR 0006`](docs/adr/0006-c-abi-capability.md) for the ownership and versioning
contract.

Run the local HTTP adapter:

```bash
pixi run serve
```

It exposes `/health`, collection open/close/flush, point upsert/delete/get, and
exact/approximate/sparse/hybrid search. `akashadb.arrow` keeps its copying column
helpers and adds an owned Arrow C Data `RecordBatch` path with explicit leases.

### Arrow C Data batch ingest

```python
import pyarrow as pa
from akashadb import Collection, upsert_record_batch

collection = Collection("./data/demo", 3)
batch = pa.record_batch(
    [
        pa.array([1], type=pa.int64()),
        pa.FixedSizeListArray.from_arrays(
            pa.array([0.1, 0.2, 0.3], type=pa.float32()), 3
        ),
        pa.array(["first chunk"], type=pa.string()),
    ],
    names=["id", "vector", "payload.chunk"],
)
upsert_record_batch(collection, batch)
```

The adapter imports Arrow C Data capsules and does not materialize intermediate
Python lists. Arrow owns input buffers through the synchronous call; accepted
values are then copied once into Akasha's durable WAL/MemTable ownership domain.

## Architecture

The Mojo kernel under `src/akasha` never depends on Python or FastAPI. Language
bindings live under `src/bindings`, and runnable adapters live under `apps`.
See [`docs/architecture.md`](docs/architecture.md) for the dependency direction
and initial data paths.

## Current milestone

Implemented:

- Dot product, squared L2 distance, and cosine similarity.
- Scalar correctness-oracle and hardware-width CPU SIMD kernels.
- Input validation for empty, mismatched, non-finite, and zero-norm vectors.
- An owning in-memory `FlatIndex` with one-pass bounded-heap Top-K selection.
- Stable ascending point-ID tie-breaking for equal scores.
- `PersistentCollection` upsert, delete, exact search, flush, and reopen.
- Atomic vector-plus-payload `upsert_document` and owned point lookup with
  `get`.
- Flat typed document fields for chunk text, image URIs, MIME types, and scalar
  metadata.
- Versioned little-endian WAL, segment, and manifest formats with CRC32.
- WAL append fsync, immutable base/delta publication, and atomic generation
  manifest commit.
- Enforced single-writer collection ownership with deterministic `close()`.
- Ordered incremental checkpoints that rotate the WAL only after all paired
  dense/sparse segment files and the new manifest generation are durable.
- WAL-only and snapshot-plus-WAL recovery, including torn-tail repair.
- Backward-compatible WAL and segment readers for Phase 3 version 1 data;
  subsequent writes and snapshots use payload-aware version 2 formats.
- Strict typed AND metadata filters evaluated before exact SIMD scoring for all
  three vector metrics.
- Bounded Boolean All/Any/Negate filter expressions with pre-score evaluation.
- Derived in-memory metadata indexes with 64-bit candidate bitmaps, String/Bool
  postings, and sorted Int64/Float64 equality and range lookup.
- Incremental metadata index maintenance for replace/delete and deterministic
  rebuild after WAL or snapshot recovery without changing durable formats.
- Metric-bound packed HNSW with M/M0, independent construction/query breadth,
  seeded geometric levels, diversity pruning, symmetric bounded links,
  generation-stamped visited scratch, post-commit incremental mutation,
  filter-aware admission, authoritative F32 rerank, and exact fallback.
- Versioned SQ8 and product quantization with deterministic codebooks,
  approximate dot/L2/cosine scoring, and optional exact rerank.
- Fixed-range single-query parallel exact scan with deterministic local-heap
  merge for unfiltered and Boolean-filtered snapshots.
- Manifest v3 HNSW sidecars with strict checksums, bounds, graph validation,
  mmap/owned open paths, and a bounded mutable delta; tombstone or delta policy
  triggers explicit/flush-time rebuild while graph failure keeps exact search
  available.
- F32, BF16, and F16 graph storage for all three metrics plus I8 dot/cosine,
  each guarded by deterministic recall-loss and serialized-size tests.
- One-time portable SIMD distance dispatch with backend/metric/scalar/storage
  reporting and no metric/scalar switch in HNSW traversal loops.
- Capability-verified C ABI v1 with an opaque Mojo-owned collection handle,
  fixed-width versioned PODs, caller-owned buffers, and an external C11 test.
- Batched Mojo GPU dot/L2/cosine scoring and deterministic GPU Top-K for Apple,
  NVIDIA, or AMD accelerators, with device-memory planning and exact CPU
  fallback for disabled, unavailable, small, memory-rejected, or failed work.
- Projected point reads plus Arrow C Data batch ingest for fixed-size dense
  vectors, aligned sparse lists, and typed payload columns with one-shot leases.
- Generation-pinned online backup, manifest-last restore, strict format/checksum
  inspection, logical export/import, conservative orphan quarantine, bounded
  cancellable queries, safe metrics/traces, and graceful server shutdown.
- Versioned shard routing, checksummed replicated journals, quorum prepare/commit,
  leader failover, replica catch-up, snapshot-plus-tail rebalancing, and
  deterministic distributed dense/sparse/hybrid/filtered query merge across
  independent Mojo replica processes.
- Durable caller-provided sparse vectors, inverted-index dot-product retrieval,
  and deterministic dense/sparse RRF hybrid search.
- Backward-compatible Manifest v2 and Segment v3 readers with ordered base and
  L0 delta recovery for both dense and sparse state.
- Threshold-triggered full-coverage compaction that publishes one new base,
  drops covered tombstones, and reclaims only files removed from the manifest.
- Immutable read snapshots with owned dense, sparse, payload, and metadata
  state; generation pins defer obsolete-file reclamation through compaction.
- Atomic WAL v3 mutation batches with contiguous sequences and all-or-none
  crash recovery.
- Deterministic scoped parallel batch query for all dense metrics and one
  Boolean metadata expression per input query.
- Serialized concurrent writers plus an engine-owned bounded pthread
  maintenance worker, deterministic drain/close, failure propagation, and a
  synchronous fallback when the native worker library cannot load.
- A compiled Mojo Python extension, typed Python facade and errors, functional
  FastAPI routes, and copying Arrow-compatible batch columns.

Text and image bytes are not embedded by the database: callers generate vectors
externally and may persist the original text or an image URI as fields. Filtered
search returns candidate IDs and scores; callers resolve payloads with `get`.
Phases 10–16 are implemented. The distributed transport is a loopback,
authenticated reference deployment; see
[`docs/distributed.md`](docs/distributed.md) for production boundary details.
