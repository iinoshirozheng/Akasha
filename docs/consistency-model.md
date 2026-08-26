# Consistency model

Status: Phase 5 implemented.

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

Flush writes a complete live snapshot to a temporary segment, fsyncs it,
atomically renames it, and fsyncs the directory. It then performs the same
protocol for the manifest. The manifest rename is the snapshot commit point.
Only after that commit is durable does flush atomically replace the WAL with an
empty fsynced file and sync the directory. Finally it removes the segment named
by the previous valid manifest and syncs the directory again. Unrelated orphan
files are not deleted.

Open validates the manifest and segment, restores live records, and replays WAL
records newer than the snapshot sequence. A final incomplete WAL record is
treated as a torn write and durably removed before another append. Any complete
record with an invalid checksum or structural field fails recovery.

If a crash occurs after manifest publication but before WAL replacement,
recovery may see the new snapshot and the pre-checkpoint WAL. Records at or
before the manifest sequence are skipped, so each mutation is restored once.

## Current limits

- No long-lived snapshot reader API yet.
- No transactions spanning multiple mutations.
- No incremental/leveled compaction, replication, or distributed consistency.
