# Batched F32 scoring after Qdrant alignment

The Qdrant-derived scorer now uses Akasha's existing four-row F32 distance
kernel after filtering and capping its candidate buffer. This reduces repeated
query loads without changing candidate order, per-row reduction order, distance
counts or checked graph access. The saved-graph comparisons preserve every
result digest and query counter. Full performance acceptance remains failed.

## Evidence and implementation

After alignment commit `4e44f3c`, five-second macOS `sample` captures of the
public Python search path recorded 4,158 unfiltered and 4,184 correlated-filter
main-thread samples. The mapped single-row distance kernel accounted for 511
and 189 self samples respectively; scoring/admission, mapped metadata and heaps
also remain substantial. These are sampling observations, not exact elapsed
time attribution. Raw captures are in
`.build/qdrant-alignment/after-commit-profile/`.

Pinned Qdrant `point_scorer.rs::FilteredScorer::score_points` filters and caps
before passing a batch to its raw scorer; `metric_query_scorer.rs` delegates
batch reads to vector storage. Akasha's aligned traversal had retained only
single-row distance calls despite already owning a validated four-row kernel.
The change reconnects that kernel for complete F32 groups. Short tails and other
scalar types retain their existing distance kernels. No format, search breadth,
planner threshold, acceptance threshold or authoritative reranking rule changes.

The separate idea of replacing source-map `contains` plus indexing with
`Dict.get` was withdrawn after finding the prior
[rejected lookup experiment](2026-10-02-hnsw-lookup-probes.md). Its source-only
variant had regressed. This change does not repeat that implementation.

## Correctness

- Expanded four-row tests compare scorer output against single-row distance
  bits for Dot/L2/cosine, 14 dimensions, owned/mapped storage, filtered inputs,
  zero through eight admitted rows, batch caps, repeated IDs and buffer reuse.
  Existing invalid-row, query-shape and closed-mapping checks also pass.
- The extracted upstream traversal oracle now checks both scalar and batched
  F32 paths against all 98 fixtures, including distance counts. Its graph
  adapter is owned storage; mapped scoring is covered separately by the tests
  and saved-graph runs, not by an additional 98 mapped fixtures.
- Extracted construction still matches 24 fixtures and 2,467 ordered adjacency
  rows. Group ordering, search layers, cancellation, filtering, compact scalar
  paths and segmented base/delta tests pass: 57 tests across six files.
- The rebuilt Python extension passes 387 Python/distributed/service tests,
  with one skip. The rebuilt C library passes `pixi run test-c`.
  Earlier unaffected durable-format, crash and GPU validation
  remains applicable; this change does not claim new runs of those suites.

Logs: `.build/qdrant-source-reference/four-score-batch-2/`,
`.build/qdrant-source-reference/build-four-score-batch/` and
`.build/qdrant-alignment/four-score-batch/`.

## Saved-graph diagnostic

`benchmarks/qdrant_saved_graph.py` reopens each original acceptance trial-0
graph with its original workload, oracle and smallest passing ef. Every process
warms all queries, then measures seven repetitions through the public Python
binding. Per corpus, old/new/old and new/old/new processes ran serially, with
no simultaneous builds or tests. All 24 cell comparisons preserve result
digests, recall values and every recorded query counter.

The 1536D ANN QPS ratios improve in both orders: 1.122–1.412 for uniform data
and 1.092–1.317 for real data in old/new/old; 1.095–1.341 and 1.021–1.194 in
new/old/new. All corresponding p95 ratios improve. The 128D ANN QPS ratios
range from .931–.985 in the first order and 1.006–1.048 in the reverse order;
this does not establish a stable low-dimensional improvement. Exact controls
also vary even though they do not invoke the changed kernel. Slow samples and
regressions remain in `aba-summary.json`, `bab-summary.json` and the raw reports.

Baseline native binary SHA-256:
`0c52ecf86d20ff4119f44b1df7761b1c37804784ca03fe697e92a2df16f20a41`.
Candidate:
`b331c3e38773160ed94ac4cc5df7428bd9bcf4b542fa3973d54f14264ea02c87`.

These diagnostics isolate retained graph queries; they are separate from the
fresh-build comparison with Qdrant.

## Fresh Qdrant acceptance

Three fresh serial trials per corpus, alternating engine order, pass matched
recall in **36/36** cells. Only **6/36** pass both QPS >= Qdrant and p95 <=
Qdrant; overall acceptance is **FAILED**. The fixed workload remains 8,192
points, 64 queries, k=10, seed=12345, Dot/F32 and the symmetric ef grid
`10,16,24,32,40,48,64,96,128,256,512,1024`. Each engine selects its smallest
passing ef without using timing to select it. Both build and reopen workers
complete successfully. All three corpus runners exit 1 for the failed speed
gate, rather than an execution error.

| Corpus | Filter | Median QPS A/Q | Median p95 A/Q | Passing trials |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 0.502 | 1.962 | 0/3 |
| uniform-128 | correlated | 0.433 | 1.944 | 0/3 |
| uniform-128 | independent | 0.440 | 2.018 | 0/3 |
| uniform-128 | selective | 0.831 | 1.463 | 1/3 |
| uniform-1536 | all | 0.954 | 1.026 | 1/3 |
| uniform-1536 | correlated | 0.629 | 1.551 | 0/3 |
| uniform-1536 | independent | 0.671 | 1.425 | 0/3 |
| uniform-1536 | selective | 1.294 | 0.837 | 2/3 |
| real-1536 | all | 0.981 | 0.936 | 1/3 |
| real-1536 | correlated | 0.370 | 2.443 | 0/3 |
| real-1536 | independent | 0.633 | 1.424 | 0/3 |
| real-1536 | selective | 0.976 | 0.877 | 1/3 |

All filtered ANN cells still fail speed parity. The previous full matrix passed
3/36 speed cells; that run used an earlier binary and was not interleaved with
this one. The 3-to-6 count is therefore a new acceptance snapshot, not an
isolated causal estimate of this patch. In particular, selective exact cells
do not use the new kernel, and 128D selective passes decrease from two to one.
Neither medians nor improvements elsewhere waive an individual failure.

The OS page cache remained present. This macOS ARM64 resident run does not
replace lifecycle/concurrent/non-resident/type matrices or native Linux
evidence. Run directory:
`.build/qdrant-alignment/four-score-batch/warm-matrix/`. `runs.json` preserves
the full commands; `acceptance-summary.json` and each corpus `report.json`
preserve the aggregate and individual results.

The fixed quality suite was rerun after timing completed: Dot .9541666667,
L2 .9458333333 and cosine .9583333333; subquadratic construction also passes.
L2 alone still fails the unchanged .95 gate. Its previous native Qdrant
reproduction does not waive this failure. This is a verified scoring-cost
optimization, not completion of the outstanding quality or M5/M6 requirements.

[Raw reports, timings, profiles, validation logs and source patch](results/2026-10-16-qdrant-score-batch.json.gz)
(3,381,471 bytes; SHA-256
`1aae473ca184e9fd02d095945cdf3176c37ad855897b54499bf92db0dbeb9b87`).
