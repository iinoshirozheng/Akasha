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
validate
   -> assign sequence
   -> append checksummed WAL record + fsync
   -> latest-state MemTable
   -> exact SIMD search

flush
   -> complete live snapshot segment + fsync
   -> atomic segment rename + directory fsync
   -> atomic manifest publish + directory fsync
```

## Initial read path

```text
manifest -> immutable snapshot -> newer WAL replay -> MemTable
                                                   |
query -> SIMD metric -> bounded Top-K <-------------+
```

## Implemented storage boundary

`PersistentCollection` is an embedded, single-writer engine. WAL, MemTable,
segment, manifest, CRC32, and the filesystem durability boundary are all Mojo
modules under `src/akasha/storage` and `src/akasha/api`. Recovery accepts only an
incomplete final WAL record; it truncates that tail before another append.
Complete checksum corruption fails open.

Segments are full live-state snapshots in Phase 3. WAL rotation, obsolete
segment cleanup, incremental segments, compaction, multi-process locking, and
snapshot-isolated concurrent readers remain future storage work.

Metadata filters, payload persistence, HNSW, hybrid search, Arrow interchange,
GPU kernels, and distributed execution remain explicit future work.
