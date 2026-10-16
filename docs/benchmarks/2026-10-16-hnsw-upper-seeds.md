# Bounded reuse of scored upper-layer candidates

The fixed quality gate now passes without changing its data, level seed, ef,
threshold or graph construction: L2 228/240 = **0.95**, Dot 229/240 =
**0.9541666667**, cosine 230/240 = **0.9583333333**. Construction distance growth
is **3.4405554**, below 3.5. This macOS ARM64 quality result does not establish
complete Qdrant performance or platform parity.

## Cause and implementation

The earlier fixed-L2 diagnosis found that the 13 missing nearest neighbors were
reachable but never scored at ef=64. Greedy upper descent scores several useful
candidates, then used to discard all except its final entry before the base
search. Query descent now retains the best unique candidates scored on the
last upper layer and initializes one shared base frontier from them. Retention
is bounded by `min(effective_ef, graph slots)`; initialization does not enlarge
ef or perform more upper distance calculations. Base traversal marks reused
seeds visited and therefore does not score them again.

The pattern is informed by Faiss `search_level_0_impl`, `search_type == 2`, at
commit `613e0acac507c7593ff14dee2c6204a83a539acb`. Faiss permits raising the queue
size to the number of probes; Akasha instead bounds the number of seeds by the
existing ef. No Faiss source is copied. Qdrant-derived single-entry primitives
remain in construction. This query optimization is an explicit algorithmic
adaptation after source alignment, not a claim of step-for-step Qdrant query
equivalence.

Owned, mapped and segmented/widening queries use the same bounded initialization.
Widening reuses the captured seeds and prepared query rather than repeating the
descent. No durable graph/vector format changes. Invalid seed bounds, levels
or eligibility fail before base scratch or counters change. Cancellation and
checked graph access remain. Base-visit counters include reused seeds; distance
counters count actual evaluations, so visits no longer imply one distance call
per base point.

The quality test also fixes its aggregation: summing 24 per-query Float64
recalls produced `0.9499999999999998` for 228/240. It now sums integer hit and
expected-result counts and divides once. Every query still has K=10, and the
literal 0.95 threshold is unchanged. The parent 227/240 still fails.

## Controlled quality/work experiment

The probe uses identical constructed graphs, 8192 points, 64 dimensions,
M=24/M0=48, efConstruction=192 and efSearch=64. Its mechanically copied
single-entry control matched the original production top-ten IDs, scores and
distance counts on all 1152 queries before integration. The candidate is capped
at 64 unique seeds. This diagnostic is not a timing comparison.

Each cell below contains 128 queries (1280 possible hits). Seeds are the fixed
`0xD1B54A32D192ED03`, `0xDEADBEEF` and `0x123456789ABCDEF0` in that order.

| Metric / seed | Parent hits | Seed reuse hits | Parent distances | Seed reuse distances |
| --- | ---: | ---: | ---: | ---: |
| L2 / fixed | 1226 | 1228 | 270710 | 267530 |
| L2 / DEADBEEF | 1211 | 1211 | 270881 | 267913 |
| L2 / 123456… | 1224 | 1223 | 270938 | 267877 |
| Dot / fixed | 1237 | 1239 | 279411 | 276186 |
| Dot / DEADBEEF | 1231 | 1231 | 279873 | 276727 |
| Dot / 123456… | 1233 | 1233 | 280107 | 276975 |
| Cosine / fixed | 1222 | 1223 | 279372 | 276133 |
| Cosine / DEADBEEF | 1221 | 1221 | 279845 | 276660 |
| Cosine / 123456… | 1234 | 1234 | 279493 | 276160 |

The net gain is four hits out of 11520, with one L2 cell regressing by one hit.
The L2 DEADBEEF cell remains below .95 for both implementations. These extra
seeds are diagnostics, not newly passing gates or a guarantee of monotonic
recall. For the fixed first 24 L2 queries, distance calls fall from 51032 to
50376 while hits increase from 227 to 228.

## Evidence scope

The source differential facade explicitly composes the unchanged single-entry
production primitives. It tests that retained construction traversal against
the pinned Qdrant source; it does not silently label the new multi-entry query
algorithm equivalent. Separate regression tests exercise seed bounds, duplicate
handling, filtering, invalid inputs, epoch wrap and discovery through another
base component without additional upper scoring.

Raw probe and integration artifacts are under
`.build/qdrant-alignment/upper-seed-probe` and
`.build/qdrant-alignment/upper-seed-reuse`.

## Saved-graph timing diagnostic

The initial sorted-seed implementation and the final unordered transfer each
received three serial alternating before/after pairs per corpus, with 31
passes per worker. Every saved-graph result digest and recall array matches
the parent in all twelve cells. ANN distance counts decrease by 0.46–0.83%.
These frozen Dot workloads do not measure the separate fixed-L2 improvement.

The final diagnostic additionally samples thread CPU time around each public
request/search; its extra clock calls are present on both sides. Neither
measurement set establishes a consistent speed improvement. Initial low-
dimensional regressions and unchanged exact-control variations are retained.
The two measurement sets are not paired against each other, so removing the
redundant seed sort is not assigned a measured speedup.

| Corpus / mode | Final QPS after/before | Final p95 after/before | Thread CPU after/before |
| --- | ---: | ---: | ---: |
| uniform-128 / all | 0.962 | 0.976 | 1.039 |
| uniform-128 / correlated | 0.996 | 1.010 | 1.004 |
| uniform-128 / independent | 1.011 | 0.951 | 0.990 |
| uniform-128 / selective | 1.005 | 0.993 | 0.995 |
| uniform-1536 / all | 1.055 | 0.930 | 0.961 |
| uniform-1536 / correlated | 1.026 | 0.980 | 0.977 |
| uniform-1536 / independent | 0.924 | 1.164 | 1.021 |
| uniform-1536 / selective | 0.947 | 1.069 | 1.012 |
| real-1536 / all | 0.986 | 1.010 | 1.014 |
| real-1536 / correlated | 1.018 | 0.984 | 0.982 |
| real-1536 / independent | 1.018 | 0.957 | 0.982 |
| real-1536 / selective | 1.005 | 1.004 | 0.995 |

Ratios are medians of the three paired ratios, not pass criteria; individual
trials and raw latency observations remain in the artifact. No test, build or
compression ran concurrently with timed workers. The low-dimensional all
median QPS regresses, and several controls also change direction. The quality
repair is not reported as a throughput optimization or as Qdrant acceptance.

Parent binary SHA-256:
`2342e619426448ed52498bb5d7eddb0bdbbe51f30ffb520f6a3b543be5c8d381`.
Sorted-seed intermediate:
`91169ba5d0c1195c2c4c6a3d977deb9fd5539e73a29e7313349dac56a052dce2`.
Final unordered-seed binary:
`358cb6212d9caa347fd6ef055aea45fc4f0052cde1f393c9bcfa92dcb3d339b1`.

## Full CPU validation

On Apple M4 Pro, macOS 26.5.2, Mojo 1.0.0 (`ed45d567`):

- All **152 Mojo test files / 1036 cases pass**, including the fixed quality
  suite, mapped/owned equivalence, compact metrics, cancellation, updates,
  persistence, publication, concurrency and leases.
- Final Python/distributed/service suite: **387 passed, one skipped**.
- Rebuilt C client, all three built examples and both HNSW quality smoke tasks
  pass. Post-HNSW smoke covers 11 metric/scalar cells and four filter modes.
- The standalone candidate and final production API match top-ten IDs, scores
  and distance counts on all 1152 probe queries. Unordered seed transfer also
  preserves every one of the 1170 diagnostic output rows.
- Single-entry Qdrant traversal primitives match all 98 fixtures on both scalar
  and batched F32 scoring paths; nine source-boundary cases pass.

Independent Mojo compilation used three compiler processes, followed by serial
test execution. The self-spawning file-retirement test requires its source path
as argv[0], so it was rerun with the documented `mojo run` invocation after the
precompiled-executable harness failed. No production fix was needed there.

The full suite also exposed two obsolete tests left by the earlier behavior
alignment: rejecting zero I8 cosine vectors, and applying the current sparse
validator to historical empty/zero-weight rejection rules. The tests now assert
zero cosine similarity and current empty/zero sparse acceptance, while retaining
nonzero normalization errors and the actual `validate_legacy_sparse` rules.
Only these test contracts changed; storage/format validation was not relaxed.
All failed attempts, including an assertion member-name compiler error and its
correction, are retained with the passing reruns and source hashes.

Formats, crash recovery and GPU implementation are unchanged; their prior valid
evidence is retained rather than relabeled as fresh tests. Native Linux,
concurrent-client performance, sustained nonresident/type/capacity matrices and
strict warm/mixed Qdrant speed acceptance remain open. The last full native
comparison is the parent current-flag report (warm 4/36, mixed 13/36,
write+flush 5/9); these saved-graph diagnostics do not supersede it.

## Frozen evidence

[Probe sources, complete raw timings, validation logs and identities](results/2026-10-16-hnsw-upper-seeds.json.gz)
contain 513 files, 2,348,731 compressed bytes. Every embedded file hash was
verified after writing. Compiled libraries, saved graphs and datasets are
identified by hashes rather than embedded; saved workload specifications,
exact oracles and original ef-selection reports are included.

Archive SHA-256:
`c336cb3b0f6679af47192bb3065a04fff69217943a1fa2b92c57f4a7f1728a0d`.
