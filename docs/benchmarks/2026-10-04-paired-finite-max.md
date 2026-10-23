# Checked-pair finite validation experiment — 2026-10-04

Neither candidate was adopted. Folding the validation state removes a measured
register-spill regression and improves most kernel timings, but public tails
remain inconsistent. Warm strict parity is **23→24/36**, mixed **19→21/36**, and
durable write+flush **3→3/9**. There are five pass→fail query cells. Both boundaries
remain **FAILED**; M5/M6 is unfinished. Production source and binaries are unchanged.
Three finite-bit regression tests are retained, byte-identical to the tested file.

## Evidence and hypothesis

Current production binary `53f630ff…` was profiled on fresh clones using the fixed
selective query streams. Uniform-1536 completed 64,128 checked queries; the paired
kernel was the leaf in 2,016/4,171 main-thread samples (48.33%). Real-1536 completed
61,120 checked queries, with 2,249/4,190 samples (53.68%). All 125,248 results match
the current gate's IDs, F32 bits and stats. These 5-second captures inside separate
7-second diagnostic runs are not acceptance timings.

The current width-16 loop packs two Boolean finite masks. The inspected AArch64
code uses 24 validation instructions per iteration before its score arithmetic.
The new hypothesis changes that intermediate representation, retaining every
candidate check. It is distinct from the older finite-reduction-placement probe.
No query validation, norm check, owner, arithmetic order, metric dispatch, heap
admission order or durable format is changed.

Candidate 1 accumulates the unsigned maximum of each F32 word shifted left by one.
Dropping the sign bit makes all finite words smaller than `0xFF000000`; infinity
and all NaN payloads reach or exceed it. It retains two width-16 accumulators.
Cosine assembly shows repeated vector spills/reloads in the steady loop, and all
three real cosine micro trials regress. This version was stopped at kernel tests
and micro measurement; it has no Python binding or public matrix.

Candidate 2 folds each validation vector to the native SIMD width using the
existing `SIMD.reduce_max[size_out]` API. The cosine steady loop has no vector
stack traffic; its 16 validation instructions replace the previous 24. Score and
norm accumulation widths remain unchanged. Final validation and tail checks stay
at their original error-precedence boundaries. Only the copied
`akasha/compute/simd.mojo` differs from production.

The APIs were checked against pinned Mojo 1.0.0 source:
[bitcast](https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/memory/unsafe.mojo)
and [SIMD reductions](https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/builtin/simd.mojo).
The archive contains source identities, inspected symbols, disassembly commands
and complete assembly/offset listings for both candidates.

## Validation

Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. The final isolated source passes
**89 unique targeted Mojo tests**: 81 existing distance/metric/HNSW tests, five
paired-score tests and three new all-exponent/all-lane cases. Earlier endpoint
versions of the same three new cases also passed and are not added again.
The first wide candidate passed the endpoint three plus existing five cases.

The retained tests cover all 256 exponent values, both signs and four mantissas,
including quiet/signaling NaN classes, at every coordinate of dimensions
4/16/17/64/65. They compare finite result bits with the unchanged scalar scorer,
check rejection in either candidate, and verify source bits remain intact.
They pass against both baseline and final candidate. Existing paired tests cover
empty/dimension errors, each nonfinite lane, signed zero, arithmetic extremes,
odd tails and first-candidate error precedence through 1,536 dimensions.

The final isolated binding passes **388 complete Python tests**, with one existing
Starlette/httpx deprecation warning. Its entry point and all Mojo imports come
from the copied tree. Saved-package pytest uses `-o pythonpath=`, import/hash
guards, and the Metal wrapper for child compilation. The native worker is not
overwritten. There is no new C ABI, example, crash, full Mojo, HTTP, Linux, ASan,
GPU or distributed run in this experiment.

## Kernel diagnostics

Each candidate has its own complete 18-worker cohort: three corpora × three
alternating AB/BA/AB trials × two versions, seven timed passes each. Inputs are
the original 8,192-row tapes and all 67 selective queries, in deterministic pair
order. Every worker compares every score with the unchanged scalar scorer before
timing; paired timing checksums agree. Original input hashes and every sample
are retained. These are kernel diagnostics, not public service measurements.

Ratios below are candidate/baseline mean duration; smaller is better.

| Candidate | Corpus / metric | Trial 0 | Trial 1 | Trial 2 |
|---|---|---:|---:|---:|
| Wide state | uniform-128 / Dot | .834 | .917 | .895 |
| Wide state | uniform-1536 / Dot | .974 | .941 | .998 |
| Wide state | real-1536 / Cosine | 1.088 | 1.030 | 1.076 |
| Folded state | uniform-128 / Dot | 1.085 | .918 | .883 |
| Folded state | uniform-1536 / Dot | .922 | .953 | .944 |
| Folded state | real-1536 / Cosine | .985 | .941 | .953 |

The folded 128D first-trial regression is retained. No samples are removed, and
the two cohorts are not combined into a better result.

## Public matrix and decision

All 54 workers complete successfully, serially, from closed fresh clones.
Corpora/seeds/filters/K/efs/service boundaries/trials remain fixed. Before,
folded and Qdrant run in BAQ/QAB/BAQ order. Benchmarks do not overlap builds,
tests, profiles or archive compression.

Each boundary passes 36/36 matched-recall cells for each Akasha version. Warm
contains 6,912 timed audits, 324 warmups, 7,236 exact checks and 27 first-query
observations. Mixed contains 7,776 audits, 27 reopen checks and 18 Akasha leases.
All paired timed IDs/F32 bits/stats/execution match (2,304 warm and 2,592 mixed
pairs); warmups and first-query results are also compared. Every mixed worker
finishes its 32 write batches and flushes. No lock timeout occurs in this cohort;
that does not resolve the earlier baseline stall.

The folded candidate regresses QPS or p95 in **11/36 warm** and **21/36 mixed**
cells. Pass→fail cells are:

- Warm: uniform-128 selective trial 1.
- Mixed: uniform-128 correlated trial 0 and independent trial 1;
  uniform-1536 selective trials 0 and 1.

Uniform-1536 warm selective improves in all three trials, but its mixed p95
ratios are 2.102/1.130/1.304. Real selective improves in all three mixed trials,
but its warm trial 2 regresses. The gains do not offset these failures. Neither
candidate is promoted; the final assessment exits 1 as the correct **FAILED**
result, not as an unfinished measurement or an audit failure. Future work should
not repeat these variants without a new causal hypothesis.

## Identities and reproduction

- Baseline source: `f398b67` (production implementation `3a5ad04`).
- Production Python SHA-256:
  `53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`.
- Unadopted folded Python SHA-256:
  `41e3dafd3715e9099b9e4ac467288182ea0861fef80b1787a26fcd58b4ab58d6`.
- Retained test SHA-256:
  `befc3155626d56090d75b867269759c02cc3319c07a6971b53fd313180244830`.
- [Immutable archive](results/2026-10-04-paired-finite-max.json.gz):
  5,680,381 bytes, 697 text entries, SHA-256
  `bfb7c33b31c55cf22b2f3568bd500e4db038b44e28bf7df69e3e9d4aa662b47a`.
  Gzip readback and every embedded file hash were checked.

The archive includes both copied candidates, profiles, tests, build/test logs,
micro/public samples, source/input/binary identities, wrapper and drivers.
Large original corpus/database/binary files are referenced by hashes, not embedded.
Existing `.build` output directories are evidence: do not rerun their writing
drivers in place or overwrite the immutable archive. Inspect archived commands
and stage a fresh output tree before reproducing a cohort.

Read-only assessment of the existing complete matrix:

```sh
rtk proxy python3 .build/2026-10-04-paired-finite-max/summarize.py
```

The retained three cases can be rerun independently when no benchmark is active:

```sh
rtk proxy pixi run mojo run -I src tests/mojo/test_paired_finite_bits.mojo
```

## Every public candidate/baseline trial

Higher QPS ratios and lower p95 ratios are better. Every regression remains below.

### warm

| Corpus | Mode | QPS ratios, trials 0 / 1 / 2 | p95 ratios, trials 0 / 1 / 2 |
|---|---|---|---|
| uniform-128 | all | 0.962 / 1.064 / 0.912 | 1.123 / 0.881 / 1.205 |
| uniform-128 | correlated | 1.363 / 1.210 / 1.137 | 0.871 / 0.529 / 0.787 |
| uniform-128 | independent | 0.988 / 0.999 / 1.109 | 0.860 / 0.935 / 0.790 |
| uniform-128 | selective | 1.189 / 0.652 / 1.015 | 0.719 / 1.850 / 1.108 |
| uniform-1536 | all | 0.801 / 1.164 / 1.048 | 1.656 / 0.765 / 0.923 |
| uniform-1536 | correlated | 1.017 / 1.138 / 1.034 | 0.972 / 0.911 / 0.975 |
| uniform-1536 | independent | 0.997 / 1.079 / 1.017 | 0.913 / 0.948 / 0.972 |
| uniform-1536 | selective | 1.089 / 1.244 / 1.046 | 0.917 / 0.735 / 0.975 |
| real-1536 | all | 1.009 / 1.197 / 1.053 | 0.946 / 0.772 / 0.935 |
| real-1536 | correlated | 1.143 / 1.016 / 1.023 | 0.848 / 1.018 / 0.981 |
| real-1536 | independent | 1.144 / 0.964 / 1.088 | 0.891 / 1.013 / 0.905 |
| real-1536 | selective | 1.032 / 1.087 / 0.927 | 0.843 / 0.906 / 1.147 |

### mixed

| Corpus | Mode | QPS ratios, trials 0 / 1 / 2 | p95 ratios, trials 0 / 1 / 2 |
|---|---|---|---|
| uniform-128 | all | 1.023 / 0.988 / 0.954 | 0.638 / 0.987 / 1.191 |
| uniform-128 | correlated | 0.844 / 0.969 / 1.025 | 2.219 / 1.000 / 0.862 |
| uniform-128 | independent | 0.979 / 0.940 / 1.022 | 0.780 / 1.339 / 0.752 |
| uniform-128 | selective | 1.040 / 1.018 / 1.565 | 1.034 / 0.940 / 0.310 |
| uniform-1536 | all | 0.998 / 0.948 / 1.015 | 0.987 / 1.117 / 1.010 |
| uniform-1536 | correlated | 1.060 / 0.990 / 1.067 | 0.799 / 0.977 / 1.027 |
| uniform-1536 | independent | 0.990 / 1.025 / 1.098 | 1.138 / 0.985 / 0.804 |
| uniform-1536 | selective | 0.851 / 0.973 / 1.011 | 2.102 / 1.130 / 1.304 |
| real-1536 | all | 1.107 / 1.051 / 0.997 | 0.821 / 0.873 / 1.017 |
| real-1536 | correlated | 1.083 / 0.993 / 0.980 | 0.927 / 1.073 / 1.015 |
| real-1536 | independent | 1.085 / 1.033 / 0.986 | 0.860 / 1.027 / 0.993 |
| real-1536 | selective | 1.070 / 1.075 / 1.073 | 0.868 / 0.732 / 0.747 |
