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
dense/sparse segment. They compare format, sequence ranges, levels, and stored
checksums; corruption is an error, not a warning.

Online backup opens the collection, checkpoints accepted WAL state, pins the
committed manifest generation, verifies every referenced file, copies immutable
files, and publishes the destination manifest last. Restore repeats strict
validation and also publishes its target manifest last. The target must not
already contain a committed manifest, dense WAL, or sparse WAL. A WAL-only
collection is authoritative even without a manifest and is never overwritten
or merged by restore.

Logical export writes one owned point per NDJSON line, including vector, typed
payload fields, and sparse elements. Import parses and validates the complete
file before committing one dense batch. Sparse vectors are fully validated
before that commit and then appended to the sparse WAL.

## Repair policy

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
single-writer directory lock.
