# Four-row F32 HNSW after unlocked reclamation — 2026-10-03

Adopted after reevaluating the saved scoring change on `7dd8647`, which already
reclaims compaction inputs outside the writer lock. The new scoring code is
identical to the previously isolated three-file candidate. It improves every
real-1536 mixed ANN cell, while warm and other mixed cells still have regressions.
**The strict performance gate remains FAILED; M5/M6 is not complete.**

## Scope and correctness

The [original design and experiment](2026-10-03-four-distance.md) explain the
four independent F32 accumulators, shared query loads, mapped bounds and retained
owners. Base-layer neighbor grouping preserves result admission, heap insertion,
score bits and stats. Partial groups, other scalar backends, upper traversal and
delta scan keep their existing arithmetic. No query checks, public API, format,
cache/owner layer or dependency is removed or added.

This new experiment compares two packages that **both** contain unlocked
reclamation. It does not replace or erase the first experiment's failed trials.
The earlier 1,646,592 kernel bit comparisons remain applicable to the identical
scoring code; they were not rerun or counted as new validation.

New validation: **174 targeted Mojo tests**, **355 full Python tests** (three
existing warnings), **C ABI/client**, and builds/runs of all **three examples**
pass. The Mojo set includes 143 affected metric/HNSW tests, the grouped-order
test, three metric-specific kernel cases, seven reclamation cases and 20
background-publication cases. Saved pytest uses `-o pythonpath=`; pixi activation
and the Metal wrapper propagate to child compilation, whose `-I src` is redirected
to the copied candidate tree. The binding entry and include tree are both copied.

The unchanged reclamation implementation retains its preceding 21 related crash
checks; no new crash run is claimed here. This is not a new full Mojo, distributed,
Linux, ASan or GPU suite. Mojo TestSuite times are milliseconds. Compiler:
Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4.

The exact tested source and binary were promoted. Python binary SHA-256:
`7b42e740846e03d99291b38a4c94c3b0b54fa47ba75a34ab889baada6c68f822`.
Native worker is unchanged.

## Public results and adoption limits

Frozen corpora, seeds, filters, K, efs, service boundaries and three rotating
BAQ/AQB/QBA trials are unchanged. All workers run serially from closed database
clones; builds/tests/compression do not overlap. No samples or failed trials are
removed. Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant remain mandatory per cell.

| Workload | Baseline strict pass | Candidate strict pass | Quality evidence |
|---|---:|---:|---|
| Warm | 18/36 | 22/36 | 108 quality cells, 6,912 timed audits, 7,236 exact checks |
| Mixed | 23/36 | 26/36 | 108 quality cells, 7,776 audits, 27 reopens, 18 leases |

Every quality cell passes. IDs, Float32 score bits, stats and execution match;
warm first queries and warmups match as well. Both speed assessments exit 1,
the expected **FAILED** gate. Warm has no pass→fail cells. Mixed has **one**:
uniform-1536 independent, trial 1 (QPS ratio 0.819; p95 ratio 1.385 versus baseline).

Real-1536 mixed all/correlated/independent improve in all nine cells: QPS ratios
1.209–1.309, p95 ratios 0.696–0.894. This repeats the end-to-end ANN benefit
observed in the original warm experiment. In this new warm run, eight of nine
real ANN QPS values improve; real all trial 2 regresses to 0.943. Three real ANN
p95 values regress (all trial 2, correlated trial 1, independent trial 1), up to
1.405. They remain failures/regressions, not excluded outliers.

The exact-plan cells also show substantial differences despite unchanged scan
code: warm uniform-128 correlated/independent trial 2 p95 exceed 2× baseline;
mixed uniform-1536 selective QPS ratios are 0.666 / 0.437 / 0.893 and all its p95
ratios worsen. Timing overlap, allocation/code placement or environmental effects
have not been separated here. Unchanged code does not justify ignoring a cell.

Adoption is an intermediate implementation decision based on preserved behavior,
the independently verified reclamation boundary and repeated public ANN gains.
It does **not** assert every workload is faster or satisfy the user's full-matrix
requirement. Strict pass counts from different experiments must not be combined.
The remaining exact-scan, ANN and maintenance tails still require work.

## Every candidate/baseline trial

Ratios are trials 0 / 1 / 2. Higher QPS and lower p95 are better.

### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.162 / 1.214 / 0.833 | 0.707 / 0.643 / 1.630 |
| uniform-128 | correlated | 0.950 / 1.107 / 0.538 | 1.024 / 0.996 / 2.077 |
| uniform-128 | independent | 1.033 / 0.909 / 0.747 | 1.002 / 1.052 / 2.086 |
| uniform-128 | selective | 1.128 / 1.167 / 1.033 | 0.739 / 0.697 / 0.955 |
| uniform-1536 | all | 1.000 / 1.882 / 0.980 | 0.984 / 0.249 / 0.934 |
| uniform-1536 | correlated | 1.012 / 1.049 / 0.873 | 0.994 / 0.954 / 1.267 |
| uniform-1536 | independent | 1.012 / 1.106 / 1.050 | 1.002 / 0.482 / 0.620 |
| uniform-1536 | selective | 0.995 / 1.040 / 1.243 | 1.044 / 0.818 / 1.032 |
| real-1536 | all | 1.227 / 1.292 / 0.943 | 0.878 / 0.743 / 1.135 |
| real-1536 | correlated | 1.371 / 1.004 / 1.113 | 0.696 / 1.121 / 0.906 |
| real-1536 | independent | 1.241 / 1.195 / 1.256 | 0.542 / 1.405 / 0.808 |
| real-1536 | selective | 1.069 / 0.983 / 0.865 | 0.928 / 0.772 / 1.419 |

### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.505 / 1.634 / 0.738 | 1.347 / 0.583 / 1.659 |
| uniform-128 | correlated | 1.156 / 3.642 / 4.924 | 1.144 / 0.455 / 1.029 |
| uniform-128 | independent | 1.174 / 1.149 / 0.832 | 1.035 / 0.923 / 0.863 |
| uniform-128 | selective | 0.733 / 0.207 / 1.715 | 1.299 / 1.705 / 3.706 |
| uniform-1536 | all | 1.001 / 0.888 / 0.989 | 0.899 / 1.242 / 1.014 |
| uniform-1536 | correlated | 1.453 / 0.785 / 0.993 | 0.824 / 1.139 / 0.898 |
| uniform-1536 | independent | 0.988 / 0.819 / 1.002 | 0.909 / 1.385 / 0.958 |
| uniform-1536 | selective | 0.666 / 0.437 / 0.893 | 1.433 / 1.443 / 1.826 |
| real-1536 | all | 1.262 / 1.304 / 1.222 | 0.743 / 0.696 / 0.828 |
| real-1536 | correlated | 1.209 / 1.235 / 1.211 | 0.894 / 0.860 / 0.851 |
| real-1536 | independent | 1.268 / 1.309 / 1.288 | 0.815 / 0.731 / 0.753 |
| real-1536 | selective | 0.972 / 1.069 / 1.069 | 1.157 / 0.900 / 0.683 |

## Frozen evidence and reproduction

[Immutable archive](results/2026-10-03-batch-after-reclaim.json.gz):
209 files, 18,682,040 bytes; SHA-256
`587aab62755ff3643d723c1dc9c5a0f5305ee8bb615f5f681d00ec1e8464a03f`.
It contains all trial reports and samples, copied changed sources, kernel tests,
validation/build logs and commands, source/binary/input identities and drivers.
Baseline source is `7dd8647`; the archive was frozen before promotion, so its
production binary identity describes the preceding `3610e302…` baseline.
All archived file hashes were decoded and verified.

Retained targeted checks:

```bash
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_hnsw_four_distance.mojo'
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_hnsw_group_order.mojo'
```

Archived `validate.py`, `integrate-checks.py`, `measure-warm.py`, `assess-warm.py`
and `measure-mixed.py` record exact commands and the full schedule. Use fresh
directories for new trials; do not overwrite frozen archives or rerun mutating
setup scripts over saved variants. `.build` remains temporary.

There is still no available native Linux runner for controlled-memory/sustained
nonresident checks. Concurrent-client/HTTP parity is also unfinished. Earlier
distributed functional tests do not certify those performance boundaries.
