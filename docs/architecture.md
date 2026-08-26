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

Phase 4.2 evaluates strict typed conditions against each live payload before
SIMD scoring. Phase 4.3 composes them as bounded All/Any/Negate expressions,
stored in a flat node arena to keep Mojo ownership explicit. Missing fields and
type mismatches do not match at the condition level. There is no metadata index
yet, so a filtered exact query scans live documents and performs linear field
lookup; WAL, Segment, and Manifest formats are unchanged. Search returns
lightweight IDs and scores, and `get` resolves the latest owned payload.
Metadata indexes, HNSW, hybrid search, Arrow interchange, GPU kernels, and
distributed execution remain explicit future work.
