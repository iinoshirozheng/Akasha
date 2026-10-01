# F32 query preparation in exact scans

Exact scans now validate the query and compute its cosine squared norm once per
scan, retaining full candidate validation and the existing score arithmetic.
The query stays immutably borrowed within the operation; the local prepared
scalar holds no pointer or owner and does not survive the call. Empty-result and
zero-norm behavior remain unchanged. Only `compute/simd.mojo`, `index/flat.mojo`
and the collection's exact candidate loop change. HNSW reranking continues to
use checked pair scoring; no data format, planner threshold, index, public API
or dependency changes. See the [design](../plans/2026-10-02-prepared-exact.md).

## Serial public warm comparison

Three fixed corpora, each with three rotating baseline/candidate/Qdrant triples:
**27 workers, 6,912 timed query audits, 324 warmups, 7,236 exact oracle checks and
108 passing recall cells**. Both Akasha versions have identical first-query,
warmup and measured IDs, F32 score bits and execution stats. No compiler, test or
archive compression overlaps the timed processes. These are resident Python
binding measurements from cloned closed databases, not HTTP or cold queries.
Selected ef values are frozen from the earlier symmetric grid; no retuning.

Before/after ratios are the median and complete range of three paired trials.
A QPS ratio above one and a p95 ratio below one indicate improvement.

| Corpus | Filter | QPS after/before | p95 after/before |
|---|---|---:|---:|
| uniform-128 | all | 1.108 (1.067–1.201) | 0.860 (0.772–0.980) |
| uniform-128 | correlated | 1.670 (0.998–1.921) | 0.587 (0.558–1.167) |
| uniform-128 | independent | 1.130 (1.089–1.761) | 0.702 (0.606–0.797) |
| uniform-128 | selective | 1.034 (0.798–1.206) | 0.953 (0.915–1.150) |
| uniform-1536 | all | 1.490 (1.490–1.579) | 0.668 (0.624–0.672) |
| uniform-1536 | correlated | 1.159 (1.147–1.165) | 0.884 (0.877–0.927) |
| uniform-1536 | independent | 1.077 (1.037–1.102) | 0.973 (0.913–0.994) |
| uniform-1536 | selective | 1.044 (0.956–1.131) | 0.952 (0.804–1.205) |
| real-1536 | all | 1.000 (0.954–1.175) | 1.010 (0.838–1.018) |
| real-1536 | correlated | 1.009 (0.995–1.016) | 0.979 (0.978–1.001) |
| real-1536 | independent | 1.010 (0.995–1.031) | 0.979 (0.945–0.993) |
| real-1536 | selective | 1.124 (1.114–1.142) | 0.878 (0.876–0.929) |

The 1536D all scan improves in every pair, as does real selective QPS and p95.
ANN cells are unchanged-path controls; their timing variation is not attributed
to faster HNSW. Uniform 128D selective trial 1 regresses (QPS .798, p95 1.150),
and uniform 1536D selective trial 2 also regresses (QPS .956, p95 1.205). These
samples remain in the report. This is not a claim of universal tail improvement.

## Strict Qdrant gate

Both baseline and candidate pass **16/36** matched-recall speed comparisons;
overall **FAILED**. The unchanged total does not offset failures: uniform 128D
selective trial 1 changes from passing to failing, while real selective trial 2
changes to passing. Every failed cell remains outstanding. The table shows the
median A/Q ratios and the number of individual pairs passing both requirements.

| Corpus | Filter | QPS A/Q | p95 A/Q | Both pass |
|---|---|---:|---:|---:|
| uniform-128 | all | 0.815 | 1.157 | 0/3 |
| uniform-128 | correlated | 2.285 | 0.557 | 3/3 |
| uniform-128 | independent | 2.721 | 0.380 | 3/3 |
| uniform-128 | selective | 0.883 | 1.047 | 0/3 |
| uniform-1536 | all | 2.573 | 0.389 | 3/3 |
| uniform-1536 | correlated | 1.484 | 0.774 | 3/3 |
| uniform-1536 | independent | 1.284 | 0.833 | 3/3 |
| uniform-1536 | selective | 0.841 | 1.246 | 0/3 |
| real-1536 | all | 0.793 | 1.380 | 0/3 |
| real-1536 | correlated | 0.646 | 1.382 | 0/3 |
| real-1536 | independent | 0.658 | 1.493 | 0/3 |
| real-1536 | selective | 0.852 | 1.153 | 1/3 |

The strict assessment exits 1 intentionally because the performance objective
is not achieved. All 36 candidate comparisons pass recall; no failure is hidden
by labeling quality alone as performance success.

## Rejected variants and diagnostic samples

The original prepared exact/rerank variant includes eight balanced-order pairs
per corpus. Its high-dimensional scan improvement is stable, but real ANN is
mostly unchanged and uniform 128D correlated p95 regresses. A separate ten-pass
128D repetition diagnostic retains all repeated samples; these are not additional
independent recall queries. After its six intended workers completed, the driver
hit a strict zip length mismatch because the corpus list was narrowed without
narrowing the ef list. The completed samples, failed exit, original driver and
corrected driver are retained; no successful measurement was rerun to hide it.

A forced-inline variant passes 85 targeted Mojo tests but regresses real ANN
QPS in several trials. Neither the forced inline nor prepared HNSW reranking is
adopted. The final version restores HNSW's checked pair path and the unprepared
kernel's original finite-mask expression. The initial isolated microbenchmark
is a local diagnostic only; its gain is not substituted for public measurements.

## Validation

The final candidate passes **88 affected Mojo tests** across eight files: the
87-test candidate run plus the updated nine-test SIMD suite replacing its earlier
eight-test entry. New coverage includes mutable caller queries, empty collections,
late invalid candidates, all finite extremes and signed zero. Existing filtered,
segmented, incremental and delta-scan results remain correct. Production source
bytes match the final isolated candidate, and the installed Python extension
matches the measured candidate binary exactly.

The complete Python suite passes **349 tests**. Rebuilt C ABI/client and three
examples pass all nine build/run steps. After that full suite, mixed and warm
benchmarks share the same strict speed gate; **16 targeted benchmark tests** pass,
including three additional mixed missing/invalid/below-recall cases. The previous
957-Mojo/23-crash CPU integration remains the prior full checkpoint; it is not
relabeled as a new full integration for this change. GPU paths and formats did
not change.

Baseline Python SHA-256:
`c2e0a6399b07d7a3ba34e4d7a6a993082b4ed73787c172a29c4bbbc892edb127`.
Final candidate Python SHA-256:
`3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`.

## Resident 90/10 read/write and maintenance

Both a saved-before/current-after comparison and a fresh Akasha/Qdrant comparison
complete nine pairs: each has **5,184 query audits, 72 individual recall cells and
18 reopened exact-oracle checks** passing. The before/after run retains 18 Arrow
leases; the Qdrant comparison retains nine Akasha leases. Each survives writes,
compaction and close, and the final lease release retires the old files. All three
workload plans match the prior ARM CRC experiment exactly. No benchmark overlaps
a build, test or archive compression.

The before/after query ratios retain every tail sample. High-dimensional exact
scans improve, but ANN and short selective cells remain noisy. In particular,
uniform 128D independent p95 has a 2.663 after/before trial and real all has a
2.252 trial. These are not discarded or described as no regressions.

| Corpus | Filter | QPS after/before | p95 after/before |
|---|---|---:|---:|
| uniform-128 | all | 1.177 (1.081–1.244) | 0.816 (0.577–1.102) |
| uniform-128 | correlated | 1.038 (0.979–1.174) | 0.950 (0.617–1.267) |
| uniform-128 | independent | 1.089 (0.862–1.297) | 1.135 (0.858–2.663) |
| uniform-128 | selective | 0.998 (0.862–1.196) | 0.815 (0.325–2.191) |
| uniform-1536 | all | 1.362 (1.336–1.416) | 0.727 (0.710–0.839) |
| uniform-1536 | correlated | 1.163 (1.091–1.279) | 0.790 (0.718–0.951) |
| uniform-1536 | independent | 1.135 (1.037–1.157) | 0.796 (0.717–1.018) |
| uniform-1536 | selective | 1.065 (0.996–1.313) | 1.011 (0.585–1.526) |
| real-1536 | all | 0.976 (0.870–1.116) | 0.986 (0.864–2.252) |
| real-1536 | correlated | 0.993 (0.972–1.108) | 1.030 (0.939–1.048) |
| real-1536 | independent | 0.982 (0.951–1.133) | 1.007 (0.830–1.108) |
| real-1536 | selective | 1.056 (0.970–1.479) | 0.899 (0.881–0.913) |

The fresh Qdrant mixed run passes **23/36** strict query comparisons and exits 1,
with all nine pairs completed and all 36 matched quality cells passing. Some
cells have a better p95 but insufficient QPS; both gates are required. This run
is separate from the warm-only matrix and cannot offset its failures.

| Corpus | Filter | QPS A/Q median | p95 A/Q median | Both pass |
|---|---|---:|---:|---:|
| uniform-128 | all | 2.101 | 0.367 | 3/3 |
| uniform-128 | correlated | 2.822 | 0.424 | 3/3 |
| uniform-128 | independent | 3.800 | 0.259 | 3/3 |
| uniform-128 | selective | 1.812 | 0.864 | 2/3 |
| uniform-1536 | all | 2.177 | 0.488 | 3/3 |
| uniform-1536 | correlated | 1.464 | 0.752 | 3/3 |
| uniform-1536 | independent | 1.278 | 0.861 | 3/3 |
| uniform-1536 | selective | 0.743 | 1.493 | 0/3 |
| real-1536 | all | 0.994 | 0.643 | 1/3 |
| real-1536 | correlated | 0.898 | 0.708 | 1/3 |
| real-1536 | independent | 0.580 | 1.332 | 0/3 |
| real-1536 | selective | 0.898 | 0.961 | 1/3 |

Write/maintenance values remain separately reported, in milliseconds. The p95
of update+flush is calculated from each block's own sum, not by adding separate
quantiles. Akasha batch acceptance fsyncs its WAL, while Qdrant's update and flush
have different durability boundaries; write-only latency is not equivalent.

| Corpus | Update+flush p95 A / Q | Post-write open median A / Q |
|---|---:|---:|
| uniform-128 | 25.337 / 39.023 | 92.675 / 60.775 |
| uniform-1536 | 57.460 / 35.656 | 147.045 / 53.551 |
| real-1536 | 47.411 / 38.962 | 159.349 / 60.562 |

The adopted code does not change writes, flush or reopen. Their before/after
variation is retained in raw samples and is not attributed to query preparation.
High-dimensional combined write latency and cached reopen still miss Qdrant.
This experiment does not rerun file-data-cold open, constrain memory, or establish
sustained nonresident or concurrent-client parity. The remaining network and Git
sandbox limitations are unchanged.

## Frozen evidence

The [prepared-exact evidence archive](results/2026-10-02-prepared-exact.json.gz)
contains raw warm and mixed reports, all retained slow samples, rejected variants,
the repetition-driver failure, source snapshots/deltas, source and binary identity,
test output and C build/run logs. Size: **19,639,625 bytes**. SHA-256:
`c6822b3054fe404e043e04ae5a47f48f68fc8a3b3a436abc7c8282bb7a559567`.

The archive is immutable. Local `.build` drivers and outputs are working copies;
do not overwrite historical evidence or rerun an old build driver against newer
production sources. The [handoff](../handoff/2026-10-02-status-and-tests.md)
distinguishes the latest targeted validation from the previous full integration.
