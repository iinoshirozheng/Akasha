# Persistent Vector Storage Design

## Goal

Phase 3 turns Akasha's exact in-memory vector search into a durable,
single-writer collection implemented in Mojo. The collection must survive a
clean reopen and the crash boundaries that can be tested without introducing
an external database or serialization runtime.

## Scope

The public entry point is `PersistentCollection.open(path, dimension)`. It
supports `upsert`, `delete`, exact dot/L2/cosine search, `flush`, and reopen.
Point IDs are signed 64-bit integers at rest and vectors are `Float32`.

Payloads, document chunks, image URIs, metadata filters, WAL rotation,
compaction, multi-process locking, and concurrent writers remain out of scope.

## Write and recovery model

Akasha uses one writer and assigns each mutation a monotonically increasing
64-bit sequence number.

1. Validate the operation and vector.
2. Assign the next sequence number.
3. Append a checksummed binary record to `wal.bin` and `fsync` it.
4. Apply the mutation to the MemTable.

On open, Akasha loads the manifest and its referenced immutable snapshot
segment, then replays valid WAL records whose sequence is newer than the
snapshot sequence. A final incomplete WAL record is treated as a torn tail and
ignored. A complete record with a bad checksum is corruption and fails open.

## In-memory state and search

The MemTable owns only the newest state for each point ID: sequence, tombstone
flag, and vector. Search scans live entries once, computes the existing SIMD
metric, and feeds the existing deterministic bounded Top-K heap. Upserts replace
the previous value and tombstones exclude deleted IDs immediately.

## Flush protocol

`flush()` publishes a complete snapshot of current live state:

1. Encode the snapshot into a uniquely sequenced `segment-<seq>.bin.tmp`.
2. Write all bytes, `fsync` the file, close it, and atomically rename it.
3. Encode a manifest referencing the new segment into `manifest.bin.tmp`.
4. Write, `fsync`, close, and atomically rename the manifest.
5. `fsync` the collection directory after each rename.

The manifest is the commit point. An orphan segment is safe because recovery
only opens the segment named by a valid manifest. Phase 3 deliberately retains
the WAL; replay skips records at or before the manifest sequence.

## Filesystem boundary

All platform interaction is isolated in `akasha.storage.filesystem`. Mojo's
public file APIs provide binary reads/writes and expose the Unix descriptor;
the boundary uses a small POSIX `fsync` call because Mojo 1.0 has no public
sync method. Directory creation, existence checks, and rename remain behind the
same boundary so the storage formats and collection logic are platform-neutral.

## Corruption policy

- Missing collection files mean a new empty collection.
- An incomplete record only at the WAL EOF is ignored.
- Bad WAL magic, invalid lengths, invalid operations, dimension mismatch,
  sequence regression, or checksum mismatch fails open.
- A malformed or checksummed-invalid manifest/segment fails open.
- A manifest referencing a missing segment fails open.
- Opening an existing collection with a different dimension fails.

## Versioning

Every persisted format has a four-byte magic and a version field. Decoders
reject unknown versions. Integers and IEEE-754 `Float32` bit patterns are
little-endian. Checksums use CRC-32/ISO-HDLC (polynomial `0xEDB88320`).

