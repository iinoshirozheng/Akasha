# Operations and recovery

Build the Mojo extension before using the admin CLI:

```bash
pixi run build-python
PYTHONPATH=python:. python -m akashadb.admin inspect ./data/demo 384
```

## Commands

```text
akashadb-admin inspect PATH DIMENSION
akashadb-admin scan PATH DIMENSION
akashadb-admin backup PATH DIMENSION TARGET
akashadb-admin restore BACKUP DIMENSION TARGET
akashadb-admin export PATH DIMENSION TARGET.ndjson
akashadb-admin import PATH DIMENSION SOURCE.ndjson
akashadb-admin quarantine-orphans PATH DIMENSION QUARANTINE
```

`inspect` and `scan` strictly decode the committed manifest and every referenced
dense/sparse segment and HNSW sidecar. They compare format, sequence ranges,
levels, stored checksums and graph identity; a missing or corrupt referenced
sidecar is an inspection/restore error even though collection recovery can
rebuild missing derived state.

Online backup checkpoints accepted WAL state, then captures and pins that
committed manifest generation under the writer lock. It copies only the captured
files after releasing the lock, so writes, flushes and compactions continue. Each
file streams through a 1 MiB buffer into a temporary name, is checked against its
manifest checksum, fsynced and renamed; the destination manifest is published last.
The backup copies the captured HNSW sidecar when present, retaining its manifest
metadata and validating its checksum, sequence, config fingerprint and live count.
Closing the source collection rejects new operations but an acquired backup keeps
the source's advisory file lock until copying finishes. The writer mutex is free
during copying; a new collection owner must wait until the backup releases the
file lock. Restore strictly decodes the backup, then copies and publishes its
target manifest last. The target must not
already contain a committed manifest, dense WAL, or sparse WAL. A WAL-only
collection is authoritative even without a manifest and is never overwritten
or merged by restore. Backup and restore acquire the target's normal
single-writer lock before checking state and hold it through manifest
publication, so an open target or concurrent writer is rejected rather than
racing the commit point.

Logical export captures one immutable root. Field-aware collections write a
versioned NDJSON schema header and every live point, including named-only and
payload-only points, all native vector types, binary bytes and ragged matrices.
Absent vectors and present empty values remain distinct. The importer requires
the same default collection identity and named schema, validates the complete
input, then commits one atomic point batch. Imported IDs replace complete point
states; unrelated target IDs remain. Source sequences are provenance, while the
target allocates new sequences. See the [frozen logical format](formats/logical-point-format.md).

The CLI initializes a new/empty target directory from the header; an existing
collection must already have a compatible field-aware catalog. It does not migrate
an incompatible existing collection during import. Row resource limits apply,
and a valid empty field-aware export imports zero rows without a mutation.

Legacy collections retain their unversioned NDJSON document rows, including
default vector, payload and sparse elements. Their reader preserves the original
dense-batch commit followed by validated sparse WAL mutations. Field-aware exports
use the single atomic point commit described above. Both exporters atomically
replace the destination using a unique temporary file; publication failure
preserves the previous destination and cleans up that temporary file.

## Repair policy

On open, while holding the source writer lock, Akasha removes unreferenced
job-named HNSW and compaction outputs at any generation, including their temporary
files. It checks exact shared file leases before unlinking, preserving readers
from earlier collection instances or other processes. Unknown names and legacy
sequence-only HNSW files are not included in this automatic cleanup.

Snapshot roots keep their captured files leased after collection close. The last
lease release reclaims obsolete files without waiting for another flush. Cleanup
uses the original directory descriptor even if its path has been renamed or
replaced. Failed cleanup retains files; a live collection retries its retirement
queue, and reopen retries eligible job outputs. Each live generation retains one
file descriptor per referenced immutable file plus its directory descriptor.

`quarantine-orphans` is deliberately conservative. It derives the live set only
from the committed manifest and moves allow-listed unreferenced segment or
manifest-temporary artifacts into a recoverable quarantine directory. It never
moves WAL files, the committed manifest, referenced segments, arbitrary user
files, or attempts to synthesize missing data.

## Limits, cancellation, metrics, and tracing

Python `ResourceLimits` bounds mutation rows, query batch size, `k`, and exact
candidate scans. `CancellationToken` and `Collection.search_controlled` route to
Mojo `QueryControl`, which checks cancellation, a monotonic deadline, and the
candidate budget at deterministic scan intervals.

`Collection.metrics()` reports operation, accepted-write, query, failure,
cancellation, and aggregate-duration counters. `Collection.traces()` retains the
latest 256 operation name/duration/status/accepted-sequence records. Vectors,
queries, payloads, and filter values are never included. HTTP exposes aggregate
collection counters at `GET /metrics`.

FastAPI lifespan shutdown closes every open collection. Collection close rejects
new operations, drains and joins background maintenance, and releases the
collection's ownership of the single-writer directory lock. An already acquired
backup or foreground compaction retains that lock through completion; snapshots
keep their own read roots and exact immutable-file leases.
