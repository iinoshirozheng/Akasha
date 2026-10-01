# Exact versus graph query cost

The previous planner considered collection size, filter fraction and readiness,
but ignored dimension, graph degree and requested ef. After the distance and
mapped-load improvements, exhaustive scanning wins several matched-recall cells.

`benchmarks/planner_cost.py` ran on each existing fixed post-mutation corpus:
8192 initial points, 10% replacements, 205 deletions, K=10, F32 authority/graph,
M=24/M0=48. Uniform 128D and 1536D use dot; real 1536D uses cosine. The paired
public Python requests alternate exact/approximate order, with three passes and
64 timed queries per mode/ef/pass. All oracles are calculated before timing.
No builds or tests ran concurrently. These are resident diagnostic measurements,
not fresh Qdrant trials. Exact results match the independent Float64 oracle.

Examples (QPS from reciprocal mean service time):

| Corpus / mode | ef | Exact | HNSW | HNSW recall |
| --- | ---: | ---: | ---: | ---: |
| Uniform 128D / all | 128 | 4526.61 | 2465.55 | 0.9875 |
| Uniform 1536D / all | 512 | 498.60 | 196.33 | 0.99375 |
| Uniform 1536D / correlated | 512 | 1207.61 | 194.73 | 0.98594 |
| Real 1536D / all | 32 | 321.79 | 2162.67 | 0.98906 |
| Real 1536D / correlated | 64 | 874.72 | 1169.47 | 0.98125 |
| Real 1536D / correlated | 256 | 871.03 | 460.84 | 1.0 |

Every failed-recall cell remains in the raw output and has no speed-ratio field.
The full 72 cells contain latency samples, ANN counters, source/binary hashes,
parameters and workload checksums:
[128D](results/2026-10-01-planner-cost-128.json.gz),
[1536D](results/2026-10-01-planner-cost-1536.json.gz),
[real 1536D](results/2026-10-01-planner-cost-real-1536.json.gz).

## Selected policy

Keep existing validation, small-collection, metric/readiness and selectivity
decisions first. For known dimensions >=128 and positive M0, compare deterministic
work estimates:

```
scan_work = matched_rows * dimension * (2 for cosine, otherwise 1)
graph_work = normalized_ef * (M0 / 3) * (dimension + 384)
```

Choose `scan_cost` when scan work is no larger. This is an empirical crossover
model, not a guarantee of graph visits or elapsed time. The fixed overhead term
accounts for graph traversal/heap work becoming relatively expensive at lower
dimensions. Cosine scans also calculate both norms; graph rows are normalized.
The coefficients were fixed from the paired diagnostics above before fresh
comparison trials. Short/unknown dimensions retain the existing policy. Float64
work arithmetic prevents integer-product overflow; normalized/capped ef is used.
No timing samples, query answer inspection or query-history state enter planning.

The filtered exact branch reuses the already evaluated eligibility bitmap under
the writer lock, avoiding a second filter evaluation. Scores still use the same
authoritative kernel, and the reason/storage counters expose the chosen scan.

Comparison reports now opt into `akasha_planner_policy=dimension-ef-v1` and count
`ann` versus `planned_exact` executions separately. A scan-cost cell requires
exact oracle agreement and exact storage labeling. Graph-unavailable, exhausted
or unknown fallbacks invalidate the speed comparison. Old reports retain their
original stricter policy and numbers; this change must not relabel old evidence.

## Verification and remaining measurement

Ten planner tests pass, including dimension/metric/degree changes, filter counts,
policy precedence, capped ef and maximum integer inputs. All 26 persistent HNSW
regressions pass. With the rebuilt extension, the 235 other Python tests pass;
the three new dot/L2/cosine tests pass after fixing their test-only context-manager
assumption (the collection exposes `close`, not `__enter__`). These cover public
scores, filters, mutation visibility, reopen and exact-plan counters.
Three fresh trials are now complete for uniform 128D/1536D and real 1536D. Every matched cell
passes recall 0.95, with Akasha using exact plans in the selected cells. QPS ratios
are Akasha/Qdrant, reported as median and full range across the three trials:

| Corpus | All | Correlated | Independent | Selective |
| --- | --- | --- | --- | --- |
| 128D | 0.657 (0.643–0.662) | 2.206 (2.008–2.242) | 2.329 (2.237–2.471) | 0.984 (0.533–1.082) |
| 1536D | 0.859 (0.849–0.877) | 1.062 (0.960–1.098) | 1.123 (1.076–1.130) | 0.677 (0.650–0.687) |
| Real 1536D | 0.525 (0.509–0.612) | 0.564 (0.557–0.582) | 0.342 (0.323–0.346) | 0.582 (0.571–0.584) |

Real-data selected all/correlated/independent cells use ANN with ef 32/32/64 and
recall 0.990625/0.953125/0.9859375; the selective cell uses an exact plan. The real
workload remains slower than Qdrant in every selected cell.

The slow third selective 128D trial is retained. Median ratios alone do not
establish uniform parity. Fresh-process 1536D open takes 1.997/2.014/2.074 seconds,
with the OS page cache still present. Raw reports preserve every trial, ef cell,
execution classification, lifecycle phase, memory/disk measurement and checksum:
[128D](results/2026-10-01-cost-plan-uniform-128.json.gz),
[1536D](results/2026-10-01-cost-plan-uniform-1536.json.gz),
[real 1536D](results/2026-10-01-cost-plan-real-1536.json.gz).

An additional finite-mask prototype reduced isolated 1536D validation from a
median 148.96 ns to 143.75 ns. This does not establish a meaningful complete-query
gain, so the production validator stays unchanged. All invalid lanes/tails passed;
short-vector samples show frequency warmup. Its complete paired timings are in
[the prototype result](results/2026-10-01-finite-mask.json).
