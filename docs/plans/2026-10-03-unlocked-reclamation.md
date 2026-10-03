# Reclaim compaction inputs outside the writer lock

Continuation of M5/M6 from `92ba72f`. Production remains `a710aa5`; the four-row
distance candidate stays separate. No performance or completion claim yet.

## Measured problem and precedent

Mixed-query traces locate 0.5–1.1 ms waits at the writer lock. Successful
background compaction holds it for 486–965 µs. A further 36 successful jobs
attribute 256–618 µs to lease-aware old-file reclamation and directory sync,
versus 181–276 µs for manifest rebasing/publication. All trace data is frozen in
[the four-row report](../benchmarks/2026-10-03-four-distance.md); instrumented
timings do not replace the failed public trials.

The current `finish_compaction` publishes the manifest and then invokes
`RetiredFileQueue.retire_or_reclaim` before releasing the caller's writer lock.
The queue requires serialized mutation, while its open/flock/unlink/fsync I/O
already has exact immutable-file lease protection. These are distinct needs.

Local RocksDB `6dbb6f30e604e0047db29f06fe1c28c348074c98`,
`db/db_impl/db_impl_files.cc:853`, gathers obsolete files under its mutex and
unlocks before purging them. Apply that limited pattern to the existing Akasha
queue; add no dependency, alternate lock implementation or persistent format.

## Small end-to-end change

1. Give `RetiredFileQueue` explicit enqueue, detach and restore operations.
   Detach moves the pending list into an owned batch and leaves an empty queue.
   Existing synchronous `retire_or_reclaim` callers keep their behavior.
2. `finish_compaction` continues to validate/rebase/publish under the writer
   lock and enqueues replaced paths there. It no longer performs reclamation
   I/O. Its internal contract becomes publication plus queued retirement.
3. Both foreground and background compaction detach a batch under the writer
   lock, release that lock, run existing lease-aware reclamation, then restore
   deferred paths under the lock. Restore the entire retained batch before
   propagating an I/O failure. New paths enqueued during I/O must survive.
4. Preserve compaction serialization, cancellation, close/drain, source/file
   leases, durable manifest ordering, tail rebasing and recovery cleanup.
   Public foreground compaction still finishes its reclamation attempt before
   returning. No change to unrelated point-store or flush reclamation paths.

## Validation and decision

First demonstrate the changed internal publication boundary and queue ownership
using real files: no deletion during enqueue/publication, detached versus newly
queued paths, leased files retained, failure restore and a successful retry.
Then run existing foreground/background publication, file/process leases,
point compaction, maintenance shutdown and relevant crash-order tests. Saved
Python tests must use pixi activation, the Metal wrapper PATH and `-o pythonpath=`.

Measure the uninstrumented isolated candidate against the original baseline and
Qdrant with the existing full warm/mixed trial schedule. Keep all quality,
ID/score/stat audits and failed/slow samples. Separate traces may confirm the
shorter critical section. Do not combine the four-row scoring candidate until
this semantic package is validated independently. M5/M6 remains unchecked;
native Linux controlled-memory/nonresident validation lacks a runner.
