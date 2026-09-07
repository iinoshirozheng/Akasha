# AkashaDB Architecture

AkashaDB starts as an embedded, single-node document and vector database. The Mojo kernel owns data modeling, query planning, indexing, persistence, and compute. Python and HTTP support are adapters and must not become dependencies of the kernel.

## Dependency direction

```text
apps / Python SDK
        |
    bindings
        |
   public API
        |
query + indexes
        |
storage + compute + document + common
```

## Initial write path

```text
validate vector + flat typed fields
   -> assign sequence
   -> append atomic vector-plus-payload WAL v2 record + fsync
   -> latest complete document in MemTable
   -> exact SIMD search

flush
   -> changed dense/sparse records plus HNSW sidecar into temporary files + fsync
   -> atomic data-file renames + directory fsync
   -> atomic Manifest v3 generation publish + directory fsync
   -> atomic empty WAL replacement + directory fsync
   -> threshold signal coalesces into one background maintenance request
   -> worker locks the same writer boundary and may publish one full base
```

## Initial read path

```text
manifest -> ordered v1/v2/v3 base+deltas -> newer WAL replay -> MemTable
                                                               |
query -> immutable read snapshot -> typed filter -> SIMD -> bounded Top-K IDs
                                                               |
                                    get(ID) -> owned document <-+
```

Approximate dense queries use a derived, metric-bound HNSW graph. Seeded
geometric levels are independent of point IDs; construction performs greedy
upper descent, bounded `ef_construction` layer search, diversity selection, and
symmetric degree repair with separate M0/M capacities. Query uses two heaps and
generation-stamped visited scratch. The planner keeps small, selective,
metric-mismatched, or unavailable queries on exact scan. A filter restricts
result admission, not graph traversal; bounded widening may gather more eligible
candidates before exact filtered fallback. Every public result is reranked
against authoritative F32 vectors.

The mutable graph uses append-only packed slots. Replacement and deletion mark
old slots non-current, so they remain safe traversal bridges but cannot be
returned. Manifest v3 commits a versioned CRC32
`hnsw-<sequence>.bin` sidecar. Reopen validates identity, all section bounds,
checksum, and graph structure before exposing it as an immutable mmap base;
mapping acquisition failure may use the same validated owned decoder. Newer WAL
mutations replay into a bounded owned delta and queries merge base/delta
candidates through the current ID-to-source mapping. `flush()` rebuilds when
inactive slots or delta mutations cross their configured limits, while
`rebuild_hnsw()` provides explicit maintenance. Queries never rebuild.
Missing/stale derived state rebuilds from authoritative records; corruption of a
matching committed sidecar fails recovery. Legacy `hnsw.cache` is read only for
pre-v3 manifests and is never preferred over a manifest-referenced sidecar.

Sparse vectors are a companion durable state keyed by the same point IDs. A
checksummed sparse WAL shares the collection sequence space. Every v2/v3
manifest descriptor pairs its dense base/delta with a sparse base/delta.
Both are fsynced before manifest publication. Open replays paired descriptors
in sequence order, then newer sparse WAL records, and removes sparse records
whose dense point is not live.
The in-memory inverted index accumulates only query posting lists. Hybrid search
runs dense and sparse retrieval independently and fuses ranks with RRF; raw
scores from the two modalities are never compared.

## Implemented storage boundary

`PersistentCollection` is an embedded, single-writer engine. Opening a
collection obtains a non-blocking exclusive advisory lock on the stable
`collection.lock` file before recovery; `close()` releases it deterministically
and RAII releases it if the owner is dropped. WAL, MemTable,
segment, manifest, CRC32, and the filesystem durability boundary are all Mojo
modules under `src/akasha/storage` and `src/akasha/api`. Recovery accepts only an
incomplete final WAL record; it truncates that tail before another append.
Complete checksum corruption fails open.

WAL writers emit version 2 records and incremental segment writers emit version
3 base/delta records that store vectors and encoded payloads as one checksummed
unit. Readers also accept Phase 3 Segment v1/v2 vector-only or snapshot records;
a later flush upgrades them into the current generation model. Payloads are
flat ordered fields with unique,
non-empty names. Supported values are String, Int64, finite Float64, and Bool,
with a maximum of 1,024 fields and 16 MiB encoded payload per document.

The first checkpoint publishes paired dense/sparse base segments; later flushes
append only the latest changed states as paired L0 deltas. Recovery validates
and applies descriptors in manifest order, then ignores WAL sequence numbers
already covered by the committed generation. Four L0 generations trigger a
bounded engine-owned maintenance request. A small portable pthread shim invokes
a Mojo callback; the callback acquires the same writer lock, reconstructs only
manifest-committed dense and sparse state, and atomically publishes one L1
base. It never modifies or rotates a newer WAL. At most one callback waits
behind the active callback. Failure is stored and surfaced by the next public
data operation, explicit wait, later scheduling, or close. If the shared
library cannot load, flush uses the same synchronous compaction path.

`PersistentCollection.snapshot()` captures owned MemTable, metadata, and
sparse index state at one accepted sequence. Exact, Boolean-filtered, sparse,
hybrid, batch, `get`, and payload results remain stable after live mutations.
Snapshots pin their manifest generation. Both foreground and background
compaction publish before retiring files and reclaim only after the final
relevant pin closes. Collection writers are serialized; snapshot reads require
no writer lock after capture.

Batch mutation uses one WAL v3 envelope and one fsync for a prevalidated
contiguous sequence range. Live state changes only after append succeeds.
Batch queries capture one snapshot, then use the public scoped MAX worker pool
with one deterministic Top-K heap and output ordinal per query. No private Mojo
async API is used.

Phase 12 single-query parallel scan splits stable snapshot ordinals into fixed
contiguous ranges, scores one bounded local heap per range, then merges ranges
in ordinal order. SQ8 stores one affine byte per dimension. Product
quantization stores one centroid byte per configured subvector. Both preserve
the scalar/SIMD implementation as the correctness oracle and optionally exact
rerank an expanded candidate set against owned Float32 vectors.

Phase 13 device batch execution flattens owned snapshot vectors and queries,
then launches one Mojo GPU scoring thread per query/candidate pair. A second
kernel assigns one query per thread and emits deterministic metric-aware Top-K
with ascending-ID ties and no kernel heap allocation. The host planner accounts
for work size, transfer bytes, configured budget, and live device free memory.
Disabled or absent hardware, small work, budget rejection, allocation/launch
failure, and injected failures all use the existing exact SIMD batch executor.
Filtered device batches materialize indexed candidates before device scoring.

## HNSW identity, storage, and operations

`collection.bin` is immutable collection identity: dimension, ANN metric,
scalar kind, M, M0, `ef_construction`, default/maximum `ef_search`, maximum
level, rebuild thresholds, and level seed. The legacy
`PersistentCollection.open(path, dimension)` creates L2/F32 defaults;
`open_with_config` creates or validates an exact identity. Approximate requests
for another metric preserve API semantics through exact fallback rather than
searching incompatible graph geometry.

F32, BF16, and F16 graph vectors support dot, squared L2, and cosine. I8
supports dot and cosine; I8/L2 is rejected. Compact values guide traversal, but
the MemTable/segments retain authoritative F32 and rerank candidates before
return. The portable SIMD backend is bound once per graph for one metric/scalar
pair and reported with actual backend, metric, scalar, and storage labels. No
runtime multi-ISA claim is made; see
[`ADR 0005`](adr/0005-distance-dispatch.md).

The immutable sidecar is demand-paged when mapped. Its vector section costs
four bytes per dimension for F32, two for BF16/F16, or one for I8 plus an F32
scale per dot vector. IDs, slot flags/levels, section offsets, and bounded
neighbor cells add graph overhead proportional to M0/M. Authoritative F32
storage exists separately. The owned delta consumes heap memory until rebuild.
A flush that crosses rebuild policy can pay full graph construction plus a new
sidecar write; crash ordering keeps the previous manifest generation usable
until the new data files and sidecar are durable and the new manifest publishes.
Reader generation pins may delay old-file reclamation.

Current durable contracts are
[`collection.bin`](formats/collection-config-format.md),
[`manifest.bin`](../formats/manifest-format.md),
[`segments`](../formats/segment-format.md), and
[`WAL`](../formats/wal-format.md). Readers preserve documented older versions.
Writers publish collection config v1 and Segment v3; a checkpoint with an HNSW
sidecar uses Manifest v3, while a sidecar-ineligible checkpoint remains a valid
Manifest v2. Single WAL mutations use v2 records and atomic batches use v3
envelopes. The HNSW sidecar v2 layout and v1 sidecar compatibility are specified
in the production HNSW design and locked by checked-in fixtures.

Phase 4.2 evaluates strict typed conditions before SIMD scoring. Phase 4.3
composes them as bounded All/Any/Negate expressions stored in a flat node arena
to keep Mojo ownership explicit. Phase 9 evaluates those same expressions with
a derived `MetadataIndex`: stable MemTable slots are ordinals in dense 64-bit
candidate bitmaps, String/Bool values use sparse sorted postings, and
Int64/Float64 values use type-specific sorted blocks for equality and ranges.
This keeps high-cardinality metadata memory linear in indexed field entries.
Missing fields and type mismatches do not match, including inequality.

Document writes incrementally remove old postings and add new postings after
the authoritative WAL and MemTable mutation succeeds. Deletes clear the live
universe bit. Recovery may load a checksummed `metadata.cache`; otherwise it
bulk-loads and heap-sorts the complete derived index from stable MemTable slots
after Segment and WAL replay. WAL, Segment, and Manifest formats remain
unchanged. Exact filtered execution scans bitmap words
and scores only selected ordinals. Approximate
planning reads cached bitmap cardinality, and HNSW/sparse candidates use indexed
point-ID membership before exact fallback or fusion. Search still returns
lightweight IDs and scores, and `get` resolves the latest owned payload.

Phase 16 adds an authenticated multi-process reference cluster. Each replica
process owns independent Mojo WAL/segment/manifest state plus a checksummed
replicated journal. Versioned cluster metadata selects shard leaders and
placements. The coordinator performs quorum prepare/commit, failover, catch-up,
snapshot-plus-tail rebalancing, fan-out, and deterministic global Top-K/RRF.

## Implemented adapter boundary

`src/bindings/python_module.mojo` compiles to the `_kernel` CPython extension
with Mojo's `PythonModuleBuilder`. Its bound collection owns the real
`PersistentCollection`; Python performs only explicit value conversion and
exception mapping. `python/akashadb` adds typed dataclasses, a named local
registry, copying Arrow-compatible columns, and an owned Arrow C Data path.
FastAPI routes obtain that same registry from application state and contain no
scoring, filtering, or storage logic.

Boolean filter dictionaries are converted into bounded Mojo
`FilterExpression` values before exact, approximate, sparse, or hybrid search.
Dense batch calls accept one filter dictionary per query and retain input
ordinal order across parallel execution.
The compatibility Arrow adapter always copies Python/NumPy/PyArrow-compatible
sequences. The C Data path imports producer capsules into a one-shot consumer
lease, validates Arrow-owned buffer views, and keeps owners alive through the
synchronous compiled-kernel call. It creates no intermediate Python list;
accepted values are copied only at the engine ownership boundary into the
WAL/MemTable. Premature release and invalid schemas fail before mutation.

`src/bindings/c_api.mojo` is the lower-level native boundary described by
[`ADR 0006`](adr/0006-c-abi-capability.md). `include/akasha.h` exposes ABI v1
through an opaque Mojo-owned collection handle and fixed-width, versioned C
PODs. Hosts retain all path, vector, result, and error buffers; calls copy input
before return and report required result capacity without partial writes.
Every export initializes the Mojo runtime idempotently and translates errors to
status codes. Close takes a handle pointer, destroys ownership once, and nulls
the caller slot. The checked surface is configured open, upsert, delete, flush,
metric-bound ANN search, last-search stats, and close. It is linked and executed
by a standalone C11 test rather than inferred from symbol presence alone.
