# Consistency model

Status: Phase 10 incremental storage core implemented.

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

## Flush and recovery

The first flush writes a complete base; later flushes write only the latest
dense and sparse states newer than the committed checkpoint as paired L0 delta
segments. Each temporary segment is fsynced, atomically renamed, and followed
by a directory fsync before the new Manifest v2 generation is published. The
manifest rename is the checkpoint commit point. Only after that commit is
durable does flush atomically replace the dense and sparse WALs with empty
fsynced files and sync the directory.

When four L0 generations accumulate, the same foreground maintenance boundary
performs full-coverage compaction. It flushes pending mutations, writes paired
base segments from authoritative live state, publishes a generation containing
only that base, then removes exactly the old files no longer referenced by the
committed manifest. Covered tombstones are discarded; unrelated orphan files
are not deleted. `compact()` and `maintenance()` expose the same deterministic
synchronous path.

Open validates every ordered manifest descriptor and its dense/sparse checksum
and sequence interval, applies base and delta records in manifest order, and
then replays WAL records newer than the checkpoint sequence. A final incomplete
WAL record is treated as a torn write and durably removed before another append.
Any complete record with an invalid checksum or structural field fails
recovery. Legacy Manifest v1 and Segment v1/v2 collections remain readable and
upgrade on their next flush.

If a crash occurs after manifest publication but before WAL replacement,
recovery may see the new snapshot and the pre-checkpoint WAL. Records at or
before the manifest sequence are skipped, so each mutation is restored once.
The same rule applies independently to retained pre-checkpoint sparse WAL
records.

## Current limits

- No long-lived snapshot reader API yet.
- No transactions spanning multiple mutations.
- No engine-owned background maintenance worker yet; threshold compaction runs
  synchronously at the end of `flush()`.
- No replication or distributed consistency yet.
