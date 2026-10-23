# HNSW query validation and measurement controls — 2026-10-03

Repeated prepared-query checks are real, but the isolated reuse candidate did
not establish a stable public performance benefit. **It was not adopted.**
Production source and Python binary remain at `a710aa5` / `3ccdc28…`. Two public
boundary regression tests are retained. M5/M6 remains incomplete.

## Measured work and the isolated candidate

The previous main-thread profile attributed 277/4,159 samples (6.7%) to metric
finite/norm checks combined. That includes necessary work and is not a measure
of redundant checks alone.

An instrumented copy of the binding traced the first frozen query in each
selected mode. Query and result markers separate reopen/build activity:

| Real 1536D mode | Finite/bound checks | Stable norms | Prepared-value checks | Layer boundaries |
|---|---:|---:|---:|---:|
| all | 9 | 10 | 8 | 6 |
| correlated | 6 | 7 | 5 | 3 |
| independent | 6 | 7 | 5 | 3 |
| selective (planned exact) | 0 | 0 | 0 | 0 |

These are counts for representative queries, not counts for every query or
widening shape. Selective uses the separate checked exact kernel; its zero
entries do **not** mean it omits validation. Uniform-128 all is also planned exact.

A separate uninstrumented Mojo diagnostic repeatedly validates the prepared
frozen real queries: seven passes of 100,000 calls give 2,391.51 / 2,205.99 /
2,210.82 / 2,245.02 / 2,270.34 / 2,189.57 / 2,201.52 ns per call. This includes
the diagnostic call overhead and is not a measured public query saving.

The candidate changes only `hnsw_core.mojo`. The enclosing widening function
already validates the prepared query before any loop; private implementations
reuse that result across layers/rounds. Public `greedy_descent` and `search_layer`
retain full numeric validation. Graph readiness, dispatcher identity, dimensions,
entry, level, adjacency, admission and demand checks remain. Arithmetic, candidate
order, distance counts, persistent formats, caches and public APIs do not change.
No prepared-query type, owner, cache, pointer or persistent state is added.

Local Qdrant `74f3e85` was consulted: `MetricQueryScorer::new` preprocesses once
and graph-layer search reuses the scorer. Akasha's lower-level public functions
still accept arbitrary vectors, so those public checks cannot simply disappear.

## Public comparison

Three rotating serial baseline/candidate/Qdrant trials per original frozen
corpus, fixed ef/seed/filter/K/binding boundary. All samples retained. Build,
tests and archive compression never overlap benchmark execution. Recall@10 ≥
.95, QPS ≥ Qdrant and p95 ≤ Qdrant are required in every cell.

| Experiment | Baseline strict pass | Candidate/repeat strict pass | Quality |
|---|---:|---:|---|
| Validation reuse, warm | 19/36 | 17/36 | 108 quality cells; 6,912 timed audits; 7,236 exact checks |
| Validation reuse, mixed | 32/36 | 30/36 | 108 quality cells; 7,776 audits; 27 reopen checks; 18 leases |
| Same-source rebuild, warm A/A | 17/36 | 17/36 | 108 quality cells; 6,912 audits; 7,236 exact checks |
| Identical binary/package, warm A/A | 18/36 | 15/36 | 108 quality cells; 6,912 audits; 7,236 exact checks |

Every quality cell passes. Warm IDs, Float32 score bits, first query, warmups,
execution and stats match; mixed IDs and score bits match. Each speed assessment
fails correctly. Rows are separate experiments and cannot be combined into an
acceptance run. No failed trial is excluded.

Validation-reuse warm candidate/baseline ratios, trials 0 / 1 / 2:

| Corpus | Filter | QPS ratios (higher better) | p95 ratios (lower better) |
|---|---|---|---|
| uniform-128 | all | 1.152 / 0.862 / 0.897 | 0.731 / 1.555 / 1.211 |
| uniform-128 | correlated | 1.106 / 0.427 / 0.923 | 0.491 / 3.243 / 1.062 |
| uniform-128 | independent | 0.839 / 0.450 / 0.962 | 1.246 / 2.950 / 1.108 |
| uniform-128 | selective | 1.121 / 0.801 / 0.930 | 0.838 / 1.077 / 1.086 |
| uniform-1536 | all | 0.913 / 1.061 / 1.032 | 1.140 / 0.889 / 0.908 |
| uniform-1536 | correlated | 0.996 / 1.015 / 1.030 | 1.016 / 0.997 / 0.944 |
| uniform-1536 | independent | 1.015 / 0.971 / 0.962 | 0.982 / 1.023 / 1.269 |
| uniform-1536 | selective | 1.135 / 0.993 / 0.945 | 0.850 / 1.006 / 1.221 |
| real-1536 | all | 0.986 / 1.028 / 1.155 | 1.020 / 0.950 / 0.863 |
| real-1536 | correlated | 1.067 / 0.957 / 0.965 | 0.955 / 1.063 / 1.023 |
| real-1536 | independent | 1.011 / 0.969 / 0.961 | 0.976 / 1.006 / 1.006 |
| real-1536 | selective | 1.021 / 0.973 / 0.938 | 0.996 / 1.091 / 1.167 |

The affected real ANN cells do not show a consistent improvement. Warm also
has three pass→fail exact control cells; mixed has two. In mixed uniform-1536
correlated, candidate/baseline p95 ratios are 2.177 / 1.382 / 1.384 although its
exact kernel source did not change. Qdrant itself has very slow mixed trials,
including a selective QPS ratio of about 17; those remain in the evidence.
No causal attribution follows from these observations alone.

## Why add A/A controls

Both explicit and default host compiler targets resolve to Apple M4 / Metal:4
with the same features. The source-identical rebuild has the same binary size
(4,558,008 bytes) but a different hash. All 1,361 matching text symbols move by
exactly +64 bytes; text/relocation sections differ. This is not evidence of a
compiler regression or an optimization.

The stronger control uses the **same saved Python package path and the same
frozen binary hash for both labels**. It still yields 128D independent p95
ratios 1.125 / 1.564 / 2.187, and selective 1.305 / 1.237 / 2.158. All three
128D selective cells move from pass to fail. Thus a per-trial regression alone
cannot identify the cause of the difference. This does not excuse any failed
gate, prove previous candidates safe to adopt, or establish that all variation
is noise. The validation candidate remains unadopted because its public benefit
is not established; strict Qdrant parity is still required.

## GC diagnostic, without changing policy

Six serial instrumented workers use the frozen baseline and Qdrant, original
selected efs and closed database clones. GC stays enabled at its existing
thresholds. A callback and preallocated numeric arrays record GC/query intervals;
these instrumented timings are diagnostic and do not replace acceptance samples.

Each Akasha corpus has five timed queries overlapping GC; Qdrant has none in
this diagnostic. Overlap sums are 121,624 / 193,667 / 182,917 ns for uniform-128 /
uniform-1536 / real-1536. Individual overlaps are approximately 13–52 µs.
Selective queries include two overlaps in each corpus. Many slowest samples,
including most broad/ANN tails, have **no** overlapping GC. Consequently GC is
one contributor, not an explanation for the whole performance gap. No samples
are removed, no adjusted latency is used for the gate, and GC is not disabled.

## Validation and reproduction

Candidate: **141 existing targeted Mojo tests across 12 files + 2 new boundary
tests**, **355 complete Python tests**, no skips. The retained test file adds
valid-output coverage and passes its two cases on unchanged production source.
It protects nonfinite, unsafe-magnitude, dimension and cosine-unit-norm checks
at public layers and the widening entry before scratch/stats mutate.
No new full Mojo/crash/C ABI/examples pass is claimed; production never used
the prototype. Existing applicable production results remain valid.

```bash
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src tests/mojo/test_hnsw_query_boundaries.mojo
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/.build/2026-10-03-query-validation/after-python:$PWD:$PWD/.build/qdrant-compare/deps" python -m pytest tests/python -q -o pythonpath=
```

Use archived drivers with fresh output directories. The trace binary contains
logging and was never used for latency comparisons. The reusable candidate is
compiled from its own copied `after-src/bindings/python_module.mojo` entry.

Production/frozen binary SHA-256:
`3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`.
Rejected candidate:
`ca2f39c04ff3a0cb81c7222a42a71300b011b49a4dc06c4f0d71de21739788b6`.
Same-source rebuild:
`93f055baf704dd7aa921de237161ab99d04a5284974790f2721f091a8e1f4cc9`.

[Immutable archive](results/2026-10-03-query-validation.json.gz): 392 files,
22,093,513 bytes, SHA-256
`36849567cf1effbc83c15f51597727e15a318aabc383d0ab771f0b4674bc4baa`.
Contains all raw trials and assessments, GC intervals, instrumented sources,
changed prototype and baseline sources, tests, command drivers, compiler logs,
binary/source identities and frozen corpus/oracle hashes. No sustained
nonresident, controlled-memory, concurrent-client, native Linux, ASan or GPU
device gate is completed by this work.
