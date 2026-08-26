# Phase 12 benchmark evidence

Run from the repository root:

```bash
pixi run bench-phase12
```

The committed harness uses deterministic 16-dimensional fixtures and fails
unless SQ8 recall@10 is at least 0.80, compact PQ recall@10 is at least 0.70,
parallel exact IDs/scores match scalar execution, full-candidate exact rerank
matches the scalar oracle, and warm/cold reopen queries agree.

One local Apple Silicon development run on 2026-08-26 measured:

| Workload | Recall@10 | QPS | p95 | Build | Estimated bytes |
|---|---:|---:|---:|---:|---:|
| SQ8, 1K × 16D | 1.00 | 21,209 | 49 µs | 0.475 ms | 24,128 |
| PQ 4×16, 1K × 16D | 0.77 | 34,364 | 30 µs | 3.722 ms | 13,024 |

The same run measured 24 µs for a 256-point scalar exact query, 1.643 ms for
the parallel path at this intentionally small size, 0.828 ms for warm
cache-backed reopen plus HNSW query, and 2.010 ms for cold rebuild plus query.
The small parallel result documents the crossover cost: the planner or caller
should retain scalar execution for small candidate sets.

These values are development-machine observations, not portable performance
guarantees. Recall and differential-correctness thresholds are the committed
gates.
