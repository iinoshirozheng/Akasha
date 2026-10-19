# Borrowed-row batches for authoritative HNSW reranking

The isolated HNSW batch candidate preserves results and error behavior, but has
mixed performance. Balanced diagnostic pairs show 4.2–12.9% lower authoritative
rerank medians in the six 1536-dimensional groups, while all three 128-dimensional
groups regress 5.2–6.9%. Fresh uninstrumented strict quality-plus-speed results
are **24/36 production, 20/36 prior candidate and 22/36 HNSW batch candidate**.
Two production pass-to-fail cells remain. Production stays `a6822c3`; this is
research evidence, not adoption or completion of M5/M6.

## Reference and implementation

The source base is the verified [selective batch candidate](2026-10-20-immutable-point-batch-score.md),
committed in `c09aba4`. The Qdrant reference remains pinned to
`21db2f3ff95d50de3a2b88a741312c056fd1762d`:

- [`ImmutableDenseVectorData::for_each_in_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/immutable_dense_vectors.rs)
  gathers vector views before invoking the scorer, using a fixed local buffer.
- [`VECTOR_READ_BATCH_SIZE`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/common.rs)
  sets the maximum to 64 rows.
- [`MetricQueryScorer::score_stored_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/query_scorer/metric_query_scorer.rs)
  keeps the prepared query and storage borrow outside individual scores.

Exactly three source files differ from the prior candidate. The pair record and
its scoring operation move to `compute/dense_batch.mojo`, shared by selective
exact scoring and `index/segmented_hnsw.mojo`. Both authoritative rerank methods
gather at most 32 original score pairs before consuming them. Their first pair
establishes the actual nested reader origin, so no ownership casts, owner clones
or numeric materialization are introduced. The existing pair kernels, offer
order, source checks and filter checks remain intact.

Prefetch failures are deferred until earlier complete pairs have been scored.
Public lookup counters advance at each pair's original scoring boundary, rather
than exposing all prefetched lookups. An earlier score error therefore retains
its original error and partial counters. Validation of a second candidate still
precedes acquisition of the first candidate's reader. Query statistics, exact
F32 bits, tie handling, fallback reasons, ef, persistence formats, public owned
getters and storage/publication behavior do not change.

The candidate currently uses a bounded-capacity `List` for borrowed pairs;
Qdrant's fixed local buffer is a remaining implementation difference. The
low-dimensional regression makes buffer-management cost a testable hypothesis,
not an established explanation. No dimension threshold or alternate path is
added to hide that regression.

## Validation

- **113 unique CPU cases in 14 modules**: three new cases against frozen prior
  rerank functions, followed by 110 cases in 13 existing/query modules. Coverage
  includes all three metrics, dimensions 3/65/1536, empty/single/paired inputs,
  63–67 and 129–130 row boundaries, zero limits, exact F32 bits, and both filter
  modes. Error cases combine score overflow with missing IDs, tombstones,
  missing/wrong-scalar dense fields and filter rejection, checking partial stats.
- **379 Python cases** pass; four launcher processes verify the exact candidate
  native SHA-256. Repository-source probes still inspect repository source and
  are distinguished from candidate-library execution.
- The candidate **C ABI** library build, strict C11 compilation and test pass.
- All builds/tests use the frozen 132-file source inventory. Persistence and
  GPU code are unchanged; no new crash-recovery or actual-device GPU result is
  claimed for this query-only change.

The existing rerank fixture initially passed an owned List to a private scorer
that already required a reader in the candidate lineage. The isolated fixture
now passes `_dense_reader()`. Moving scoring into a generic record also exposed
a nominal row-type mismatch; the final record explicitly uses the borrowed F32
reader's origin. Initial sources and compiler failures are retained. A separate
diagnostic build initially omitted counter initialization in one of two index
constructors; both were corrected before any diagnostic worker ran. The failed
build and instrumentation are archived. The compiler is Mojo **1.0.0 (ed45d567)**.

Python native SHA-256:
`8ad8364e8205ad0cb8197e4825d6f873eeae59d728b73e5368e80428c9c79bb3`.
C native SHA-256:
`c67a5ff85b825be7809816a3dff0eb41659fdfe6c4d9c6b155464bd7d45b3d08`.

## Balanced phase diagnosis

Both prior and candidate diagnostic kernels are freshly built with identical
collection phase boundaries and authoritative-rerank timers. Counters reset
under the collection lock; trace output occurs after unlocking. Twelve serial
workers run prior/candidate then candidate/prior for each corpus. All **3,456
timed responses, 12 exact reopens and 12 Arrow leases** match the frozen
uninstrumented results, including IDs, bits, statistics, recall and execution
route. All 36 warmups are retained separately; no timed samples are discarded.
The 2,592 timed ANN queries each invoke authoritative reranking once; the 864
planned-exact queries never invoke it.

Microseconds below are medians of the two trial medians. Negative reduction
means a slower rerank. Both individual trials have the same gain/regression
direction in every rerank group.

| Corpus | Mode | Prior rerank µs | Batch rerank µs | Reduction | Prior core µs | Batch core µs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | all | 29.00 | 30.50 | -5.2% | 362.75 | 363.75 |
| uniform-128 | correlated | 54.00 | 57.75 | -6.9% | 398.75 | 410.50 |
| uniform-128 | independent | 54.50 | 57.50 | -5.5% | 398.00 | 406.25 |
| uniform-1536 | all | 402.50 | 350.50 | 12.9% | 2554.75 | 2485.75 |
| uniform-1536 | correlated | 274.50 | 252.00 | 8.2% | 1238.50 | 1224.50 |
| uniform-1536 | independent | 279.25 | 259.00 | 7.3% | 1249.00 | 1225.75 |
| real-1536 | all | 26.50 | 24.00 | 9.4% | 320.25 | 320.50 |
| real-1536 | correlated | 172.00 | 164.75 | 4.2% | 715.75 | 705.25 |
| real-1536 | independent | 99.00 | 91.50 | 7.6% | 456.75 | 449.25 |

Reranking accounts for approximately 8–24% of prior total ANN core time,
depending on the group. Improving that stage cannot eliminate all remaining
search cost. In real-1536/all, reranking improves while the full core median
does not, illustrating the limit of stage-only conclusions.

Selective core medians change 22.00→21.50, 72.75→71.75 and 78.00→77.25 µs.
Their total writer waits across 144 timed queries per variant/corpus change
1501→4109, 642→2800 and 640→1356 µs. Publication interference therefore remains
visible even when core medians improve. These instrumented observations do not
establish the cause of separate uninstrumented tails or satisfy a speed gate.
Observed timestamps have 1 µs resolution; zero phase medians are not zero cost.

## Fixed uninstrumented comparison

Thirty-six serial workers compare production, the prior selective-batch
candidate, the HNSW-batch candidate and native Qdrant Edge 0.8.0. They use the
same three corpora, three trials, frozen plans/seeds/ef/oracles and mixed
read/upsert/flush schedule. Three of four order rotations are used, so this
comparison is not fully order-balanced. No build, test, profiling or compression
overlaps the timed workers.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. Akasha variants have identical IDs, F32 bits, stats and execution
decisions, and meet all 36 recall cells. Matched quality stays 33/36 because
Qdrant's three real-correlated cells retain recall .945833 versus Akasha's
.980556. The original failures remain: ef has not been recalibrated, and no
pending benchmark-contract decision is treated as approval.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 24/36 | 9/9 |
| Prior selective batches | 33/36 | 20/36 | 9/9 |
| HNSW batches | 33/36 | 22/36 | 9/9 |

Within-batch median ratios; QPS improves above 1 and p95 below 1. Individual
trial gates remain authoritative.

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.964 | 0.968 | 1.023 | 0.945 |
| uniform-128 | correlated | 0.965 | 1.003 | 0.977 | 1.001 |
| uniform-128 | independent | 0.908 | 1.319 | 0.990 | 0.999 |
| uniform-128 | selective | 0.925 | 0.933 | 1.157 | 0.959 |
| uniform-1536 | all | 1.010 | 1.009 | 1.015 | 0.982 |
| uniform-1536 | correlated | 0.993 | 1.024 | 1.017 | 0.992 |
| uniform-1536 | independent | 0.989 | 1.023 | 1.005 | 1.014 |
| uniform-1536 | selective | 0.876 | 1.072 | 0.909 | 0.977 |
| real-1536 | all | 1.004 | 0.955 | 1.001 | 1.005 |
| real-1536 | correlated | 1.005 | 1.060 | 1.009 | 1.052 |
| real-1536 | independent | 0.980 | 1.040 | 1.057 | 0.657 |
| real-1536 | selective | 0.910 | 0.970 | 0.912 | 1.006 |

The production pass-to-fail cells are uniform-128 trial 1 independent and
uniform-1536 trial 2 selective. No prior-candidate pass becomes a failure in
this batch, but that does not waive the low-dimensional stage regressions or
production failures. The correct same-batch prior count is 20/36, not the
historical 21/36. Combined write-plus-flush is the durability-relevant comparison;
raw update-call timings have different durability semantics.

## Remaining work and evidence

Keep this candidate isolated. Next test whether matching Qdrant's fixed local
batch storage can remove the observed low-dimensional overhead, retaining the
same source/eligibility checks, borrow lifetimes, error ordering and score pairs.
Continue treating publication waits and the remaining ANN core as separate
costs. Full warm/concurrent performance, sustained nonresident capacity under
equal limits, integration/example and native Linux gates remain open. No
dimension-specific exception, threshold relaxation or M5/M6 completion is
claimed.

The [evidence archive](2026-10-20-immutable-point-hnsw-batch.json.gz) contains
complete candidate and both diagnostic sources, the implementation diff, new
and inherited test sources, rejected sources/build logs, validation logs, all
36 mixed and 12 diagnostic reports/logs, phase/rerank traces, scripts, and six
pinned Qdrant files including LICENSE. Parent source/archive, native identities
and all embedded hashes are verified. Binaries and copied databases are excluded.
The archive contains **853 text artifacts, 3,222,242 compressed bytes**, SHA-256
`311635bcfc53d71a26b03f19fbae4eee259481857514b4975e4b45041b22d050`.
