# Consistency model

Status: Phase 3 implemented.

## Mutation visibility and durability

Akasha currently requires one `PersistentCollection` writer per collection;
this is an API contract, not yet an inter-process lock. Each accepted mutation
receives a strictly increasing sequence number. The call returns only after its
checksummed WAL record has been fully written and `fsync` has succeeded. It is
then applied to the in-process MemTable and immediately visible to searches on
that handle.

## Flush and recovery

Flush writes a complete live snapshot to a temporary segment, fsyncs it,
atomically renames it, and fsyncs the directory. It then performs the same
protocol for the manifest. The manifest rename is the snapshot commit point.

Open validates the manifest and segment, restores live records, and replays WAL
records newer than the snapshot sequence. A final incomplete WAL record is
treated as a torn write and durably removed before another append. Any complete
record with an invalid checksum or structural field fails recovery.

The WAL is retained after flush in Phase 3. Records at or before the manifest
sequence are skipped during replay.

## Current limits

- No concurrent-writer or multi-process lock enforcement.
- No long-lived snapshot reader API yet.
- No transactions spanning multiple mutations.
- No WAL rotation, segment garbage collection, replication, or distributed
  consistency.
