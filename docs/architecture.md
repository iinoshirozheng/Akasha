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
   -> changed dense/sparse records into paired base-or-delta segments + fsync
   -> atomic segment renames + directory fsync
   -> atomic Manifest v2 generation publish + directory fsync
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

Approximate dense queries use a derived HNSW graph. Point IDs produce
deterministic bounded levels; insertion connects bounded nearest neighbors,
then search performs greedy upper-layer descent and best-first layer-zero
expansion. The planner keeps small or selective queries on exact scan. Filtered
HNSW search over-fetches, evaluates the Boolean expression, retains exact metric
scores, and falls back to exact filtered scan when the graph candidates cannot
fill `k`. Recovered WAL/segment state remains authoritative. A versioned CRC32
`hnsw.cache` stores graph bytes only as a rebuildable acceleration artifact;
generation, sequence, source fingerprint, payload structure, or checksum
mismatch becomes a cache miss.

Sparse vectors are a companion durable state keyed by the same point IDs. A
checksummed sparse WAL shares the collection sequence space, and every
Manifest v2 descriptor pairs its dense base/delta with a sparse base/delta.
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

Trusted zero-copy Arrow C Data interchange, operations tooling, and distributed
execution remain explicit Phase 14–16 work.

## Implemented adapter boundary

`src/bindings/python_module.mojo` compiles to the `_kernel` CPython extension
with Mojo's `PythonModuleBuilder`. Its bound collection owns the real
`PersistentCollection`; Python performs only explicit value conversion and
exception mapping. `python/akashadb` adds typed dataclasses, a named local
registry, and copying Arrow-compatible columns. FastAPI routes obtain that same
registry from application state and contain no scoring, filtering, or storage
logic.

Boolean filter dictionaries are converted into bounded Mojo
`FilterExpression` values before exact, approximate, sparse, or hybrid search.
Dense batch calls accept one filter dictionary per query and retain input
ordinal order across parallel execution.
The current Arrow adapter always copies Python/NumPy/PyArrow-compatible
sequences. A zero-copy C Data bridge remains disabled until its ownership ABI
can be expressed and tested safely.
