# Native query phases: production versus shared-owner candidate

The same phase clocks now compare production `a6822c3` with the isolated
[owner-capture candidate](2026-10-20-immutable-point-owner-capture.md). Search
core time remains higher in the candidate across all twelve corpus/mode groups.
Filtering is similar; publication waits remain visible separately. This is a
diagnosis of the existing candidate, not a new product implementation or speed
acceptance run. Production is unchanged and M5/M6 remain open.

## Reference and scope

The reference remains Qdrant commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`. Its
[`LockedSegmentHolder`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs)
has separate holder read/write and update locks. Akasha still holds its writer
lock through these ANN queries. That difference matters, but cannot explain
cost measured inside the query after the lock is acquired.

For the next query optimization, Qdrant's
[`ImmutableDenseVectorData::for_each_in_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/immutable_dense_vectors.rs)
gathers borrowed rows in bounded batches before scoring, while
[`MetricQueryScorer::score_stored_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/query_scorer/metric_query_scorer.rs)
keeps the storage borrow and preprocessed query outside individual scores. These
are concrete source paths to evaluate against Akasha's row acquisition and
scoring path; the current experiment does not yet establish a batching speedup.
All five reference files, including compaction finalization and LICENSE, are
extracted with `git show` of the pinned object and hashed. The checkout HEAD is
`74f3e85`, but these particular files are byte-identical to the pinned versions.

## Method and verification

Both diagnostic kernels compile with Mojo `1.0.0 (ed45d567)`. Their frozen
source inventories contain 127 production and 130 candidate files. Only
`api/collection.mojo` differs between each baseline and its diagnostic copy.
The original production build source was also compared with repository source:
all 127 Mojo files match, and its retained native library SHA-256 is
`f4d7736f453e8e0187860f6dd15eb998b586083bcf9a4ef6dd0a84cf98a55067`.

Identical clocks surround lock acquisition, validation, filter evaluation,
planning/eligibility preparation, search core, result/statistics finalization
and cleanup. Eight fixed Int64 lanes hold diagnostics under the existing lock;
one trace prints after unlocking. The core includes HNSW traversal, scoring
and reranking on ANN paths, or candidate gathering, scoring and top-k on exact
paths. It does not isolate arithmetic from row acquisition. No per-vector clocks
or additional synchronization are introduced.

Twelve serial workers cover three corpora, with production/candidate then
candidate/production ordering for each corpus. Each uses the same frozen
32-block plan, queries, eight-point updates, flushes, ef values and exact oracles.
No builds, tests or compression overlap the workers. All **3,456 timed responses**
match the uninstrumented candidate's exact IDs, F32 score bits, statistics,
execution decisions, recall and oracle. All **12 exact reopens and 12 Arrow
leases** pass. All 36 explicit warmups remain in raw traces and are separate
from timed-query summaries; no timed samples are discarded. Each mode has 72
queries per worker. Every ANN route remains ANN and every selective route
remains planned exact, with no new fallback.

The first setup equality assertion overlooked the known Arc memtable
dereference in the candidate. It now normalizes only that preexisting spelling
difference. The initial compile also required explicit Int-to-Int64 timestamp
conversion. The rejected script, build result and compiler log are retained.
These are instrumentation setup fixes; no product behavior or worker result
was changed. Both final diagnostic builds and all workers succeed.

## Measurements

The table reports the median of the two trial medians, in microseconds. Each
trial remains available separately. Observed clock timestamps are multiples of
1,000 ns; a zero phase median means below this resolution, not zero work.

| Corpus | Mode | Production core µs | Candidate core µs | Production filter µs | Candidate filter µs |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 346.75 | 364.75 | 0.00 | 0.00 |
| uniform-128 | correlated | 388.50 | 416.00 | 9.00 | 9.00 |
| uniform-128 | independent | 383.75 | 414.75 | 8.00 | 8.50 |
| uniform-128 | selective | 18.25 | 23.50 | 4.00 | 4.00 |
| uniform-1536 | all | 2567.25 | 2583.75 | 0.00 | 0.00 |
| uniform-1536 | correlated | 1238.50 | 1285.75 | 10.00 | 10.25 |
| uniform-1536 | independent | 1241.00 | 1269.25 | 9.00 | 9.00 |
| uniform-1536 | selective | 76.00 | 82.00 | 5.00 | 5.00 |
| real-1536 | all | 322.00 | 329.25 | 0.00 | 0.00 |
| real-1536 | correlated | 722.75 | 742.50 | 9.00 | 9.00 |
| real-1536 | independent | 455.75 | 465.00 | 8.50 | 9.00 |
| real-1536 | selective | 82.00 | 88.50 | 4.00 | 4.50 |

Selective core differences are 5.25/6.00/6.50 µs for uniform-128, uniform-1536
and real-1536. The corresponding total lock waits across 144 queries are
920/34/1,252 µs for production and 2,481/2,279/3,131 µs for the candidate.
Other groups also retain all waits; low wait medians must not hide their tails.
This supports investigating both query-core cost and publication interference.
It does not attribute the entire core difference to a particular instruction,
nor establish how much end-to-end latency any proposed change will recover.

Instrumentation and printing may affect optimization, scheduling and cache
state. These values are diagnostic; the prior uninstrumented strict mixed
result stays **23/36 production versus 16/36 candidate**, with every regression
retained. No acceptance threshold, quality requirement or workload changes.

## Next implementation and evidence

Evaluate the pinned Qdrant batch-read/scorer boundary in Akasha's borrowed
numeric path, preserving F32 reduction order, bounds, native errors, point
eligibility and owner lifetimes. The earlier raw-pointer kernel trial already
failed to remove the gap and is not repeated unchanged. Keep publication wait
cost separate and retain the need for read/update lock separation. Any resulting
candidate must compile, preserve exact responses and pass uninstrumented gates
before adoption. Full warm/concurrent, sustained nonresident capacity,
integration/example and native Linux gates remain open.

The [evidence archive](2026-10-20-immutable-point-query-phases.json.gz) contains
both complete source baselines and diagnostic variants, instrumentation and
analysis scripts, both successful builds and initial failures, all twelve raw
worker reports/logs, every phase trace and pinned reference files. Frozen plans
are hash-verified and retained through the linked parent evidence chain; binaries
and copied databases are excluded. All embedded hashes and the parent archive
were verified.
The archive has 620 text artifacts, 1,811,076 compressed bytes,
SHA-256 `0407d367e64d61ad984db2476d0f81acef159c1b371eb26bac9310e6b85b47b1`.
