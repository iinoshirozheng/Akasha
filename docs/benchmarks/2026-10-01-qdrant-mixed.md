# Resident mixed reads, writes, maintenance and Arrow leases

Three fresh sequential process trials per corpus clone the closed, fixed
post-mutation baseline databases. Each trial executes 32 blocks of nine reads,
one eight-point replacement batch and one flush: 288 reads, 32 write operations,
256 replaced points and 32 flushes. The read/write operation ratio is 90/10 when
flush is excluded. Fixed per-engine ef comes from the earlier matched-recall
report. This is one foreground caller interleaved with configured engine workers;
there is no concurrent-client or non-resident claim and no explicit optimizer
call. The engines need not perform identical maintenance work for a flush.

Every evolving-state Float64 oracle was computed before either worker started.
After all workers exited, the shared independent validator checked all 5,184
returned rankings for duplicate/non-live IDs, count bounds and filter membership,
and recomputed every recorded recall. All 36 filter/trial comparisons meet .95
recall with valid execution classification. Every engine's final reopened exact
query matches the final oracle. Stats/oracle validation is outside query timings;
the report also records write/flush p50/p95/p99, RSS high-water marks, inventories,
binary/source/workload hashes, all plans and the exact benchmark source used.

Median query QPS ratio Akasha/Qdrant, with full three-trial range:

| Corpus | All | Correlated | Independent | Selective |
| --- | --- | --- | --- | --- |
| Uniform 128D dot | 1.181 (.973–1.253) | 2.074 (1.786–2.289) | 1.885 (1.878–2.258) | 1.005 (.756–1.284) |
| Uniform 1536D dot | 1.557 (1.538–1.558) | 1.372 (1.325–1.392) | 1.134 (1.095–1.155) | .750 (.636–.890) |
| Real 1536D cosine | .534 (.456–.571) | .459 (.457–.525) | .270 (.246–.317) | .609 (.305–.620) |

The real-data graph path remains below parity. Tail outliers are retained:
Akasha real independent p99 reaches 20.329 ms in the third trial. First-process
open and post-write reopen retain the OS page cache. Post-write reopen takes
.734–.749 seconds for 128D and 1.692–2.185 seconds for 1536D in Akasha, versus
.044–.060 seconds in Qdrant. The former 75–76 second graph rebuild is resolved,
but cold/open speed parity is still unmet.

Eight-point write p95 is 13.72–13.95 ms in Akasha 128D and 23.73–36.40 ms at
1536D; Qdrant's update calls measure .38–.87 ms. Akasha flush p95 is 32.75–33.26 ms
at 128D and 140.12–176.91 ms at 1536D, versus 34.54–45.76 ms in Qdrant. These are
specific API service costs. The word `atomic` in the as-run scope describes
Akasha's batch contract; Qdrant cross-point atomicity was not established by this
measurement. Both workers issue one batch update followed by flush per block.
Akasha's accepted batch includes WAL fsync; Edge synchronizes WAL/segments in
the separate flush. Thus update latency alone is not a durability-equivalent
comparison; see the [pinned baseline contract](2026-09-30-qdrant-comparison.md).
New reports also summarize each block's combined update-plus-flush time, keeping
the two component timings and their different maintenance work visible.

## Lease and compaction evidence

Each Akasha worker retains one Arrow row/vector batch across all writes, flushes
and collection close. Its content remains unchanged after close. Actual
`segment-compact-*` files appear during the run. For example, the first 128D trial
keeps the original base and delta beside compacted outputs until the Arrow owner
is released. Disk inventory is 23,661,470 bytes after close with the lease and
15,835,670 after release; the original base/delta are then gone. The newer compacted
base and current deltas remain. The same ownership checks pass in all nine
Akasha trials. Qdrant Edge has no corresponding Arrow lease API, so this lifecycle
cell is not a cross-engine comparison. RSS is peak process usage, not current
resident bytes or precise retained-owner allocation.

[Raw archive](results/2026-10-01-qdrant-mixed.json.gz) includes the separate
post-run filter audit and as-run source. The reusable benchmark now performs that
audit after each worker. No performance samples were rerun merely to add this
out-of-timing verification.

## Remaining M6 work

Warm real-data, write and high-dimensional flush speed gaps remain. Source
inspection after measurement identifies full MemTable cloning and metadata
rebuilding in legacy batch commits as the next bounded optimization target.
That change is now implemented and separately measured in the
[paired batch report](2026-10-02-bounded-batch.md); its real-data tail dispersion
is preserved and does not establish Qdrant parity.
True non-resident/OS-cache-evicted measurements, concurrent-client boundaries,
and HTTP comparisons have not been run in this restricted embedded environment.
The completed resident interleaving cell does not stand in for those gates.
