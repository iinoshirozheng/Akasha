# Paired checked F32 scoring for filtered exact scans — 2026-10-03

Adopted on `c00494f` for a proper subset of live ordinals. Full-live-set scans keep
the original sequential loop. This repeats useful high-dimensional filtered-scan
gains, but some full-scan and ANN trials regress. **The strict performance gate
remains FAILED; M5/M6 is not complete.** The universal-pairing candidate was not
adopted. Both experiments and every sample remain available separately.

## Implementation and validation

The private two-row kernel shares the query SIMD load, retaining two independent
score, candidate-finiteness and cosine-norm accumulators. It preserves each row's
SIMD width, reduction and scalar-tail order, Float32 score bits and first-error
precedence. Dimensions, every candidate value and cosine zero norms remain
checked. The query is prepared once by the existing operation boundary. No cache,
inline directive, ownerless view, dependency or durable-format change is added.

Collection exact scanning uses paired adjacent ordinals only when the candidate
set is a proper subset of the live set. The live count is cached O(1). Missing
default fields, partial pairs, odd tails and top-k admission order are preserved.
The snapshot single-row exact path is independently compared in the new public
regressions. HNSW checked rerank, FlatIndex and other scalar backends are unchanged.

Validation for the adopted implementation: **99 targeted Mojo tests** (94 existing
cases against the final isolated tree, plus five kernel cases rerun after exact
promotion), **358 Python tests** (355 existing plus three new metric cases),
**C ABI/client**, and all **three examples** build and pass. The three new Python
cases also pass on the baseline. They cover named-only points, absent second
fields, ties, odd dimensions, all/empty/subset filters, two K values, delete,
default-field addition/removal, flush and reopen. Five Mojo tests cover all three
metrics at SIMD boundaries, every nonfinite lane, size errors, first-candidate
error precedence, extreme finite values and signed zero.

Saved pytest uses `-o pythonpath=` and the isolated package first. Pixi activation
and the Metal wrapper propagate to child compilation, with `-I src` redirected
to the copied tree. The binding entry itself is copied. No worker library is
rebuilt during testing. Compiler: Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4.
TestSuite times are milliseconds. There is no new full Mojo/crash/distributed,
Linux, ASan or GPU suite; preceding storage/crash results remain applicable.

Promoted Python binary SHA-256:
`b183b8805e8b7cf29b86cf443e1898befebac4cd77844680944f853461422412`.
C ABI SHA-256: `662fd31469c0b68e4df6c3a9afe5c5041de3f630043ab40b3436ef2e6d42c238`.
The native worker is unchanged. Both source files and artifacts are exact copies
of the validated final candidate.

## Diagnostic kernel experiment

Seven alternating passes over the three frozen corpora compare 1,646,592 score
bits successfully. All these corpus microbenchmarks use **Dot**; the real public
workload uses **Cosine**, so the raw-real Dot result is not a same-metric proxy
for its public cost. The separate boundary tests cover all three metrics.
Diagnostic scalar/pair time ratios range 1.014–1.263 for uniform-128,
1.503–1.559 for uniform-1536 and 1.390–1.536 for raw real-1536 vectors.
A kernel improvement alone does not satisfy the public gate.

## Public results and decision

Frozen corpora, seeds, filters, K, efs, service boundaries and three rotating
BAQ/AQB/QBA trials are unchanged. All workers run serially from closed clones;
builds/tests/profiles/compression do not overlap with benchmark execution. Every
sample and failed trial is retained. Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤
Qdrant are mandatory per cell, without tolerance or offsets across cells/trials.

| Experiment | Workload | Baseline strict pass | Candidate strict pass | Pass→fail |
|---|---|---:|---:|---:|
| Universal pairing, not adopted | Warm | 17/36 | 21/36 | 0 |
| Universal pairing, not adopted | Mixed | 31/36 | 31/36 | 0 |
| Filtered pairing, adopted | Warm | 19/36 | 20/36 | 2 |
| Filtered pairing, adopted | Mixed | 29/36 | 32/36 | 0 |

Each run passes all 108 quality cells. Each warm run has 6,912 timed audits,
7,236 exact checks and 324 warmups; each mixed run has 7,776 audits, 27 reopens
and 18 leases. IDs, Float32 score bits, stats and execution match. All four speed
assessments return the expected exit 1 (**FAILED**), not an incomplete run.

Universal pairing loses on uniform-1536 full scans in all six warm/mixed trials:
QPS ratios 0.840–0.903, p95 ratios 1.045–1.251. That systematic cost prompted the
operation-shape restriction. It was not promoted, despite its pass count.

With filtered pairing, uniform-1536 correlated/independent improve QPS and p95 in
all 12 warm/mixed cells: QPS ratios 1.096–1.321 and p95 ratios 0.838–0.957. Warm
1536D selective scans also improve, and mixed selective QPS improves, but some
mixed p95 values worsen. The final warm run loses strict parity for real-1536 all
trials 0 and 1. All three uniform-128 full-scan QPS values regress in both runs;
the full-loop implementation is retained, but the cause of these regressions
has not been separated. They remain regressions, not excluded noise.

Adoption is an intermediate implementation decision based on preserved behavior
and repeated filtered high-dimensional gains. It does not certify every cell as
faster, combine pass counts from different experiments, or close M5/M6. Full-scan,
ANN and maintenance tails still require work.

## Every candidate/baseline trial

Ratios are trials 0 / 1 / 2. Higher QPS and lower p95 are better.

### Universal pairing — not adopted

#### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.017 / 1.010 / 0.963 | 0.974 / 0.998 / 1.248 |
| uniform-128 | correlated | 1.198 / 1.003 / 0.924 | 0.626 / 1.235 / 1.534 |
| uniform-128 | independent | 1.034 / 1.944 / 0.991 | 0.921 / 0.363 / 1.081 |
| uniform-128 | selective | 1.563 / 1.070 / 1.199 | 0.477 / 0.668 / 0.735 |
| uniform-1536 | all | 0.840 / 0.880 / 0.859 | 1.251 / 1.105 / 1.177 |
| uniform-1536 | correlated | 1.129 / 1.120 / 1.163 | 0.888 / 0.879 / 0.875 |
| uniform-1536 | independent | 1.295 / 1.245 / 1.246 | 0.824 / 0.853 / 0.845 |
| uniform-1536 | selective | 1.317 / 1.173 / 1.225 | 0.657 / 0.850 / 0.840 |
| real-1536 | all | 1.011 / 0.989 / 0.876 | 0.995 / 1.001 / 1.094 |
| real-1536 | correlated | 0.987 / 0.982 / 0.995 | 1.030 / 0.988 / 1.006 |
| real-1536 | independent | 1.008 / 0.984 / 1.098 | 1.019 / 1.075 / 0.886 |
| real-1536 | selective | 1.166 / 1.108 / 1.196 | 0.787 / 0.984 / 0.802 |

#### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.121 / 0.987 / 1.035 | 0.935 / 1.485 / 0.972 |
| uniform-128 | correlated | 1.172 / 1.057 / 0.870 | 0.750 / 0.913 / 0.929 |
| uniform-128 | independent | 0.977 / 1.089 / 1.136 | 1.435 / 0.956 / 0.592 |
| uniform-128 | selective | 0.892 / 1.246 / 1.756 | 3.757 / 0.199 / 1.127 |
| uniform-1536 | all | 0.869 / 0.859 / 0.903 | 1.161 / 1.198 / 1.045 |
| uniform-1536 | correlated | 1.096 / 1.082 / 1.146 | 0.907 / 0.926 / 0.954 |
| uniform-1536 | independent | 1.326 / 1.332 / 1.384 | 0.786 / 0.766 / 0.752 |
| uniform-1536 | selective | 1.280 / 1.149 / 1.345 | 0.974 / 1.764 / 0.939 |
| real-1536 | all | 1.018 / 1.030 / 1.007 | 1.018 / 0.931 / 1.002 |
| real-1536 | correlated | 1.028 / 0.945 / 1.018 | 0.970 / 1.053 / 1.031 |
| real-1536 | independent | 1.024 / 0.999 / 1.014 | 0.924 / 0.999 / 0.986 |
| real-1536 | selective | 1.293 / 1.226 / 1.226 | 0.827 / 1.224 / 0.923 |


### Filtered pairing — adopted

#### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 0.987 / 0.925 / 0.908 | 1.011 / 1.238 / 1.327 |
| uniform-128 | correlated | 1.118 / 0.708 / 1.027 | 0.729 / 1.349 / 0.902 |
| uniform-128 | independent | 0.925 / 1.022 / 0.987 | 1.160 / 0.938 / 1.143 |
| uniform-128 | selective | 1.076 / 1.231 / 0.978 | 0.907 / 0.694 / 1.121 |
| uniform-1536 | all | 0.911 / 0.999 / 0.990 | 1.137 / 1.015 / 1.014 |
| uniform-1536 | correlated | 1.113 / 1.110 / 1.135 | 0.910 / 0.918 / 0.898 |
| uniform-1536 | independent | 1.249 / 1.241 / 1.239 | 0.845 / 0.845 / 0.855 |
| uniform-1536 | selective | 1.470 / 1.195 / 1.328 | 0.543 / 0.775 / 0.691 |
| real-1536 | all | 0.909 / 0.976 / 1.030 | 1.089 / 1.016 / 0.938 |
| real-1536 | correlated | 0.942 / 0.988 / 0.999 | 1.097 / 1.000 / 0.984 |
| real-1536 | independent | 1.068 / 0.862 / 0.937 | 0.875 / 1.218 / 1.112 |
| real-1536 | selective | 1.219 / 1.319 / 1.149 | 0.746 / 0.646 / 0.771 |

#### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 0.982 / 0.952 / 0.987 | 1.016 / 1.047 / 0.986 |
| uniform-128 | correlated | 0.994 / 1.015 / 1.007 | 1.543 / 1.032 / 1.020 |
| uniform-128 | independent | 1.009 / 1.028 / 1.015 | 0.957 / 0.993 / 0.918 |
| uniform-128 | selective | 1.195 / 1.092 / 1.102 | 0.619 / 0.934 / 0.846 |
| uniform-1536 | all | 1.023 / 1.028 / 0.995 | 0.974 / 0.964 / 1.034 |
| uniform-1536 | correlated | 1.115 / 1.097 / 1.096 | 0.957 / 0.907 / 0.840 |
| uniform-1536 | independent | 1.321 / 1.286 / 1.273 | 0.838 / 0.865 / 0.919 |
| uniform-1536 | selective | 1.507 / 1.490 / 1.161 | 0.326 / 1.185 / 1.303 |
| real-1536 | all | 1.030 / 1.020 / 0.981 | 0.969 / 0.973 / 1.025 |
| real-1536 | correlated | 1.033 / 1.020 / 0.983 | 0.956 / 1.015 / 1.034 |
| real-1536 | independent | 1.013 / 1.021 / 0.992 | 1.018 / 0.915 / 1.056 |
| real-1536 | selective | 1.309 / 1.195 / 1.327 | 0.662 / 1.326 / 0.559 |


## Fresh baseline profile

The archive also contains five 5-second `sample` captures after 67 warmups, taken
against **production `c00494f` / `7b42e740…` before promotion**, not the filtered
candidate. These are diagnostic samples, separate from timed acceptance trials.

| Case | Main-thread samples | Mapped four-row | Mapped single-row | Collection exact |
|---|---:|---:|---:|---:|
| real-1536 all, ef16 | 3,797 | 31.24% | 6.61% | 0% |
| real-1536 correlated, ef32 | 3,802 | 34.77% | 6.29% | 0% |
| real-1536 independent, ef40 | 3,791 | 35.51% | 6.33% | 0% |
| real-1536 selective, ef10 | 3,814 | 0% | 0% | 72.39% |
| uniform-128 all, ef128 | 3,834 | 0% | 0% | 55.01% |

Percentages are inclusive function samples; inlined arithmetic is part of the
collection exact total. Do not sum parent/child categories. Uniform-128 also has
16.20% in default-field lookup, 11.03% in values access and 8.71% in top-k offer;
the earlier rejected lookup prototypes are not thereby validated. Filtered real
ANN still uses scalar delta scans (6.04–7.05% owned distance), while unfiltered
real ANN uses the already batched owned HNSW traversal. Checked rerank is
10.31–11.50% for filtered ANN; this does not authorize removing checks or repeating
the rejected prepared-rerank prototype. Mapped distance remains the largest ANN
component. Python vector conversion is about 1% for these filtered ANN cases.

## Frozen evidence and reproduction

[Immutable archive](results/2026-10-03-paired-exact.json.gz): 417 files,
37,495,341 bytes; SHA-256
`3e80c14a01efcfca271a8c22199483d3b0257c7dea1b75d4ab18c3f0a5045e7a`.
All decoded file hashes were verified. It contains both source candidates,
all four public runs and raw samples, micro/edge/public tests, validation and
build logs, commands, identities, drivers and fresh baseline profile captures.
It was frozen before promotion, so production identity entries describe `7b42…`.

Final assessment hashes (warm / mixed):
`9b420b740710153c9b26bd7b6ad240e0bae35623ec554732483cf1fea7ee10c1` /
`2cda6c7ab8512b429624bd6ca07c958e99fcc390fecdbdb89f265cd28885b493`.
The archived `validate.py`, `integrate-checks.py`, `measure-warm.py`,
`assess-warm.py` and `measure-mixed.py` record exact commands and schedules.
Use fresh output directories; do not rerun mutating setup scripts over saved
variants or overwrite frozen archives. `.build` remains temporary.

Retained checks:

```bash
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_paired_exact.mojo'
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD:$PWD/.build/qdrant-compare/deps" python -m pytest tests/python/test_paired_exact.py -q -o pythonpath='
```

The user confirms no native Linux runner is available. Sustained nonresident /
controlled-memory checks and concurrent-client/HTTP parity remain unfinished.
Distributed functional success does not certify those performance boundaries.
