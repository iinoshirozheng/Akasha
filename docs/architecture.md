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
   -> complete live vector-plus-payload segment v2 + fsync
   -> atomic segment rename + directory fsync
   -> atomic manifest publish + directory fsync
   -> atomic empty WAL replacement + directory fsync
   -> previous manifest segment removal + directory fsync
```

## Initial read path

```text
manifest -> v1/v2 snapshot -> newer v1/v2 WAL replay -> MemTable
                                                         |
query -> typed AND filter -> SIMD metric -> bounded Top-K IDs
                                                         |
                              get(ID) -> owned document <-+
```

Approximate dense queries use a derived in-memory HNSW graph. Point IDs produce
deterministic bounded levels; insertion connects bounded nearest neighbors,
then search performs greedy upper-layer descent and best-first layer-zero
expansion. The planner keeps small or selective queries on exact scan. Filtered
HNSW search over-fetches, evaluates the Boolean expression, retains exact metric
scores, and falls back to exact filtered scan when the graph candidates cannot
fill `k`. Recovered WAL/segment state remains authoritative; no graph bytes are
stored in the durable formats.

Sparse vectors are a companion durable state keyed by the same point IDs. A
checksummed sparse WAL shares the collection sequence space, and a complete
`sparse-<sequence>.bin` sidecar is fsynced before manifest publication. Open
requires a present sidecar's sequence to equal the manifest, replays newer
sparse WAL records, and removes sparse records whose dense point is not live.
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

WAL and segment writers emit version 2 records that store the vector and its
encoded payload as one checksummed unit. Readers also accept Phase 3 version 1
vector-only records and expose them with an empty field list; a later flush
publishes a version 2 snapshot. Payloads are flat ordered fields with unique,
non-empty names. Supported values are String, Int64, finite Float64, and Bool,
with a maximum of 1,024 fields and 16 MiB encoded payload per document.

Segments are full live-state snapshots. A flush is an ordered checkpoint: it
publishes the new segment and manifest, atomically replaces the WAL with an
empty durable file, then removes only the segment named by the previous valid
manifest. Recovery remains safe if a crash retains the old WAL after the new
manifest because replay ignores sequence numbers already covered by the
snapshot. Incremental segments, leveled compaction, and snapshot-isolated
concurrent readers remain future storage work.

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
universe bit. Recovery bulk-loads and heap-sorts the complete derived index from
stable MemTable slots after Segment and WAL replay, so WAL, Segment, and
Manifest formats remain unchanged. Exact filtered execution scans bitmap words
and scores only selected ordinals. Approximate
planning reads cached bitmap cardinality, and HNSW/sparse candidates use indexed
point-ID membership before exact fallback or fusion. Search still returns
lightweight IDs and scores, and `get` resolves the latest owned payload.

Incremental compaction, trusted zero-copy Arrow C Data interchange, GPU kernels,
and distributed execution remain explicit future work.

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
The current Arrow adapter always copies Python/NumPy/PyArrow-compatible
sequences. A zero-copy C Data bridge remains disabled until its ownership ABI
can be expressed and tested safely.
