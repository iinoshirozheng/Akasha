# Phase 11: Snapshots, Concurrency, and Batch Design

## Scope

Phase 11 adds stable read views, generation-safe reclamation, atomic batch
mutation, deterministic batch query execution, and bounded maintenance
scheduling. The ordered WAL pipeline remains the only authoritative mutation
path. Segment, index, and batch workers are derived execution machinery and
cannot bypass WAL durability or deterministic Top-K ordering.

## Immutable snapshot model

`PersistentCollection.snapshot()` captures the accepted collection sequence,
the committed manifest generation, and owned immutable copies of the MemTable,
metadata index, and sparse index. Query methods on the snapshot never consult
the live collection, so a later replace, delete, flush, or compaction cannot
change its results or payloads.

The initial owned representation makes the data lifetime independent of segment
files. A shared generation-pin registry still records the manifest generation
for reclamation accounting. Compaction may publish a new manifest while readers
are active, but it moves removed files into a retired-generation set. Those
files are reclaimed only after the last pin is released. Snapshot `close()` is
idempotent and RAII releases a forgotten pin.

## Mutation concurrency and batch atomicity

One collection core serializes writers through a lock around sequence
allocation, WAL append, MemTable/index mutation, and maintenance publication.
Read snapshots do not acquire that writer lock after capture.

An atomic mutation batch is encoded as one checksummed WAL v3 envelope. The
envelope contains a contiguous sequence range and individually bounded
upsert/delete document bodies. Validation and encoding complete before append;
one append+fsync makes the batch durable, and only then are all mutations
applied to live state. Recovery either accepts the complete envelope or repairs
an incomplete final envelope, so no prefix of a torn batch becomes visible.

## Batch query execution

Batch queries first validate all requests against one snapshot. Work is divided
into deterministic ordinal ranges and dispatched through Mojo's scoped runtime
worker pool. Each query owns its local bounded Top-K state. Results are written
to their input ordinal and retain the same score ordering and ascending point-ID
tie break as a single query. The sequential path remains available for small
batches and as a correctness oracle.

## Maintenance lifecycle

Foreground `compact()` and `maintenance()` remain the deterministic source of
truth. The engine-owned scheduler has bounded pending work, records the first
failure for the next public operation, and joins during close. It cannot reclaim
a pinned generation. Because Mojo's general async surface is unfinished, the
implementation must use only a compiling stable-runtime primitive or an
explicit native-thread shim with shared ownership and locking; private async
runtime APIs are not an accepted dependency.

## Validation

- A snapshot preserves exact, filtered, sparse, hybrid, and `get` results after
  live replace/delete/flush/compaction operations.
- Snapshot payload/vector ownership is independent from caller and live state.
- Compaction retains pinned files and reclaims them after the final unpin.
- Batch validation failure consumes no sequence and appends no WAL bytes.
- Crash recovery exposes either every mutation in a batch or none of them.
- Batch results equal sequential single-query results for all metrics and ties.
- Concurrent stress tests preserve monotonic sequences and deterministic reads.
- Close joins maintenance and surfaces worker failures deterministically.

