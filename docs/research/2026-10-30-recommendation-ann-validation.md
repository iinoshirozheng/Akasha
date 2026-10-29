# Q02c dense recommendation ANN validation

Date: 2026-10-30. Starts at `e034038`; Mojo `1.0.0 (ed45d567)`, macOS ARM64.
Dense HNSW recommendation is implemented through Mojo, Python and Arrow.
Q02 and the full feature plan remain in progress. No performance tuning or
benchmark acceptance was performed.

## Source and execution

The scoring boundary follows Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:

- `vector_storage/query_scorer/custom_query_scorer.rs`: prepare the composite
  query once and score each stored candidate against its examples.
- `index/hnsw_index/point_scorer.rs`: admit/filter candidates before scoring.
- `index/hnsw_index/graph_layers.rs`: pass the scorer through upper descent and
  layer traversal; recommendation scoring is independent of graph topology.
- `vector_storage/query/reco_query.rs`: the previously ported best/sum reducers.

`HnswQueryScorer` replaces the internal dispatcher-plus-query arguments.
`MetricPointScorer` preserves existing nearest-vector scalar/four-row kernels.
`PreparedRecommendation` shares the exact path's preprocessing/reducers with
`RecommendationPointScorer`; its negated similarity fits Akasha's distance heap.
Best/sum use their actual examples during graph traversal, not an averaged
nearest-vector surrogate. Average-vector L2 postprocessing happens after merging
per-run results; custom L2 scores retain negative squared-distance semantics.

The graph still uses its configured native field metric for construction.
Recommendation scores read authoritative native field values through retained
run/graph/query owners. Exclusions, payload filters and shadowed-row visibility
apply before admission. Each run's graph is queried under its existing lock.
Small/selective plans and insufficient-result fallbacks report their exact path;
a full result count does not imply exact recall. Deadlines/cancellation also
cover candidate admission scans and individual example scoring.

Existing traversal derives from Qdrant Edge
`21db2f3ff95d50de3a2b88a741312c056fd1762d`, with separately documented bounded
upper-layer seed reuse. This is not a claim that the entire traversal has been
replaced with v1.19.0. See [traversal provenance](../../benchmarks/mojo/qdrant_search_reference.md).
Per-file source/target hashes and adaptations are in `docs/upstream/ports.json`.

## Independent scoring and preserved quality failure

The 132 valid dense cases from the existing 14-function unedited Rust oracle
are each expanded to 112 candidates, exceeding the planner's exact threshold.
Tests require `recommendation_hnsw`, nonzero graph visits, no fallback, and the
source's expected IDs/scores for all three strategies, Dot/L2/cosine, and raw/ID
examples with differing source/target metrics.

These integration fixtures explicitly use `m=m0=ef_construction=128`, `ef=128`
so every candidate is reachable. This validates scoring and traversal wiring;
it is neither a recall acceptance run nor a change to production parameters.

The first run used the default graph (`m=16`, `m0=32`). It produced **148 passes
and one failure**. Source fixture case 12, repeated 16 times, requested `k=10`,
`ef=128` (effective 112), but visited only 105 base nodes. Exact IDs were
`[1,8,15,22,29,36,43,50,57,64]`; ANN returned
`[1,8,15,22,29,36,43,50,106,5]`. Nine ANN scores equaled the optimal
`5.645833969116211`; the last was `4.625000476837158`.

Returned-node scoring agreed with the source. The graph did not reach all
repeated candidates. ID overlap was 0.8; because tied IDs are interchangeable
for score quality, this is recorded separately from the 9/10 optimal-score
count. Neither measure passes an acceptance gate here. The full diagnostic is
preserved in `tests/fixtures/qdrant-recommendation/ann-duplicate-diagnostic.json`.
Production parameters, historical thresholds and failed records are unchanged.
This remains open under Q02/P01; no recall improvement is claimed.

The other ANN tests keep default graph configuration and cover five native
datatypes across all strategies, flush/reopen, shadowed/deleted rows, source-ID
updates/exclusion, filters, Arrow lifetime, and exact-vs-ANN results. A two-peak
L2 case distinguishes best-score traversal from averaged nearest search.
Bounds, empty/small/selective plans, cancellation and deadlines are checked.

## Validation

All heavy steps ran serially. Final Python bindings were rebuilt after the
execution-control changes.

```sh
rtk proxy pixi run build-python
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_recommendation.py tests/python/test_recommendation_ann.py \
  tests/python/test_point_query.py tests/python/test_weighted_rrf.py \
  tests/python/test_score_fusion.py tests/python/test_named_vectors.py \
  tests/python/test_field_ivf.py tests/python/test_field_rerank.py \
  tests/python/test_binding_conversion_close.py tests/python/test_operations.py -q
rtk proxy pixi run python -m benchmarks.qdrant_search_reference \
  --output .build/recommendation-ann-validation/source-traversal
rtk proxy git diff --check
```

- **952 distinct Python cases passed**, including 149 ANN cases. Two existing
  `__module__` deprecation warnings remain.
- **72 native cases across 11 modules passed** using
  `rtk proxy pixi run mojo run -I src <file>`: `test_recommendation_ann`,
  `test_hnsw_search_layer`, `test_hnsw_query_boundaries`, `test_hnsw_widening`,
  `test_hnsw_view`, `test_hnsw_control`, `test_hnsw_quantized`,
  `test_hnsw_payload`, `test_qdrant_hnsw_build`, `test_hnsw_live_radius`
  under `tests/mojo/`, plus `benchmarks/mojo/test_qdrant_search_reference.mojo`.
  The native recommendation test retains a snapshot after its writer closes.
  Earlier in this change, `test_hnsw_four_distance` (3 cases) and
  `test_recommendation` (5 cases) also passed; these are not added to the 72.
- **98 independent Rust/Mojo traversal fixtures passed**. These compare the
  existing single-entry primitives on distinct-score graphs, not full server
  behavior, custom recommendation graph topology or seeded-query equivalence.
- Initial native validation found misplaced module docstrings and unmigrated
  reference-test calls after the scorer-signature change. These were corrected
  and the affected modules passed on rerun. Logs and initial failures are under
  `.build/recommendation-ann-validation/`.
- The historical `hnsw_prefetch_bench.mojo` adapter was migrated to the scorer
  signature and current graph-access callbacks, and compiled with
  `rtk proxy pixi run mojo build -I src benchmarks/mojo/hnsw_prefetch_bench.mojo -o .build/recommendation-ann-validation/hnsw-prefetch-compile-only`.
  Its initial compile exposed a misplaced docstring and missing forwarding
  methods; both were corrected. The experiment was **not executed** and its
  historical performance results are not revalidated.

There is no durable schema/WAL/publication change, so crash tests were not rerun.
GPU kernels did not change. Native Linux acceptance remains deferred.

## Required continuation

Sparse/multivector indexed recommendation, full F16/U8 independent oracle and
SIMD/large-dimension cases, canonical low-precision storage/source behavior,
universal-query/prefetch and C/REST/gRPC exposure remain open. BF16/I8 are native
extensions. Query-time normalization cannot recover the original pre-ingestion
F32 value from rounded low-precision authority. The recorded recall diagnostic
and all historical M5/M6 failures remain unaccepted; functionality work continues
before performance optimization.
