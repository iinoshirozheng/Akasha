# Mixed query tail: native writer-lock boundaries

The reproduced selective-query tail overlaps background compaction holding the
same writer lock used by approximate-query entry points. It occurs in both
production and the isolated F32 row-copy candidate. This localizes the new
diagnostic runs; it cannot retroactively assign a cause to each uninstrumented
sample or erase the candidate's earlier strict-gate failure.

## Boundary evidence

Six serial workers use the two unchanged native binaries and the three original
mixed plans. The diagnostic separates Python request/search time, records thread
CPU time and GC callbacks, and reads the existing `TraceRecord.duration_ns` for
the native call. All 1,728 paired IDs, Float32 bits, stats and execution decisions
match the frozen trial-0 controls. Retained Arrow leases and reopen oracles pass.

Each worker observes two generation-0 collections during write/flush, with zero
GC overlap across all timed queries. The largest selective samples are dominated
by the native call, and several have substantially less thread CPU than elapsed
time. For example, production uniform-128 ordinal 27 takes 329 µs, native 309 µs,
thread CPU 133 µs; candidate ordinal 171 takes 370/348/148 µs respectively.
This supports investigating waits; CPU gaps alone do not prove a specific lock.
The six workers complete in 17.61 s. Callback allocations, clocks and the named
request's lifetime perturb scheduling; these are not acceptance timings.

## Native lock evidence

Two isolated source trees add timestamps to the six public approximate-query
lock scopes and background compaction capture/publish/reclaim boundaries.
Both Mojo 1.0.0 shared libraries compile without warnings. No lock policy,
validation, query algorithm, format or durability order changes. Prints occur
after the measured query and compaction lock scopes. The original mixed worker
and plans run unchanged for another six serial workers, completing in 18.72 s.
All 1,728 query pairs and lease/reopen checks again pass.

There are 291 query-lock events per worker: three warmups and 288 measured
queries. They are paired in execution order, not by assuming Python and Mojo
clocks share an epoch. Background interval comparisons use only Mojo clocks.
All 71 capture and 71 publication attempts remain, including two unpublished
attempts; 69 successful publications have reclamation events.

Median microseconds from lock entry through the post-release timestamp:

| Corpus | Variant | Capture | Publish | Successful / attempted publications |
| --- | --- | ---: | ---: | ---: |
| Uniform 128 | Production | 192.5 | 260.5 | 12 / 12 |
| Uniform 128 | Row copy | 173.0 | 273.0 | 12 / 12 |
| Uniform 1536 | Production | 202.0 | 318.0 | 11 / 11 |
| Uniform 1536 | Row copy | 190.0 | 355.0 | 12 / 13 |
| Real 1536 | Production | 175.0 | 326.0 | 11 / 11 |
| Real 1536 | Row copy | 168.5 | 361.0 | 11 / 12 |

For uniform-128 candidate ordinal 171, public latency is 397 µs, query lock
wait 306 µs and core execution 52 µs; 303 µs of the wait overlaps publication.
Ordinal 27 waits 210 µs, overlapping capture for 189 µs. Production ordinal 135
waits 541 µs, overlapping publication for 518 µs. All samples and top-ten rows
for every mode remain in the archive, including tails without such overlap.

These are upper bounds on held time because the ending timestamp follows lock
release. Reclamation is a whole helper interval with mostly unlocked I/O; its
overlap must not be described as writer-lock ownership. Instrumentation changes
interleaving, visible in the different attempt counts. Zero-microsecond measured
waits do not establish an absence of sub-microsecond contention.

## Source explanation and next work

Filtered approximate entry points retain the writer lock while planning. A
selective query that chooses planned exact calls `_search_candidates` directly;
it does not acquire or reconstruct a read snapshot. Background capture calls
`begin_compaction`, which reads the manifest and a bounded segment header before
pinning the inputs. Background publication validates/rebases against the current
manifest and durably publishes it under the same lock. These operations protect
accepted writes, pins and recovery; they cannot simply be unlocked.

This agrees with the earlier observation that the fixed mixed path does not
rebuild a full read base after each compaction. A future change to these lock
boundaries needs an explicit publication predicate and race/crash tests. The
current evidence does not justify changing durability or disabling maintenance.
Keep the row-copy candidate isolated and its failed cell intact. Continue with
the independently localized payload-encoding work in the
[flush diagnostic](2026-10-14-legacy-flush-phases.md): both authority fingerprint
and metadata serialization call the same ordered codec.

The [archive](2026-10-14-mixed-query-boundaries.json.gz) contains **349 files,
1,979,000 bytes**, including complete native diagnostic sources, unchanged Python
package sources, patches, drivers, all 12 raw worker reports/logs, build identities
and summaries. Full original plans are referenced by verified hashes in the
flush archive. The two parent archives are also identified by SHA-256. Every
embedded hash and source/binary inventory is verified; root production source
and Python binary still match the frozen parent.

Archive SHA-256: `68f768313f6dd89d40c250fd7152a4d49e043cec48983e4f1248b979a670f0c6`.
All builds, workers and compression run serially. No new full correctness suite,
speed, native Linux, capacity/nonresident, C ABI, crash or GPU gate is claimed.
M5/M6 remain incomplete.
