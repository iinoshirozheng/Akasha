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

## Write and checkpoint paths

```text
validate/stage complete point changes
   -> assign a contiguous accepted sequence range
   -> append one combined point WAL v4 envelope + fsync
   -> publish immutable native vector/payload owners and current point descriptors
   -> exact native scoring or per-field derived retrieval + authoritative rerank

flush
   -> changed point records into temporary v4 base/delta files + fsync
   -> retain a valid default HNSW base or prepare a replacement sidecar
   -> atomic data-file renames + directory fsync
   -> atomic manifest generation publish + directory fsync
   -> atomic empty WAL replacement + directory fsync
   -> threshold signal coalesces into one background maintenance request
   -> worker pins inputs, builds outside writer, conditionally publishes a base
```

Collections opened without a field catalog retain their documented dense/sparse
WAL v2/v3 and paired Segment v3 paths. Opting into named fields (or an empty named
catalog) preflights all legacy sources, publishes catalog v2, and switches future
writes to combined point WAL/Segment v4. Old sources remain readable across the
cutover; migration never reinterprets legacy F32 bytes as another scalar type.

## Read path

```text
manifest -> ordered versioned base+deltas -> newer WAL replay -> MemTable
                                                               |
query -> immutable read root -> field presence + typed filter -> scoring -> Top-K
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
against authoritative F32 vectors for default dense queries. Native named fields
rerank their own F32/F16/BF16/I8/U8 buffers with Float64 accumulation and scores.

The mutable graph uses append-only packed slots. Replacement and deletion mark
old slots non-current, so they remain safe traversal bridges but cannot be
returned. Manifest v4 commits a job-unique, versioned CRC32 HNSW sidecar;
legacy v3 descriptors retain their `hnsw-<sequence>.bin` naming contract. Manifest
v5 can retain a base captured at an earlier sequence, with later complete point
states recovered into its bounded overlay. Advancing a v3 checkpoint copies its
verified base to a unique v5 filename before publishing, without rebuilding it.
Reopen validates identity, all section bounds,
checksum, and graph structure before exposing it as an immutable mmap base;
mapping acquisition failure may use the same validated owned decoder. Newer WAL
mutations replay into a bounded owned delta and queries merge base/delta
candidates through the current ID-to-source mapping. `flush()` rebuilds when
inactive slots or delta mutations cross their configured limits, while
`rebuild_hnsw()` provides explicit maintenance. Default dense queries never rebuild.
Missing/stale derived state rebuilds from authoritative records; corruption of a
matching committed sidecar fails recovery. Legacy `hnsw.cache` is read only for
pre-v3 manifests and is never preferred over a manifest-referenced sidecar.

In the legacy collection format, sparse vectors are a companion durable state
keyed by the same point IDs. A
checksummed sparse WAL shares the collection sequence space. Every v2/v3/v4
manifest descriptor pairs its dense base/delta with a sparse base/delta.
Both are fsynced before manifest publication. Open replays paired descriptors
in sequence order, then merges newer dense and sparse WAL mutations by sequence.
Dense deletes remove sparse state before a later reinsert can inherit it. Recovery
also removes sparse records whose final dense point is not live.
The in-memory inverted index accumulates only query posting lists. Hybrid search
runs dense and sparse retrieval independently and fuses ranks with RRF; raw
scores from the two modalities are never compared.

In point mode, all named/default vectors and payload changes share one WAL commit
and visibility boundary. A point may lack the default dense field and still exist
in named search/scans. Point sequence covers every mutation; document sequence
covers only the default dense/payload projection. Present empty sparse vectors,
empty multivectors, absent fields, and zero-valued vectors remain distinct.

Each named HNSW or sparse index is an immutable-root artifact keyed by field ID.
The first request builds outside the collection writer lock; a complete artifact
is shared by sibling snapshots, and failed/cancelled builds publish nothing.
HNSW protects mutable query scratch with its own lock. Named graph artifacts have
no persistent sidecars yet and rebuild on a new root's first approximate request.
Native binary Hamming/Jaccard and ragged MaxSim use exact kernels; sparse postings
use F64 sums and include present zero-score rows. Multi-field RRF executes all
branches against one captured root and combines Float64 rank contributions.

## Implemented storage boundary

`PersistentCollection` is an embedded, single-writer engine. Opening a
collection obtains a non-blocking exclusive advisory lock on the stable
`collection.lock` file before recovery; `close()` releases it deterministically
and RAII releases it if the owner is dropped. WAL, MemTable,
segment, manifest, CRC32, and the filesystem durability boundary are all Mojo
modules under `src/akasha/storage` and `src/akasha/api`. Recovery accepts only an
incomplete final WAL record; it truncates that tail before another append.
Complete checksum corruption fails open.

Dense-WAL recovery borrows encoded spans from a 64 KiB read-ahead buffer that can
grow to one complete validated envelope. It transfers decoded vector/payload
allocations into the MemTable without retaining the complete dense history. A
matching committed HNSW sidecar replays a second bounded pass under the collection
lock. The owned replay API still returns the complete owned mutation list; sparse
WAL and segment decoding have separate memory costs. All authoritative sources
and matching sidecars pass preflight before identity publication or tail repair.
Repair truncates the existing descriptor to the accepted length and fsyncs it,
preserving the accepted prefix. See the [recovery measurement](benchmarks/2026-10-01-borrowed-wal.md).

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
a Mojo callback; the callback pins the committed manifest under the same writer
lock, merges its dense and sparse segments without the lock, and atomically
publishes one L1 base under a short lock, keeping segments flushed during the
merge after it. A flush that finds eight L0 segments (`LEVEL_ZERO_SEGMENT_LIMIT`)
waits without the lock until the worker publishes, so a writer that flushes faster
than the merge cannot grow L0 without bound. The callback never modifies or rotates
a newer WAL. At most one callback waits
behind the active callback. Failure is stored and surfaced by the next public
data operation, explicit wait, later scheduling, or close. If the shared
library cannot load, flush uses the same synchronous compaction path.

`PersistentCollection.snapshot()` shares an immutable base/sealed-run chain and
captures bounded head descriptors at one accepted sequence. Repeated unchanged
captures share a root; native vector and payload owners are retained rather than
deep-copied. Exact, Boolean-filtered, sparse,
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
rerank an expanded candidate set against authoritative Float32 vectors. SQ8 and
PQ builds are cached per immutable root/configuration and shared across snapshots;
queries do not retrain an already-ready artifact.

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
A small delta can use bounded exact candidate scoring alongside base HNSW when
its physical history, vector component count and initial search breadth fit the measured
limits. Both paths preserve current-source filtering and authoritative rerank;
the combined result remains approximate. Execution stats identify delta scans.

After a durable checkpoint, an optional `hnsw-overlay.cache` retains the mutable
graph, including inactive slots. Recovery verifies its envelope, retained-base
identity, graph structure and exact current-vector coverage before adoption.
Missing or invalid cache data is rebuilt from authority. This avoids replaying
graph insertion after small updates at the cost of additional flush work. F32
owned decoding and mapped validation use bounded bulk reads; checksums and
prepared-vector validation remain mandatory. See the
[cache format](formats/hnsw-format.md) and measured
[reopen tradeoff](benchmarks/2026-10-02-hnsw-overlay-cache.md).

A flush that crosses rebuild policy can pay full graph construction plus a new
sidecar write; crash ordering keeps the previous manifest generation usable
until the new data files and sidecar are durable and the new manifest publishes.
Reader generation pins may delay old-file reclamation.

Current durable contracts are
[`collection.bin`](formats/collection-config-format.md),
[`manifest.bin`](../formats/manifest-format.md),
[`segments`](../formats/segment-format.md), and
[`WAL`](../formats/wal-format.md). Readers preserve documented older versions.
Legacy writers retain collection config v1, Segment v3, single WAL v2 and atomic
batch WAL v3. Point-mode writers publish catalog v2 and WAL/Segment v4. HNSW
checkpoints use manifest v4 for a complete current base, or v5 for a retained
earlier base with recoverable overlay; a checkpoint without a sidecar remains
valid manifest v2. Readers retain the documented older formats. HNSW sidecar v2
layout and v1 compatibility are locked by checked-in fixtures. See also the
[field catalog](formats/field-catalog-format.md),
[point records](formats/point-record-format.md), and
[field envelopes](formats/field-envelopes-format.md).

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
bulk-loads and stable-sorts the complete derived index from stable MemTable slots
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
