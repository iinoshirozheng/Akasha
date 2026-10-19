# Bounded borrowed-row batches for selective exact scoring

The isolated candidate now gathers up to 64 borrowed dense rows before scoring,
following Qdrant's storage/scorer boundary. In balanced diagnostic pairs,
selective core medians decrease by 6.4%, 11.0% and 11.6% across the three corpora.
The uninstrumented comparison still has one prior-candidate pass-to-fail cell;
the optimization remains isolated and is not adopted into production. Fresh
strict quality-plus-speed results are **24/36 production, 20/36 prior candidate
and 21/36 batch candidate**. Production remains `a6822c3`; M5/M6 remain open.

## Reference and implementation

This extends the [paired query-phase diagnosis](2026-10-20-immutable-point-query-phases.md)
and uses the verified [owner-capture source](2026-10-20-immutable-point-owner-capture.md)
as its implementation base. The pinned Qdrant reference is
`21db2f3ff95d50de3a2b88a741312c056fd1762d`:

- [`ImmutableDenseVectorData::for_each_in_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/dense/immutable_dense_vectors.rs)
  gathers row views before invoking the scorer.
- [`VECTOR_READ_BATCH_SIZE`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/common.rs)
  is 64. The candidate uses the same maximum, represented as 32 score pairs.
- [`MetricQueryScorer::score_stored_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/query_scorer/metric_query_scorer.rs)
  keeps the query and storage borrow outside individual scores.

Exactly two source files differ from the owner-capture base. The collection's
selective `_search_candidates` branch calls the new `query/dense_scoring.mojo`
helper instead of interleaving every pair's acquisition and arithmetic. Full
sequential scans retain their existing row loop. HNSW traversal and authoritative
reranking are unchanged. The fixed batch is internal, not a new configuration.

The helper establishes the first valid nested reader borrow before constructing
a reusable bounded List. The compiler accepts later row borrows with that same
nested origin; there are no owner clones, numeric copies or new untracked-origin
casts. Each record retains one original score pair, or one single row when the
old loop encounters an absent second dense field. This preserves pair grouping,
ordinal order, F32 arithmetic, tie handling and missing-field behavior.

A later acquisition error is retained while earlier completed pairs are scored.
It is raised afterward unless an earlier pair itself raises, preserving native
error precedence. Partial pairs are never added. The table remains immutably
borrowed for the whole synchronous operation, under the existing collection
lock. No persisted format, point mutation, compaction selection, threshold, ef,
query statistics or public getter contract changes.

The first compiler probe could not convert nested origins into the enclosing
table origin. Establishing the existing nested borrow first succeeds without
casting that rejection away. Initial scaffolding also needed the required
MemTable/TopK constructor arguments, and the generic pair record needed an
explicit Deinitable bound. Original sources and compiler logs remain archived.
The [live Mojo origin documentation](https://mojolang.org/docs/manual/values/lifetimes/)
was consulted; it identifies version 1.1.0, while the installed **Mojo 1.0.0
(ed45d567)** compiler is the compatibility authority for this implementation.

## Validation

- **68 CPU cases in 10 modules**: 67 in the selected query matrix plus one
  mapped-row case. The preceding narrow three-case invocation is not counted
  again. Tests cover all three metrics, multiple dimensions, ties, batch tails,
  absent dense fields, and earlier score errors versus later acquisition errors.
- The mapped-row case mixes 129 unaligned mapped rows with an owned row, checks
  every score against the old loop, then replaces a live row. Retained old data
  stays valid and mapped public List caches remain empty until explicitly read.
- **379 Python cases**, with the exact candidate library SHA-256 verified in
  four launcher processes. Repository-source probes still inspect repository
  source; these are distinguished from candidate-library execution.
- **Candidate C ABI** library build, strict C11 compilation and execution pass.
- All builds/tests use the frozen 131-file source inventory. Persistence and GPU
  implementation are unchanged; no fresh crash or actual-device GPU run is
  claimed for this query-only layer.

Python native SHA-256:
`4e248eb871d75738ac0f12856faa74c7414b7a9130ae4a7e806ccfaa43cad1f8`.
C native SHA-256:
`1d5287d990b4edf372883f778f702b6043875af2d0721faf072d6f6596d497a6`.

## Balanced query-core diagnosis

The previous candidate's verified diagnostic binary is reused without rebuild.
The new candidate is instrumented at the identical phase boundaries. Twelve
serial workers run prior/batch then batch/prior for each corpus. All **3,456
timed responses, 12 exact reopens and 12 Arrow leases** match the frozen
uninstrumented responses. All 36 explicit warmups remain separately recorded;
no timed samples are dropped and no query changes route or falls back.

Selective core microseconds, reporting the median of two trial medians:

| Corpus | Prior core µs | Batch core µs | Reduction | Prior total wait µs | Batch total wait µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 23.50 | 22.00 | 6.4% | 1255 | 2330 |
| uniform-1536 | 81.50 | 72.50 | 11.0% | 1761 | 1757 |
| real-1536 | 88.50 | 78.25 | 11.6% | 607 | 1142 |

Both individual trial medians decrease for every selective corpus. Wait totals
cover all 144 timed selective queries per variant/corpus. The batch still shares
the writer lock with publication: core savings coexist with publication delays.
These instrumented timings do not prove the cause of any separate uninstrumented
tail or establish an end-to-end speed gate. Observed clock resolution is 1 µs;
zero phase medians do not mean zero work. All twelve mode groups and raw phase
traces remain in the archive.

## Fixed uninstrumented comparison

Thirty-six serial workers compare production, the prior owner-capture candidate,
this candidate and native Qdrant Edge 0.8.0 across three corpora and three trials.
Order rotates through three of four rotations and is not fully balanced. Frozen
plans, seeds, ef, oracles, nine reads/eight-point upsert/flush blocks and strict
per-cell requirements are unchanged. No builds, tests, profiling or compression
overlap timed workers.

All **10,368 responses, 36 exact reopens and 27 Akasha Arrow leases** pass their
audits. Akasha variants match exact IDs, F32 bits, statistics and execution
decisions, and meet all 36 recall cells. Matched quality remains 33/36 because
Qdrant's three real-correlated cells retain recall .945833 versus Akasha's
.980556. They remain failed, with no exclusions or ef retuning.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 24/36 | 9/9 |
| Prior owner capture | 33/36 | 20/36 | 9/9 |
| Borrowed batches | 33/36 | 21/36 | 9/9 |

Within-batch median ratios; QPS improves above 1, p95 below 1. These summaries
do not replace individual trial gates:

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.977 | 0.978 | 1.006 | 0.994 |
| uniform-128 | correlated | 0.967 | 0.982 | 0.979 | 1.019 |
| uniform-128 | independent | 0.957 | 1.030 | 0.997 | 0.947 |
| uniform-128 | selective | 0.787 | 1.033 | 0.910 | 0.952 |
| uniform-1536 | all | 0.997 | 0.993 | 1.009 | 0.972 |
| uniform-1536 | correlated | 0.985 | 1.017 | 0.998 | 0.955 |
| uniform-1536 | independent | 0.978 | 1.104 | 0.992 | 0.988 |
| uniform-1536 | selective | 0.835 | 1.083 | 0.975 | 1.009 |
| real-1536 | all | 0.994 | 0.985 | 1.001 | 0.980 |
| real-1536 | correlated | 0.993 | 1.005 | 0.979 | 1.038 |
| real-1536 | independent | 0.963 | 0.982 | 1.004 | 0.933 |
| real-1536 | selective | 0.997 | 0.821 | 1.065 | 0.970 |

Three production pass-to-fail cells remain: uniform-128 trial 0 correlated,
and uniform-1536 trials 1 and 2 selective. The prior-candidate pass-to-fail is
uniform-1536 trial 2 selective. These regressions are not offset by the extra
passes. Historical batches remain separate; the proper same-batch prior count
is 20/36, not the previous report's 16/36. Combined write-plus-flush remains the
durability-relevant comparison; raw update calls have different durability
semantics. This resident serial run does not close sustained maintenance,
concurrent-client or nonresident capacity acceptance.

## Remaining work and evidence

Carry the bounded gather into subsequent isolated work because its intended
core cost decreases in both balanced trials while preserving exact behavior.
The remaining HNSW core paths still use the prior acquisition/scoring loop.
Next inspect the pinned batch scorer boundary for authoritative HNSW reranking,
preserving lookup counters, source/eligibility checks and error ordering. Keep
publication wait costs separately visible. Full warm/concurrent speed, sustained
nonresident capacity under equal limits, integration/example and native Linux
gates remain open; no production adoption or M5/M6 completion is claimed.

The [evidence archive](2026-10-20-immutable-point-batch-score.json.gz) contains
the complete candidate and diagnostic source, implementation diff, new and
inherited test sources, rejected probes, all validation logs, all 36 mixed and
12 diagnostic reports/logs, phase traces, script inputs and six pinned Qdrant
files including LICENSE. The reused diagnostic binary/source and frozen plans
remain hash-linked through the parent archive. All embedded hashes, native
identities and parent sources/archive are verified; binaries and copied
databases are excluded.
The archive contains 715 text artifacts, 2,907,207 compressed bytes,
SHA-256 `160c2339e1ae4d7a75db668eab1ca918301f3a249ad60914a2e766160c2fa689`.
