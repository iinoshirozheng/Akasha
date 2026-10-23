# Native F64 metric loops

Native F64 dense/MaxSim scoring now iterates equal-length borrowed Spans with
`std.iter.zip`. This removes per-coordinate error-string preparation while
preserving sequential scores and numeric validation. It is a partial M5
improvement, not completion of M5/M6. The alternative that only separated metric
loops was measured independently and not adopted.

Baseline: `7b53ce9`; Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4.
Baseline Python SHA-256:
`7db8a2d6b20436c5efdc71dd92565d58c4037448c32fbd7bfbee6a81c19910a6`.
Adopted Python SHA-256:
`2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`.
Metric-only diagnostic SHA-256:
`435a12372b36cb0a718fa8b4ccfaec39990ee7cdf31acbeab915693174064655`.

## Cost attribution

The instrumented baseline uses the full frozen import/update/delete streams and each named cell's previously selected ef. All 804 samples (including 36 warmups) reproduce reference IDs, score bits and complete statistics. The table averages the 64 measured samples per cell. Logging occurs after the measured interval. These are instrumented phase timings, not public latency or Qdrant results.

| Corpus | Filter | Total µs | Base graph % | Small-run graph % | Native rerank % | Admission % |
|---|---|---:|---:|---:|---:|---:|
| uniform-128 | all | 399.0 | 51.8 | 27.3 | 14.0 | 4.0 |
| uniform-128 | correlated | 424.9 | 47.4 | 25.8 | 11.2 | 13.3 |
| uniform-128 | independent | 725.5 | 49.5 | 27.2 | 12.6 | 8.0 |
| uniform-128 | selective | 713.3 | 71.5 | 16.2 | 8.0 | 3.0 |
| uniform-1536 | all | 4283.8 | 50.6 | 14.2 | 32.7 | 0.9 |
| uniform-1536 | correlated | 4294.6 | 49.3 | 13.8 | 32.0 | 3.6 |
| uniform-1536 | independent | 4318.3 | 49.2 | 13.8 | 32.0 | 3.7 |
| uniform-1536 | selective | 7063.6 | 81.6 | 6.5 | 10.1 | 1.2 |
| real-1536 | all | 541.7 | 45.3 | 30.6 | 18.9 | 4.1 |
| real-1536 | correlated | 629.7 | 39.4 | 25.9 | 14.9 | 19.1 |
| real-1536 | independent | 588.9 | 41.6 | 24.7 | 15.2 | 17.9 |
| real-1536 | selective | 1898.4 | 65.4 | 20.4 | 9.8 | 4.1 |

Ready-artifact lookup is below 0.1%; caching that lookup is not the next large opportunity. Graph traversal remains dominant, especially for selective queries. Small-run graph traversal, first-open/reopen construction and admission costs remain separate unfinished work.

## Metric-only candidate and validation

The first candidate's `_numeric_score` selects one of three explicit loops. Dot/L2 use one F64 accumulation per dimension; cosine keeps dot and both norms. No horizontal SIMD reduction, unchecked pointer access, query-validation removal, durable format change or graph/candidate change is introduced. Qdrant's local `lib/segment/src/spaces/simple.rs` also uses separate metric kernels; its F32/pre-normalized scoring is not substituted for native authority.

Baseline and candidate assembly are archived. The baseline Dot loop contains three `fmadd` instructions and two `fcsel` instructions per dimension; the candidate Dot/L2 loop each contains one `fmadd`. Checked Span access and the cosine zero-norm error remain.

Six new tests retain 270 baseline F64 score-bit fixtures across F32/BF16/F16/I8/U8, Dot/L2/cosine, dense/MaxSim, dimensions 1/2/3/7/16/127/128/129/1536, plus a cancellation/signed-zero case. Fixtures were generated from the unchanged `7b53ce9` source and independently checked before the candidate. Existing independent numeric goldens and finite-F32 extremes remain covered.

The isolated candidate passed **30 targeted Mojo / 358 full Python / C ABI/client / three examples**. This is not a new full Mojo/crash/distributed/GPU run. Sources and the copied binding entry were both isolated; child compiles used the Metal wrapper and saved-package pytest used `-o pythonpath=`. The native worker stayed unchanged at `bc064bc8…`.

## Metric-only diagnostic (not promoted)

One uninstrumented paired trial retains the original 8,192-point streams,
replacements/deletes, four filters, K=10, ef=32/64/128/256/512/1024 and all
67 queries per cell. All 1,608 exact oracle checks and 9,648 ANN audits pass;
4,824 paired samples have identical IDs, F64 score bits and statistics. Both
variants retain 25 below-target curve cells and reach .95 in all 12 selected
combinations at the same ef. There is no quality change or candidate pruning.

| Corpus | Filter | ef | QPS candidate/baseline | p95 candidate/baseline |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | 1.033 | 0.869 |
| uniform-128 | correlated | 128 | 1.016 | 0.947 |
| uniform-128 | independent | 256 | 0.952 | 1.146 |
| uniform-128 | selective | 128 | 0.987 | 1.031 |
| uniform-1536 | all | 512 | 1.053 | 0.909 |
| uniform-1536 | correlated | 512 | 1.030 | 0.979 |
| uniform-1536 | independent | 512 | 1.020 | 0.994 |
| uniform-1536 | selective | 256 | 1.020 | 0.941 |
| real-1536 | all | 32 | 1.034 | 0.933 |
| real-1536 | correlated | 32 | 0.993 | 1.037 |
| real-1536 | independent | 32 | 1.039 | 0.956 |
| real-1536 | selective | 64 | 0.999 | 0.984 |

This metric-only candidate is not promoted: modest high-dimensional gains do
not establish a stable overall improvement, and the slower cells remain in the
archive. A separate iterator experiment starts again from production `7b53ce9`,
keeping the original metric branches, to isolate the per-coordinate checked
indexing cost. Its ratios must not be multiplied by this experiment's ratios.

## Adopted iterator and validation

This experiment starts again from `7b53ce9`, retaining the original source-level
metric branches. Equal-length validation precedes `zip` so invalid inputs cannot
silently truncate. All public query/candidate/schema validation, ownership and
cosine zero-norm behavior remain. Empty equal pairs still return zero for Dot/L2;
cosine rejects them. Mismatched pairs now raise an explicit internal dimension
error. The new mismatch test failed on the baseline, then passed on the candidate;
the earlier test compile error caused by two mutable empty borrows is retained.

The [Mojo 1.0 zip API](https://mojolang.org/docs/std/iter/zip/) was confirmed with
the installed compiler. The tagged
[Span iterator source](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/collections/span.mojo)
checks the end before reading. Callers retain the authoritative vector owners;
no raw pointer or retained borrowed API is added. The resulting M4 assembly has
no per-coordinate error-string stores and now hoists all metric branches itself.
Tuple/iterator control overhead is still present; this is not a claim of an ideal
kernel or of the same performance on other CPUs.

The adopted candidate passed **31 targeted Mojo / 358 full Python / C ABI/client /
three examples**. After promotion, **7 score-bit Mojo / 91 native-oracle and named
Python / C client** passed. The production source and Python/C artifacts were
copied from the tested isolated variant. No new complete Mojo, crash, distributed,
Linux or GPU suite is claimed. The worker binary remains unchanged.

## Iterator fixed-corpus diagnostic

This separate paired trial uses the same complete corpus/filters/efs/query streams
as the first experiment. It independently passes **1,608 exact oracle checks /
9,648 ANN audits**, with **4,824 identical paired result/score-bit/statistic samples**.
Both variants retain 25 low-recall curve cells and the same selected ef in all 12
combinations. Ratios below compare the iterator directly with production baseline;
they are not multiplied by the metric-only results.

| Corpus | Filter | ef | QPS candidate/baseline | p95 candidate/baseline |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | 0.765 | 1.538 |
| uniform-128 | correlated | 128 | 1.129 | 0.723 |
| uniform-128 | independent | 256 | 0.967 | 1.076 |
| uniform-128 | selective | 128 | 1.209 | 0.852 |
| uniform-1536 | all | 512 | 1.117 | 0.835 |
| uniform-1536 | correlated | 512 | 1.091 | 0.914 |
| uniform-1536 | independent | 512 | 1.134 | 0.846 |
| uniform-1536 | selective | 256 | 1.074 | 0.915 |
| real-1536 | all | 32 | 1.041 | 0.939 |
| real-1536 | correlated | 32 | 1.045 | 0.944 |
| real-1536 | independent | 32 | 1.196 | 0.862 |
| real-1536 | selective | 64 | 1.107 | 0.959 |

The first 128D all cell regresses across its distribution (p50 491.9 → 641.0 µs,
p95 531.6 → 817.5 µs), not only in a single outlier. It is retained as a failure.
Three additional fresh 128D paired trials rerun **all six ef curves**, with
before/after, after/before, before/after process order. These independent follow-up
trials do not replace the first run. Each pair uses the unchanged original import,
updates, filters, exact checks and 67 queries per curve. They collectively retain
another 1,608 exact checks / 9,648 ANN audits / 4,824 bitwise/statistic matches.
Each variant/trial retains nine low-recall cells.

| Trial | Filter | ef | QPS candidate/baseline | p95 candidate/baseline |
|---:|---|---:|---:|---:|
| 0 | all | 128 | 1.036 | 0.971 |
| 0 | correlated | 128 | 1.090 | 0.847 |
| 0 | independent | 256 | 1.007 | 0.970 |
| 0 | selective | 128 | 0.976 | 1.145 |
| 1 | all | 128 | 1.125 | 0.744 |
| 1 | correlated | 128 | 1.292 | 0.719 |
| 1 | independent | 256 | 1.291 | 0.684 |
| 1 | selective | 128 | 0.989 | 0.942 |
| 2 | all | 128 | 1.020 | 0.979 |
| 2 | correlated | 128 | 1.015 | 0.940 |
| 2 | independent | 256 | 1.072 | 0.905 |
| 2 | selective | 128 | 1.139 | 0.895 |

The large 128D all regression did not repeat, but selective trials 0/1 still have
lower QPS and trial 0 has higher p95. No median hides these failures. Adoption is
supported by simpler checked iteration, identical outputs, high-dimensional gains
and the three repeated 128D all improvements; it does not claim every timing cell
improves. Previous named warm regressions and first-open/reopen graph construction
remain open. The original three-trial Qdrant warm/mixed gate was not rerun or
reclassified by these diagnostics. M5/M6, concurrent-client parity and sustained
nonresident/controlled-memory validation remain incomplete; no native Linux runner
is available.

## Evidence and reproduction

[Frozen archive](results/2026-10-03-native-metric-loops.json.gz):
4,902,212 bytes, 152 text files, SHA-256
`1084d5fc6c696fc0b2cd0bce1c116ca993524b0daa47eaf38940d5969fdbbfdb`. Every decoded file hash was verified.

The archive contains original phase traces, all three experiments' complete
curves and samples, the golden generator/output, baseline failure, isolated
sources, assembly, drivers, compiler wrappers, binary/input identities and test
logs. Official tagged-source URLs/hashes are retained, without copying whole
third-party source files. No preceding archive was rewritten. Tests report
milliseconds; public samples are nanoseconds. Builds, tests, benchmarks and
compression ran serially.

```sh
rtk proxy pixi run mojo --version
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_native_metric_bits.mojo
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD" OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 python NEW_OUTPUT/named-quality.py
```

For reproduction, copy `7b53ce9` source and package into a fresh output directory,
apply only the archived iterator `field_metrics.mojo` to its `after-src`, then
build that tree's `bindings/python_module.mojo` with the same include tree.
Adjust the validator's `OUT` and child-compiler wrapper to the fresh directory;
saved-package pytest must use `-o pythonpath=`. The repeated-trial driver's
package path must point to those new before/after packages. Drivers refuse
existing report/database paths; do not run them over archived outputs. Do not
replace production artifacts while tests are running.
