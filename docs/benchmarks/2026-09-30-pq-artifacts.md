# #55: Root-owned PQ training artifacts

Date: 2026-09-30. Source: the #55 changes on top of `9c4fa71`, committed with this
report. Apple M4 Pro, macOS arm64, Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implementation and evidence

The root owns a synchronized official Dict of training configurations; the key is
`(subquantizers, centroids, iterations)`. Root ownership fixes field/config/layout
and coverage. The existing initializer deterministically selects evenly spaced
training rows and has no seed argument. Metrics and query result counts do not
affect training. Each key uses #54's `ArtifactState` and a separate build lock;
only a complete, uncancelled artifact can become ready. A query copies its owner
and searches outside the build lock. Failures retain other ready configurations
and roots, and the failed key can be retried.

Reference checked: local Faiss `faiss/IndexPQ.cpp`, `IndexPQ::train` and `search`
(training completes before `is_trained` is published; search requires trained
state). Existing Akasha PQ math, deterministic initialization and result ordering
are unchanged. Official Tuple/Dict APIs were checked against live documentation
and a compiler probe using the project's pinned 1.0.0, because live docs are 1.1.0.

Optional existing `QueryControl` now propagates through PQ gathering, training,
encoding, scoring and rerank. It checks candidate budgets, cancellation and
deadlines. A final checkpoint precedes artifact publication. Normal APIs keep
their prior signatures compatible through the optional keyword argument.

## Measurement

[`pq_artifact_bench.mojo`](../../benchmarks/mojo/pq_artifact_bench.mojo) measures
1,024 points × 32 dimensions with a fixed deterministic fixture. Three sequential
processes each run seven fresh roots/configuration and 64 warm queries/root.
Snapshot construction is outside timing. Cold time includes gather and build,
but not search. Warm time includes the public snapshot query, owner acquisition,
cache lookup and L2 Top-10. Oracle comparisons are outside timing; every warm
result has identical IDs and Float32 scores to a standalone `PqIndex.build`.

| Subquantizers / centroids / iterations | Median cold build | Median warm query | Artifact bytes |
| --- | ---: | ---: | ---: |
| 4 / 16 / 8 | 6,959 µs | 49.72 µs | 14,336 |
| 8 / 16 / 4 | 4,073 µs | 52.39 µs | 18,432 |

The warm column is the median of per-round mean query costs. Every one of the
42 root/configuration samples retained `build_count=1` after all queries.
These are cold-vs-warm costs, not a paired before/after speedup or a claim about
other dataset sizes. [Raw samples](results/2026-09-30-pq-artifacts.json).

Reproduce:

```sh
pixi run mojo build -I src benchmarks/mojo/pq_artifact_bench.mojo -o .build/pq-artifact-bench
.build/pq-artifact-bench
```

## Validation and limits

- `test_product_quantization.mojo`: 10 tests, including exact/raw-score oracle
  parity, every training-key parameter, metrics/k/rerank reuse, old/new/layout
  roots, failure/retry, handle/collection close, eight concurrent callers across
  two configurations, invalid/empty inputs, and cancellation during build/training.
- `test_quantized_search.mojo`: 8 SQ8/shared-helper regressions.
- `test_query_control.mojo`: 2 control regressions.
- `test_snapshot.mojo`: 10 snapshot ownership/isolation regressions.
- `test_generation_close.mojo`: 5 operation/GPU-owner CPU regressions.
- `pixi run bench-phase12`: SQ8 Recall@10 1.0, PQ 0.77 (existing 0.80/0.70
  gates), exact rerank/parallel oracle and warm/cold reopen passed. The benchmark
  initially failed on both the changed tree and archived `9c4fa71` because it
  required the obsolete HNSW cache instead of the current sidecar. A separate fix
  verifies the sidecar hit, removes that sidecar for the cold case, and compares
  all returned IDs and scores.

No persistent format or GPU execution path changed. This slice does not claim a
fresh full CPU/crash/C ABI/GPU gate; prior unchanged results remain recorded in
the checklist. PQ artifact memory grows with distinct configurations on each live
root; there is no eviction. Same-key callers wait for the builder's lock and
observe cancellation after acquiring it. The existing duplicate-ID check during
build is still quadratic; warm queries do not run it or copy training vectors.
