# Phase 15: Operations and Recovery Tooling

**Goal:** Make a live single-node Akasha collection inspectable, backupable,
restorable, bounded, cancellable, and safely shut down without weakening the
manifest/WAL consistency model.

## Architecture

Consistency-sensitive operations live in Mojo. `PersistentCollection.backup_to`
flushes a checkpoint under the writer lock, pins the committed manifest
generation, validates every referenced dense/sparse checksum, copies immutable
files, and publishes the backup manifest last. The pin is released on success or
failure. Restore validates the entire source and only publishes a target
manifest after every referenced file is durable.

An offline inspector reports format version, dimension, generation, accepted
sequence, segment ranges, checksums, and point counts. Checksum scan decodes all
referenced files strictly. Orphan discovery is manifest-driven. Quarantine may
move only known Akasha artifacts that are not referenced by the committed
manifest; it never edits referenced data or invents a replacement.

Logical NDJSON export/import is an adapter over owned Mojo snapshot records.
Import parses and validates every row before one dense mutation batch is
committed. Sparse rows are validated before the dense commit and then appended
through the existing sparse WAL.

`QueryControl` carries bounded `max_candidates`, deadline, and cancellation
state. Controlled exact scans check it at deterministic intervals. Python and
HTTP additionally cap request batch size and `k`. Metrics count accepted writes,
queries, failures, cancellations, and latency; trace records contain operation,
duration, status, and accepted sequence but never vectors or payload content.

Graceful shutdown stops accepting HTTP work, cancels outstanding request tokens,
drains maintenance, closes every collection, and then releases directory locks.

## TDD sequence

1. Add failing Mojo tests for strict inspection, backup/restore parity,
   corruption rejection, manifest-last publication, and pin release on failure.
2. Implement storage operation reports and generation-pinned backup/restore.
3. Add failing tests for control limits, pre-cancel, deadline, and deterministic
   controlled-search parity; implement `QueryControl`.
4. Add Python tests for NDJSON export/import, orphan quarantine allow-list,
   metrics/traces, resource limits, and graceful FastAPI shutdown.
5. Implement the typed Python operations API and `akashadb-admin` CLI.
6. Document commands, recovery safety, observability schema, and limitations.
7. Run focused tests, full Mojo/Python/crash suites, release builds, smoke, and
   clean-diff validation.

## Completion gates

- Restored dense, sparse, payload, filter, and query results equal the backup
  generation.
- Any manifest/segment/sparse checksum failure aborts backup/restore without
  publishing a target manifest.
- Quarantine never moves a manifest-referenced file.
- Invalid import mutates no sequence or live point.
- Cancelled/deadline/resource-limited queries fail predictably; uncontrolled
  APIs remain compatible.
- Metrics/traces avoid vector and payload data; shutdown releases all locks.
