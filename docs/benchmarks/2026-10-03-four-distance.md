# Four-row F32 scoring and mixed-query lock waits — 2026-10-03

The isolated HNSW candidate improves every real-1536 warm ANN cell, but its
mixed run has four passing-to-failing cells. **It remains isolated, not promoted.**
Production source still matches `a710aa5`; Python binary remains `3ccdc28…`.
M5/M6 is incomplete. The follow-up investigation identifies background
compaction holding the writer lock as a cause of mixed-query tail latency.
This does not erase failed trials or establish that the candidate caused—or
could not cause—the changed maintenance/query overlap.

## Candidate and correctness

The [plan](../plans/2026-10-03-four-distance.md) uses four independent F32 row
accumulators with one query load. Both owned and mapped graphs implement the
private operation on the existing graph-access trait. Mapping ownership,
per-chunk bounds, query dimension and slot validation remain. Each row uses the
original accumulator width, reduction and scalar-tail order.

At level zero, search collects up to four first-visited adjacent slots in the
original order. Full F32 groups use the new operation; incomplete groups and
compact backends retain scalar scoring. Result admission, heap insertion and
counters run in the original order. Upper greedy descent and delta scan remain
unchanged; no public API, format, owner/cache layer, prefetch or inline directive
is added. No previously rejected optimization is combined with this candidate.

The mapped-only diagnostic compares all 67 queries × 8,192 slots in each of the
three corpora: **1,646,592 distance-bit comparisons** match. Seven alternating
passes show kernel throughput ratios of 1.499–1.582 (uniform-128), 1.632–2.054
(uniform-1536), and 1.854–2.070 (real-1536). These are kernel diagnostics, not
public query acceptance results.

Candidate validation: **147 targeted Mojo tests** = 143 existing affected tests
+ three new metric/row-boundary cases + one grouped-admission case; **355 full
Python tests pass**, with three existing warnings. Kernel cases cover dimensions
1/3/4/15/16/17/31/63/64/65/127/128/129/1536, all three metrics, owned/mapped
storage, repeated/noncontiguous/final slots, bad slots/dimensions and closed
mappings. The admission case covers full groups, a tail, ties, filtered/inactive
bridges, revisits and scratch reuse; it also passes on unchanged production.
Mojo TestSuite durations are milliseconds. No new full Mojo/crash/C ABI/GPU or
Linux validation is claimed for this candidate.

The copied binding entry was built with Mojo 1.0.0 (`ed45d567`), Apple M4 /
Metal:4. Candidate binary SHA-256:
`b3ad3194c09fc912173c317196248b81baefd6f8868d0554f2854ca526842546`.

## Public comparison

Frozen corpora, seeds, filters, K, selected efs, service boundaries and all
three trials remain unchanged. Baseline/candidate/Qdrant run serially in rotating
BAQ/AQB/QBA order from closed database clones. No build, tests or archive
compression overlap the measurements. Recall@10 ≥ .95, QPS ≥ Qdrant and
p95 ≤ Qdrant remain mandatory in every cell.

| Workload | Baseline strict pass | Candidate strict pass | Quality evidence |
|---|---:|---:|---|
| Warm | 16/36 | 18/36 | 108 quality cells, 6,912 timed audits, 7,236 exact checks |
| Mixed | 30/36 | 27/36 | 108 quality cells, 7,776 audits, 27 reopens, 18 Akasha leases |

All quality cells pass. IDs, Float32 score bits, execution and search stats match
between baseline and candidate; warm first queries/warmups also match. Both
speed assessments are **FAILED**. Assessment exit 1 is the expected failed
performance gate, not an incomplete run.

All nine real-1536 warm ANN cells improve: QPS +20.2% to +38.8%, p95 ratios
0.694–0.837. Mixed real filtered ANN improves in all six cells; real all has one
QPS regression (0.964) while all three p95 ratios improve. Mixed write/flush
combined p95 ratios are 0.970–1.019 and reopen ratios 0.977–1.026; this is not a
claim of write, flush or reopen acceleration.

Warm has no pass→fail cells. Mixed has four: uniform-128 selective trials 0/1/2,
and uniform-1536 correlated trial 1. The 128D selective p95 ratios are
1.944 / 5.532 / 6.158. These exact-plan cells do not execute the new HNSW kernel,
but remain part of acceptance; changing foreground/maintenance timing can alter
which query meets a background critical section.

## Diagnosing the mixed tail

Separate instrumented runs retain normal GC and all workload operations. Six
uniform-128 workers (three baseline/candidate pairs) record wall time, thread
CPU time and GC intervals. Slow selective samples of roughly 0.6–1.5 ms often
use only 0.1–0.17 ms of main-thread CPU, with **no GC overlap**. Both binaries
show this pattern. The measurements are diagnostic; no CPU-time substitution
or corrected acceptance latency is reported.

Separate copied bindings then time acquisition of the existing writer lock.
In representative slow selective samples, waiting takes 0.5–1.1 ms while the
work after acquisition takes 12–58 µs. Tracing background maintenance in three
baseline workers identifies overlapping compaction phases:

| Phase | Observed holding time |
|---|---:|
| Sealed-run merge check, no work due | 0–1 µs |
| Compaction capture | 93–282 µs |
| Successful compaction publish | 486–965 µs |

The trace includes one discarded output (131 µs). It is retained, not hidden.
Prints/timers perturb execution, so these phase traces explain waiting rather
than certify production performance. Locking and all persistent transitions
remain unchanged in both production and the uninstrumented scoring candidate.

A further three baseline workers split successful publication into its parts:

| Publication work | Observed duration (all 36 successful jobs) |
|---|---:|
| Rebase/load and durable manifest publication | 181–276 µs |
| In-memory read-generation publication | 0–1 µs |
| Lease-aware retired-file reclamation, including directory sync | 256–618 µs |

Reclamation is the largest measured component and currently runs under the
writer lock. Moving only that I/O outside the lock is the next independent
implementation hypothesis. Manifest validation/publication, file leases,
queue ownership, error retry, close/drain and crash behavior must remain intact.
The scoring candidate remains isolated while that work is evaluated.

## Every candidate/baseline trial

Ratios list trials 0 / 1 / 2. QPS is higher-is-better; p95 is lower-is-better. No samples are removed.

### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.029 / 1.043 / 0.997 | 0.902 / 0.949 / 1.036 |
| uniform-128 | correlated | 1.065 / 1.165 / 0.941 | 0.920 / 0.676 / 1.252 |
| uniform-128 | independent | 1.221 / 1.717 / 1.221 | 0.925 / 0.438 / 0.649 |
| uniform-128 | selective | 1.004 / 1.042 / 1.079 | 1.254 / 0.893 / 0.799 |
| uniform-1536 | all | 0.983 / 1.022 / 0.996 | 1.042 / 0.929 / 1.020 |
| uniform-1536 | correlated | 0.979 / 0.983 / 1.022 | 0.997 / 1.038 / 0.989 |
| uniform-1536 | independent | 0.980 / 0.974 / 0.982 | 1.004 / 0.995 / 1.034 |
| uniform-1536 | selective | 1.067 / 0.964 / 0.988 | 0.914 / 1.073 / 0.906 |
| real-1536 | all | 1.238 / 1.284 / 1.282 | 0.796 / 0.786 / 0.763 |
| real-1536 | correlated | 1.376 / 1.240 / 1.227 | 0.694 / 0.775 / 0.837 |
| real-1536 | independent | 1.388 / 1.256 / 1.202 | 0.694 / 0.819 / 0.816 |
| real-1536 | selective | 1.194 / 1.057 / 0.915 | 0.877 / 1.006 / 1.244 |

### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 0.885 / 0.980 / 1.129 | 2.990 / 1.080 / 0.593 |
| uniform-128 | correlated | 0.839 / 0.990 / 1.033 | 1.556 / 0.995 / 0.941 |
| uniform-128 | independent | 1.066 / 0.841 / 1.166 | 0.986 / 1.907 / 0.631 |
| uniform-128 | selective | 0.855 / 0.783 / 0.599 | 1.944 / 5.532 / 6.158 |
| uniform-1536 | all | 1.031 / 1.033 / 1.017 | 0.989 / 1.009 / 0.962 |
| uniform-1536 | correlated | 1.048 / 0.912 / 1.059 | 0.934 / 1.988 / 1.023 |
| uniform-1536 | independent | 1.146 / 1.062 / 1.030 | 0.940 / 0.947 / 0.886 |
| uniform-1536 | selective | 1.072 / 1.203 / 1.410 | 1.433 / 0.659 / 0.541 |
| real-1536 | all | 0.964 / 1.259 / 1.283 | 0.832 / 0.756 / 0.733 |
| real-1536 | correlated | 1.294 / 1.265 / 1.257 | 0.723 / 0.887 / 0.774 |
| real-1536 | independent | 1.279 / 1.252 / 1.266 | 0.781 / 0.848 / 0.783 |
| real-1536 | selective | 0.981 / 1.252 / 1.160 | 1.256 / 0.581 / 0.618 |


## Frozen evidence and reproduction

[Immutable archive](results/2026-10-03-four-distance.json.gz): 300 files,
22,223,562 bytes, SHA-256 `e6fefd3d13a668fa8cb1f45ff5c0ffea9fa3ae4a346f7044fc72e2178d3b5680`.
It contains all reports, trials, logs, micro samples, modified variant sources,
drivers, test sources/results, input hashes and separate instrumented traces.
Baseline source is `a710aa5`; experiment checkpoint is `ff13f46`. Every archived
file hash and both public assessments were verified. Frozen archives are not
rewritten; `.build` is only a working copy.

As-run targeted checks (the copied source and binding entry must match):

```bash
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I .build/2026-10-03-batch-distance/after-src .build/2026-10-03-batch-distance/edge-test.mojo
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I .build/2026-10-03-batch-distance/after-src .build/2026-10-03-batch-distance/order-test.mojo
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/.build/2026-10-03-batch-distance/after-python:$PWD:$PWD/.build/qdrant-compare/deps" python -m pytest tests/python -q -o pythonpath='
```

The archive's `run-validation.py` records all 13 existing test files and the
copied-entry build command. `measure-warm.py`, `assess-warm.py` and
`measure-mixed.py` contain the exact trial schedule; use new output directories
for a new experiment. Do not rerun source-mutating setup scripts over existing
variants. Do not run benchmarks with builds, tests or compression.

Native Linux x86-64 controlled-memory/nonresident validation remains unavailable:
the user confirmed there is no runner. No new Linux, ASan or GPU gate is claimed.
