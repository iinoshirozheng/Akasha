# Query exclusion during live compaction

This isolated candidate starts from the retained
[head-projection source](2026-10-20-immutable-point-head-projection.md).
It separates six ANN entrypoints from publication's writer lock, then acquires
their shared query lock for the final live-owner exchange. The query lock still
serializes mutable HNSW scratch, statistics and graph-availability state.

Production remains `a6822c3`. No full M5/M6 acceptance is claimed.

## Qdrant reference and prior experiment

Pinned Qdrant commit `21db2f3ff95d50de3a2b88a741312c056fd1762d`
[`finish_optimization`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478)
holds an upgradable segment-holder read guard and a separate update mutex
while propagating changes. It upgrades for the swap, then downgrades before
manifest synchronization and retirement registration. Its
[`LockedSegmentHolder`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs#L18)
makes update exclusion separate from reader exclusion.

The implemented design principle is a short exclusion around live-state exchange.
Akasha preserves its own durable order: publish the manifest first, then
exchange the live owners. It does not copy Qdrant's manifest order or introduce
its segment-holder architecture. Snapshot creation and lazy read-root/pin
updates remain writer-serialized, so they cannot enter the interval between
manifest publication and live-root exchange.

The [October 14 lock experiment](2026-10-14-live-query-lock.md) already tested
separate ANN exclusion before live mapped-owner replacement existed. Its guard
pattern and four tests are reused, with the additional shared query lock in the
current compaction finalizer. The older implementation cannot be copied
unchanged because the finalizer now mutates owners borrowed by ANN scoring.
The original archive SHA-256 is
`0e9ba9630a0681ad660cd694912f030878bcc44bca73009f2c28919855f4734b`.

## Implementation and boundaries

Three files change in the 132-file frozen candidate:

- `collection.mojo` creates a heap-stable query lock, shares it with maintenance,
  and uses it alone in `search_{dot,l2,cosine}_approx{,_where}`. The remaining
  52 foreground writer scopes acquire writer then query. Final foreground
  publication holds writer, calls the shared finalizer, and acquires query for
  index-cache publication or its conflict counter afterward.
- `maintenance.mojo` retains the same query-lock owner and supplies it to the
  shared finalizer. Capture, cancellation and other writer responsibilities
  remain unchanged.
- `committed_compaction.mojo` keeps authority validation, read-head staging and
  durable publication under writer. PointTable, MemTable and the read-root
  exchange occur together under query. Detached owners remain retained until
  the caller has left writer.

All original executable foreground bodies are checked after normalizing the
new guards and shared-lock arguments. The 18-method direct ANN call closure
contains no writer acquisition. The lock order is writer then query; ANN never
reverses it. Maintenance status reads use the existing status lock. Neither
search routes, results, score arithmetic, counters nor error precedence change.

Other foreground operations still hold both locks, including foreground
flush and snapshot construction. Multiple ANN readers are still serialized.
This is not full concurrent read/update support. The existing benchmark times
request construction and the adapter's `db.search(...)` call; its subsequent
`db.stats()` call remains outside that interval and may wait for writer. No
timing boundary is changed.

Durable formats, complete preflight, late writes, legacy cutover, four-delta
compaction admission, four-attempt retries and exact-file leases are unchanged.
No old internal API fallback or optional-lock compatibility path is added.

## Correctness validation

The parent source fails the expected lock-progress regression: while another
thread holds writer, none of the six ANN entrypoints completes. Its test process
exits 1 with three cases passing and one failing. The candidate passes all four:
progress while writer is held, error-path release, complete-batch visibility,
and close/query races.

A new two-thread barrier test runs the actual finalizer. While query is held,
the disk manifest advances but both live tables retain their old numeric owner.
After query is released, both tables exchange to the same new owner. The old
snapshot and borrowed value remain valid; ANN and reopen results are correct.
This directly covers the live-owner mutation absent from the old experiment.

All **145 unique CPU cases in 27 modules** pass: the four restored lock cases,
one owner-exchange barrier, three inherited head-projection cases, and the
137-case compaction/recovery matrix. All **23 crash cases in eight modules**
pass, including typed/legacy formats, late writes, cancellation/conflicts,
corruption rejection, snapshot ownership, leases and recovery.

All **379 Python cases** pass with candidate identity checked in four launcher
processes. Repository-source compile probes remain separate from candidate
native execution. The C ABI library build, strict C11 compile and execution
pass. Existing unused-assignment warnings and one Python dependency deprecation
warning remain in the logs.

Python native SHA-256: `4d71aec5b11193be99034bd87ccdc163d63526d464c84351bc44c7ddf1b4f96e`.
C native SHA-256: `29a56aa56f1af465dc058db6308989963001be420a3c65e84fe85e4c86838336`.

## Publication diagnosis

Twelve serial workers use prior/candidate followed by candidate/prior for each
corpus. The prior diagnostic source and binary are verified before reuse.
Both versions record writer-held publication phases and query waits. Candidate
instrumentation additionally records acquisition and release of the late query
guard, separating its lock wait from the point-owner exchange.

For the parent, publication's writer interval excludes queries. For the candidate,
only the late query guard does. Query-wait overlap is attributed to those
respective exclusion intervals, never to the candidate's full writer interval.
The observed 1 µs clock resolution and instrumentation cost limit precision.
Diagnostics are not performance acceptance.

All **3,456 timed responses** match the frozen prior IDs, F32 score bits,
statistics, routes, recall and oracle. All **12 exact reopens and 12 Arrow
leases** pass. The **36 warmup calls** execute successfully and retain clock
traces; their result values are not retained or compared. All 120 publication
attempts publish. No timed query or publication sample is omitted. Trial medians:

| Corpus | Trial | Prior query exclusion µs | Candidate µs | Reduction | Prior writer µs | Candidate writer µs | Candidate waits for query µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 0 | 493.5 | 14.0 | 97.2% | 493.5 | 492.0 | 0.0 |
| uniform-128 | 1 | 490.0 | 15.0 | 96.9% | 490.0 | 501.0 | 0.5 |
| uniform-1536 | 0 | 572.0 | 29.0 | 94.9% | 572.0 | 1381.0 | 759.0 |
| uniform-1536 | 1 | 569.5 | 31.0 | 94.6% | 569.5 | 1121.0 | 359.0 |
| real-1536 | 0 | 537.0 | 22.0 | 95.9% | 537.0 | 567.0 | 1.0 |
| real-1536 | 1 | 546.0 | 22.5 | 95.9% | 546.0 | 568.0 | 0.0 |

Query exclusion falls by **94.6–97.2%** in both orderings for every corpus.
Writer hold is distinct: uniform-1536 rises from about 0.57 ms to 1.12–1.38 ms,
including a median 0.36–0.76 ms waiting for active queries before the exchange.
This can delay writer-serialized APIs even when the timed ANN call completes
sooner. Owner-exchange execution also grows in the high-dimensional traces;
no improvement to that operation itself is claimed.

| Corpus, both trials | Prior query waits ms | Candidate query waits ms | Prior publication overlap ms | Candidate publication overlap ms |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 | 4.158 | 0.070 | 3.879 | 0.000 |
| uniform-1536 | 4.836 | 0.133 | 4.540 | 0.000 |
| real-1536 | 5.051 | 0.092 | 4.727 | 0.000 |

The prior has 26 timed queries with observed publication overlap; the candidate
has zero in these traces. That does not prove every possible query is wait-free.
The writer wait has moved to the publication side, and the uninstrumented
end-to-end cells below remain authoritative.

Prior diagnostic SHA-256:
`5272ad075e1957afe5316b720a06cd7f17fd4f55651014d27e3777256822a843`.
Candidate diagnostic SHA-256:
`59cfb769a213b0960520a6a911c4c77549b0dc2032fad8c1c98fb3a208161176`.

## Fixed mixed acceptance

Thirty-six serial workers compare production, the retained head-projection
source, the query-lock candidate and native Qdrant Edge 0.8.0. The workload,
plans, ef, oracle, query timing and upsert/flush schedule remain unchanged.
Three of four order rotations are used; this is not fully balanced. Builds,
tests, instrumentation workers and compression do not overlap timed workers.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. Every Akasha response matches exact IDs, F32 score bits, statistics,
routes, recall and oracle. Every Akasha recall cell passes. Matched quality
remains **33/36** because Qdrant's real-correlated recall is .945833 versus
Akasha's .980556 in all three trials. Those cells remain failed, with no speed
acceptance comparison or ef adjustment.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 25/36 | 9/9 |
| Head projection | 33/36 | 22/36 | 9/9 |
| Query lock | 33/36 | 25/36 | 9/9 |

There are **zero production pass-to-fail and zero prior pass-to-fail cells**.
The 22→25 comparison uses this same batch; earlier batches have different
production counts and are not substituted. Within-batch median ratios follow;
QPS improves above 1, p95 below 1. Individual cells, not these medians, determine
acceptance.

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.984 | 0.964 | 1.016 | 1.011 |
| uniform-128 | correlated | 0.968 | 1.040 | 1.025 | 0.971 |
| uniform-128 | independent | 0.974 | 0.954 | 1.062 | 0.851 |
| uniform-128 | selective | 1.038 | 1.013 | 1.391 | 0.881 |
| uniform-1536 | all | 1.012 | 0.966 | 0.997 | 0.992 |
| uniform-1536 | correlated | 1.010 | 0.979 | 1.028 | 0.926 |
| uniform-1536 | independent | 1.014 | 0.979 | 1.009 | 0.952 |
| uniform-1536 | selective | 1.070 | 0.965 | 1.098 | 1.007 |
| real-1536 | all | 1.026 | 0.982 | 0.999 | 1.023 |
| real-1536 | correlated | 1.018 | 0.965 | 1.035 | 0.986 |
| real-1536 | independent | 1.016 | 0.978 | 1.015 | 1.006 |
| real-1536 | selective | 1.114 | 0.908 | 1.070 | 0.984 |

Several ratios still regress despite the improved gate count, including
uniform-128 correlated versus production and real-1536 all-mode p95 versus the
prior. Combined write-plus-flush remains 9/9 for all three Akasha variants;
raw update acknowledgements are not treated as equivalent durability.

All eight speed failures with valid matched quality are retained:

| Corpus | Trial | Mode | Candidate QPS | Qdrant QPS | Candidate p95 µs | Qdrant p95 µs | Failed speed gates |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| uniform-128 | 0 | all | 2513.11 | 2610.79 | 522.334 | 672.041 | QPS |
| uniform-128 | 2 | all | 2564.63 | 2656.68 | 528.750 | 689.583 | QPS |
| uniform-1536 | 0 | correlated | 764.32 | 899.98 | 1512.417 | 1289.166 | QPS + p95 |
| uniform-1536 | 0 | independent | 759.29 | 885.93 | 1516.500 | 1335.209 | QPS + p95 |
| uniform-1536 | 1 | correlated | 758.80 | 948.05 | 1497.750 | 1220.875 | QPS + p95 |
| uniform-1536 | 1 | independent | 753.73 | 927.38 | 1544.542 | 1339.542 | QPS + p95 |
| uniform-1536 | 2 | correlated | 757.79 | 897.71 | 1492.500 | 1282.291 | QPS + p95 |
| uniform-1536 | 2 | independent | 755.80 | 887.07 | 1507.708 | 1314.833 | QPS + p95 |

The three real-correlated quality failures above make 11 failed cells total.
No failure is excluded or offset by another cell.

## Decision and evidence

Retain the query-lock candidate for subsequent work: correctness is preserved,
publication excludes queries for less time in both diagnostic orderings, and
the same-batch strict mixed count rises from 22 to 25 without any pass-to-fail
cell. Do not adopt into production or mark the full performance requirement
complete. Longer writer holds and the remaining per-cell failures remain part
of the decision.

Next profile the six uniform-1536 correlated/independent failures against
pinned Qdrant's filtered traversal and scoring. The repeated failures after
removing the reproduced publication waits justify inspecting that query path;
they do not yet prove which operation causes the gap. Keep the two uniform-128
all-mode failures and all quality failures in the complete acceptance matrix.

Full warm/concurrent performance, sustained nonresident capacity under equal
limits, integration/example and native Linux gates remain open. No new GPU or
native Linux result is claimed. No ef recalibration or sample exclusion is
assumed from the unanswered user decisions. Production remains `a6822c3`.

The [evidence archive](2026-10-20-immutable-point-query-lock.json.gz) includes
candidate and diagnostic sources, implementation diff, guard/call audits,
restored old fixtures, parent regression failure, new barrier test, complete
validation logs and native identities, paired diagnostic traces, all 36 mixed
reports and logs, and the pinned Qdrant sources with LICENSE. Exact frozen plans
are referenced by verified hash and key in the parent head-projection archive;
they are not duplicated. Workload NPZ files, copied databases and native binaries
are excluded, with their relevant identities retained.

The verified archive contains **902 text artifacts, 3,239,267 compressed bytes**,
SHA-256 `cee93573303bc99ad13b192ffd1f75658b3bdfdf28e480d3da9c67b85202b234`.
