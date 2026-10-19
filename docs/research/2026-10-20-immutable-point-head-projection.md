# Compaction publication phases and head-only projection

The retained [HNSW List-batch source](2026-10-20-immutable-point-hnsw-batch.md)
still constructs projected rows for every numeric owner under writer, even
though immutable read runs were already prepared outside writer. Only the
current read head consumes that list. This candidate filters head membership
and sequence before cloning a descriptor. All live point/projection preflight,
durable publication and numeric-owner exchange remain in the same order.

The two rejected buffer variants are not part of this source. Production
remains `a6822c3`; full M5/M6 acceptance is still open.

## Reference and initial diagnosis

Pinned Qdrant
[`finish_optimization`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478)
propagates remaining changes after its slow build, upgrades the segment-holder
lock for the swap, then downgrades it before manifest synchronization and
retirement registration. Its separate
[`updates_mutex`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs#L18)
continues to exclude updates while readers can use the holder. This is a
reference for the preparation/publication boundary, not evidence that Akasha
already has equivalent lock separation. Akasha still holds its shared
query/writer lock throughout live publication.

A fresh instrumented build of the unchanged retained source splits admission,
live-owner staging, row projection, read-head staging, durable publication,
point/projection owner exchange and read-root exchange. Foreground and
background callers print only after leaving writer. The fixed workload takes
the background path. Query lock waits and publication intervals share the
same monotonic clock. Returned attempts distinguish cancellation, read-chain
conflict, manifest conflict and publication; raising attempts would fail their
worker rather than be counted as successful traces.

Six serial workers, two per corpus, retain **1,728 timed queries and 18 warmups**.
All IDs, F32 score bits, statistics, execution routes, recall and oracle results
match the prior source. All six exact reopens and six Arrow leases pass. All
60 recorded publication attempts publish; every output contains 1,024 points.
No timed samples or returned attempts are omitted.

Trial median microseconds:

| Corpus | Trial | Writer hold | Authority staging | Full projection | Read head | Durable publication |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 0 | 591.5 | 182.0 | 73.5 | 50.5 | 265.0 |
| uniform-128 | 1 | 575.5 | 184.0 | 72.0 | 49.5 | 259.5 |
| uniform-1536 | 0 | 698.0 | 203.0 | 76.5 | 52.5 | 324.5 |
| uniform-1536 | 1 | 632.0 | 185.0 | 71.5 | 48.0 | 301.5 |
| real-1536 | 0 | 603.0 | 185.0 | 74.0 | 47.0 | 286.0 |
| real-1536 | 1 | 646.5 | 188.0 | 73.5 | 51.0 | 316.0 |

Durable publication includes input unpinning, manifest load/rebase/write,
cache invalidation and retirement enqueue; it is not an isolated fsync timer.
Across all successful intervals it accounts for 44.7–49.2% of writer hold,
authority staging for 29.3–31.4%, and projection plus read-head staging for
18.8–20.9%. Point/projection/root exchanges account for about 2.3–2.4%.
Clock resolution is 1 µs; a zero median does not mean zero work.

Observed publication intervals overlap 3, 16 and 10 timed query waits across
the two trials of uniform-128, uniform-1536 and real-1536 respectively. Their
overlap totals are 1.709, 9.905 and 6.355 ms, versus all timed wait totals of
1.838, 10.494 and 6.698 ms. This attributes the reproduced diagnostic waits,
not earlier uninstrumented p95 samples.

Initial diagnostic native SHA-256:
`55c866581e615205ccd451d32b86b671390ba00172b7954e5b4431021e59c60f`.

## Implementation and invariants

Three files change in the frozen 132-file candidate:

- `committed_compaction.mojo` passes the current projection and already validated
  replacement records to read-owner staging, instead of constructing a complete
  projected list first.
- `read_generation.mojo` constructs projected rows only when a current head
  exists. Immutable layers use the previously prepared replacements exactly
  as before, and retain their current visibility masks.
- `memtable.mojo` replaces the obsolete full-projection helper with
  `_project_compaction_head`. For each grouped point it checks membership and
  matching sequence before cloning; every numeric field in an included group
  uses the same replacement owner. Empty heads need no projected rows.

The helper still visits the replacement records linearly. Descriptor
allocations are limited to matching head rows; this is not an O(head) claim
for all staging work. `_checkpoint_read_table` still validates every field of
each matching head row: field ID, kind, scalar type and byte count. The
unchanged PointTable staging validates every output point and live projection
before head filtering, including points absent from the head. Newer versions
are skipped under the same sequence rule as the previous read-table helper.

No lock, persisted format, numeric data, public getter, query parameter,
durability fence, source-file lease, retirement rule or retry budget changes.
There is no compatibility wrapper or old internal projection fallback. Existing
owners remain retained until the caller leaves writer.

## Validation and acceptance

- **140 unique CPU cases in 25 modules** pass: three new head-projection cases
  plus the inherited 137-case, 24-module compaction/recovery matrix. The new
  tests cover multiple numeric fields, noncontiguous matching head rows,
  newer and absent rows, empty/missing heads, unchanged old owners, and
  document-version, field-ID and shape corruption rejected before publication.
- The integration matrix covers typed and legacy output, migration cutover,
  late WAL writes/appended deltas, partial/background compaction, stale and
  cancelled preparation, live-authority corruption, snapshots, file leases,
  close/reclaim, HNSW publication and recovery. All **23 crash cases in eight
  modules** pass.
- **379 Python cases** pass, with candidate native identity confirmed in four
  launcher processes. Repository-source compile probes remain distinct from
  candidate-library execution. Candidate C ABI build, strict C11 compilation
  and execution pass.
- The first new-test compile exposed obsolete List/TestSuite fixture syntax.
  The rejected fixture and compiler-error summary are retained; the corrected
  fixture uses the installed Mojo 1.0.0 APIs and all three cases pass.
- No new GPU, native Linux or sustained-capacity result is claimed. Existing
  numeric kernels, GPU/Arrow implementations and durable formats are unchanged.

Python native SHA-256:
`90ba0f4e082811a5291cd4dfe151328c2d93d7bf48e335b80194d865623ca6a2`.
C native SHA-256:
`82c05a3358d1ba181e968b782116e08a9834ecd0bbe495426de9e95172f1d33e`.

## Balanced publication diagnosis

Twelve serial workers run prior/candidate followed by candidate/prior for each
corpus. The prior diagnostic binary above is reused only after verifying its
complete source inventory and binary hash. Candidate clocks use identical
publication boundaries. Projection now occurs inside head staging, so compare
the sum of projection and head time per publication, not the renamed phase
alone. Medians below are computed from those per-publication sums.

All **3,456 timed responses, 12 exact reopens and 12 Arrow leases** match.
The **36 warmup calls** execute successfully and retain clock traces; their
result values are not retained or compared. The same distinction applies to
the 18 initial-diagnosis warmups above. All 120 returned publication attempts
publish. No timed or publication
sample is omitted. The core query implementation, routes and counters are
unchanged.

| Corpus | Trial | Prior head preparation µs | Candidate µs | Reduction | Prior hold µs | Candidate µs | Reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 0 | 127.0 | 50.5 | 60.2% | 577.5 | 516.5 | 10.6% |
| uniform-128 | 1 | 125.5 | 49.5 | 60.6% | 584.0 | 496.5 | 15.0% |
| uniform-1536 | 0 | 126.0 | 52.0 | 58.7% | 642.0 | 568.5 | 11.4% |
| uniform-1536 | 1 | 131.0 | 51.0 | 61.1% | 669.0 | 550.0 | 17.8% |
| real-1536 | 0 | 128.5 | 52.0 | 59.5% | 611.0 | 545.0 | 10.8% |
| real-1536 | 1 | 129.0 | 51.0 | 60.5% | 634.0 | 547.0 | 13.7% |

Both orderings improve head preparation and total hold for every corpus.
Authority staging and durable publication still dominate the remaining hold;
their source is unchanged and no improvement to those algorithms is claimed.
Instrumented improvements are not uninstrumented QPS/p95 acceptance.

## Fixed mixed acceptance

Thirty-six serial workers compare production, prior List batches, this candidate
and native Qdrant Edge 0.8.0 using the unchanged plans, seeds, ef, oracle and
mixed read/upsert/flush schedule. Three of four order rotations are used, so
order is not fully balanced. Builds, tests, profiling and compression never
overlap timed workers.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. IDs, F32 score bits, statistics, routes and recall match the frozen
Akasha reference exactly. All Akasha recall cells pass; matched quality is
33/36 because the unchanged real-correlated Qdrant cells remain .945833 versus
Akasha's .980556. No ef retuning, exclusion or pending user decision is assumed.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 22/36 | 9/9 |
| Prior List batches | 33/36 | 19/36 | 9/9 |
| Head projection | 33/36 | 20/36 | 9/9 |

Median within-batch ratios; QPS improves above 1, p95 below 1. Every individual
trial gate remains authoritative:

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.979 | 0.990 | 1.004 | 0.976 |
| uniform-128 | correlated | 0.924 | 1.052 | 0.971 | 1.162 |
| uniform-128 | independent | 0.931 | 1.114 | 1.027 | 0.886 |
| uniform-128 | selective | 0.767 | 1.153 | 1.037 | 0.961 |
| uniform-1536 | all | 0.996 | 1.019 | 0.991 | 1.028 |
| uniform-1536 | correlated | 0.982 | 1.017 | 0.997 | 1.020 |
| uniform-1536 | independent | 0.989 | 1.007 | 0.998 | 1.017 |
| uniform-1536 | selective | 0.894 | 1.096 | 1.001 | 1.071 |
| real-1536 | all | 0.989 | 1.013 | 0.986 | 1.001 |
| real-1536 | correlated | 0.999 | 0.974 | 1.000 | 1.012 |
| real-1536 | independent | 0.963 | 1.295 | 0.998 | 1.006 |
| real-1536 | selective | 0.960 | 1.061 | 0.938 | 1.030 |

Two production and two prior pass-to-fail cells remain; they are the same cells:

- **uniform-1536 trial 0 selective:** prior 9,095.51 QPS / 134.625 µs p95,
  candidate 7,194.33 / 154.000, Qdrant 7,412.78 / 203.708. Candidate QPS fails;
  p95 and recall pass.
- **real-1536 trial 0 independent:** prior 1,921.69 QPS / 647.667 µs p95,
  candidate 1,820.01 / 1,000.292, Qdrant 1,838.76 / 883.500. Candidate QPS and
  p95 both fail; recall passes.

The phase improvement does not excuse those failures or prove their cause.
Several aggregate query ratios also regress. Combined write-plus-flush keeps
the durability-relevant comparison; raw update acknowledgements alone are not
treated as equivalent durability.

## Decision and evidence

Retain this isolated candidate for further work because the same publication
stage and total hold improve in both orderings without a correctness change.
Do not adopt it into production or mark any full performance requirement
complete. The earlier List source remains available as a comparator.

The remaining authority staging and durable publication still run while
excluding queries. Next audit query read roots and mutable HNSW scratch/stats
to implement Qdrant's separation of update exclusion from reader access.
That change must preserve complete preflight, manifest ordering, newer writes,
legacy cutover, bounded conflict retries and file-lease retirement. It cannot
be implemented by releasing the current writer lock around an unprotected
manifest operation.

Full warm/concurrent performance, sustained nonresident capacity under equal
limits, integration/example and native Linux gates remain open. Production
stays `a6822c3`; M5/M6 are not complete.

The [evidence archive](2026-10-20-immutable-point-head-projection.json.gz)
contains the full candidate and diagnostic sources, implementation diff,
new/inherited tests, initial fixture rejection, validation logs, native/runtime
hashes, the six initial and twelve paired diagnostic workers, all phase/query
traces, 36 mixed reports/logs, the complete frozen plans, workload hashes and
three pinned Qdrant files including LICENSE. Copied databases, native binaries
and workload NPZ files are excluded. Every embedded text hash, parent-source
identity and Qdrant reference is verified, as is the unchanged production src.

The archive has **1,207 text artifacts, 19,219,933 compressed bytes**, SHA-256
`331f221812c7257506b9c2f9d183191c46e4b88af9bf9e4ee0e68dffb5ffaaa4`.
