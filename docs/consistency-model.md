# Consistency model

Status: Phase 12 single-node durability, snapshots, concurrency, quantized
execution, and rebuildable derived-cache model implemented.

## Mutation visibility and durability

Akasha enforces one live `PersistentCollection` writer per collection directory
with a non-blocking advisory lock on `collection.lock`. A second open fails
while the owner is live. `close()` is idempotent, releases the lock
deterministically, and makes subsequent data operations fail; dropping the
owner or exiting the process also releases the operating-system lock.

Each accepted mutation receives a strictly increasing sequence number. The call
returns only after its checksummed WAL record has been fully written and `fsync`
has succeeded. It is then applied to the in-process MemTable and immediately
visible to searches on that handle.

`apply_batch` validates every upsert/delete before allocating one contiguous
sequence range. It appends and fsyncs one checksummed WAL v3 envelope before
swapping the staged MemTable and derived indexes into live state. Recovery
accepts a complete envelope or repairs an incomplete final envelope as a unit;
it never exposes a durable prefix.

Mutable collection operations are serialized by one engine-owned writer lock.
`snapshot()` takes that lock only while capturing an owned view. Later exact,
filtered, sparse, hybrid, batch, and `get` calls on the snapshot consult no live
collection state. A concurrent snapshot sees either the state before an atomic
batch or the state after it, never a prefix.

## Flush and recovery

The first flush writes a complete base; later flushes write only the latest
dense and sparse states newer than the committed checkpoint as paired L0 delta
segments. Each temporary segment is fsynced, atomically renamed, and followed
by a directory fsync before the new Manifest v2 generation is published. The
manifest rename is the checkpoint commit point. Only after that commit is
durable does flush atomically replace the dense and sparse WALs with empty
fsynced files and sync the directory.

When four L0 generations accumulate, flush coalesces a request into one bounded
background slot. The worker acquires the writer lock, merges only the
generation named by the manifest, writes paired bases, and publishes a new
generation. A WAL accepted after that manifest remains untouched and is
replayed above the compacted checkpoint. `wait_for_maintenance()` drains the
queue; `close()` drains and joins it before releasing the collection lock. The
first worker error is surfaced deterministically. If the portable native worker
cannot load, threshold compaction runs synchronously. Explicit `compact()` and
`maintenance()` remain synchronous.

Every read snapshot pins its captured manifest generation. Obsolete files are
queued rather than deleted while any relevant pin remains. Reclamation happens
only after publication and the final unpin; unrelated orphan files are never
silently removed.

Open validates every ordered manifest descriptor and its dense/sparse checksum
and sequence interval, applies base and delta records in manifest order, and
then replays WAL records newer than the checkpoint sequence. A final incomplete
WAL record is treated as a torn write and durably removed before another append.
Any complete record with an invalid checksum or structural field fails
recovery. Legacy Manifest v1 and Segment v1/v2 collections remain readable and
upgrade on their next flush.

HNSW and metadata cache files are outside the acknowledgement and recovery
boundary. They are atomically published and keyed by manifest generation,
accepted sequence, dimension, and a checksum of authoritative dense vectors,
tombstones, sequences, and payloads. Missing, stale, truncated, structurally
invalid, or CRC-corrupt cache files are cache misses: open or the next
approximate query rebuilds them from recovered state. Cache publication failure
is ignored and cannot fail an otherwise valid query or acknowledged write.

Quantized and parallel execution run only over owned read-snapshot state. SQ8
and PQ may change candidate recall and approximate scores, but exact rerank uses
the same Float32 SIMD metric oracle. Parallel range scheduling cannot change
visible snapshot state or deterministic tie order.

GPU execution also consumes only owned snapshot state. The planner and device
allocation happen after snapshot capture; any device rejection or runtime
failure recomputes the whole batch through the exact CPU executor. There is no
partially device-produced result, mutation, or durability side effect.

If a crash occurs after manifest publication but before WAL replacement,
recovery may see the new snapshot and the pre-checkpoint WAL. Records at or
before the manifest sequence are skipped, so each mutation is restored once.
The same rule applies independently to retained pre-checkpoint sparse WAL
records.

## Current limits

- Atomicity is collection-local; there are no cross-collection transactions.
- Live approximate queries are mutable collection operations; callers needing a
  stable long read use the immutable exact/sparse/hybrid snapshot APIs.
- There is no replication or distributed consistency yet.
