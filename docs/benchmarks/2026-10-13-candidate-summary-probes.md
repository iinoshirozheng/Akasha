# Immutable F32 candidate summary experiments — not adopted

Four isolated prototypes cached candidate finiteness and the exact F32 cosine
squared norm on the immutable dense vector owner. The idea follows the existing
query preparation and owner sharing: derive once, preserve legacy raw bits,
and reuse during exact candidate scans. Qdrant's local reference
`lib/segment/src/spaces/simple.rs` preprocesses cosine vectors before its dot
kernel; Akasha must instead preserve its existing authoritative F32 score bits.

**None of these prototypes is adopted.** Long repeated selective diagnostics
improved, but the fixed full warm protocol retained regressions, especially in
high-dimensional selective queries. Production remains `406eccd`, the mapped
segment recovery change. The strict per-cell Qdrant gate remains FAILED.

## Design and correctness

The summary was stored inside `_DenseValue` and shared with the existing
immutable owner. It was recomputed after decoding and never serialized. Legacy
NaN/Inf remained accepted by legacy decoding and rejected when scored; new
typed construction retained its earlier finite-value validation. Candidate
dimension/finite/zero-norm error order and exact SIMD accumulation order were
preserved. HNSW normalization and traversal were not intentionally changed.

A compiled layout probe reports `VectorValue` as 64 bytes before and after.
`_DenseValue` grows from 48 to 56 bytes, matching the existing 56-byte
`_MultiValue`, so the enclosing variant does not grow. This establishes object
layout only, not a measured memory-cap improvement.

The first prototype passed 131 relevant Mojo cases and the complete Python
suite, 356 passed with three warnings. These cover SIMD extremes and raw score
bits, every invalid SIMD lane/tail, immutable shared owners after replacement,
typed values, point state, MemTable, recovery, migration, codec, compaction,
snapshots, filtered and segmented HNSW. Its four new cases compare cached
scores against the existing checked scalar/SIMD public-score path.

Each of the subsequent three implementations passed the same four new cases
and nine existing SIMD cases, followed by its own fresh Python-extension build.
The wider owner/codec tests apply to their unchanged owner representation;
they were not rerun as a full suite for every variant. No Linux or C ABI
validation was executed for these rejected variants. Prepared but unexecuted
drivers in the artifact must not be counted as passing checks.

## Experiments

All trials use the existing 8,192-point uniform-128, uniform-1536 and real-1536
fixtures, frozen efs, .95 recall target, K=10, 64 measured queries and three
warmups per mode. Mac Mojo 1.0.0 builds use the Metal 4 / Apple M4 flags. Each
full warm experiment rotates three before/after/Qdrant Edge 0.8.0 triples per
corpus and checks every before/after ID, F32 score bit and execution statistic.
Both sides pass quality 36/36 in each full matrix. Speed still requires both
QPS ≥ Qdrant and p95 ≤ Qdrant in every individual cell.

| Prototype directory prefix | Implementation | Full warm baseline / prototype speed passes |
| --- | --- | ---: |
| `cached-candidate` | Specialize the existing checked kernel for cached candidate facts | 18/36 → 20/36 |
| `cached-candidate-simple` | Reuse the existing unchecked dot/L2 helpers, keep the checked kernel unchanged | 15/36 → 16/36 |
| `cached-candidate-inline` | Inline the two leaf kernels | Not run; diagnostic trials only |
| `cached-candidate-full-inline` | Inline both wrappers and leaf kernels | 17/36 → 18/36 |

These are separate trial sets, with their own contemporaneous baseline. Their
pass counts cannot be compared as a cumulative improvement or used to pick a
favorable sample. The initial implementation's real-1536 all-mode warm QPS
median ratio was .907. Follow-up all-mode diagnostics gave a .960 median over
32 passes, then 1.000 over 256 passes, with all original slow pairs retained.
This did not establish an ANN improvement.

The simpler helper-reuse version slowed uniform-128 all-mode QPS to a median
.796 of baseline. Disassembly showed per-candidate calls to the leaf distance
kernels. Inlining only those leaves moved the call boundary to the wrappers;
the diagnostic low-dimensional regression remained. Inlining the complete
chain removed those calls, as verified in the archived disassembly.

The final prototype's 32-pass diagnostics produced these median paired ratios:

| Corpus / mode | QPS after/before | p95 after/before |
| --- | ---: | ---: |
| Uniform 128 / selective | 1.051 | .996 |
| Uniform 1536 / selective | 1.112 | .880 |
| Real 1536 / selective | 1.149 | .858 |
| Uniform 128 / all | 1.090 | .918 |
| Real 1536 / all | .984 | 1.030 |

All repeated responses match their preflight IDs and F32 bits. Repetitions
are additional latency observations, not independent recall samples. These
diagnostics pre-create and reuse Python query lists and repeatedly execute one
mode; they cannot replace the frozen full-matrix protocol, which also runs the
preceding modes and creates each query list immediately before its timed call.
The measured binding boundary itself remains request construction plus search.

The final full warm matrix exposes the limitation:

| Corpus / mode | Median QPS after/before | Median p95 after/before |
| --- | ---: | ---: |
| Uniform 128 / all | 1.094 | .905 |
| Uniform 128 / correlated | 1.036 | .949 |
| Uniform 128 / independent | .943 | 1.162 |
| Uniform 128 / selective | .960 | 1.124 |
| Uniform 1536 / all | 1.081 | .922 |
| Uniform 1536 / correlated | 1.056 | .971 |
| Uniform 1536 / independent | 1.070 | .929 |
| Uniform 1536 / selective | .952 | 1.174 |
| Real 1536 / all | .955 | 1.030 |
| Real 1536 / correlated | 1.000 | .971 |
| Real 1536 / independent | 1.021 | .964 |
| Real 1536 / selective | .928 | 1.123 |

In particular, all three real selective trials are slower in aggregate QPS;
their p50 values also regress. This cannot be dismissed solely as one tail
outlier. Other modes' improvements do not offset those cells. The source and
validation show a viable numerical optimization, but the measured tradeoff
does not justify adding this derived state to production now.

## Evidence

The [raw archive](2026-10-13-candidate-summary-probes.json.gz) retains all four
source variants and verified source/binary hashes, three complete warm matrices,
every short/long diagnostic, latency observations, IDs/score-bit audits,
execution statistics, disassembly, layout probe and validation logs. It also
records the initial missing-symbol red test as observed tool output; no
separate original stderr file was captured. Baseline source/build evidence is
in the [mapped segment report](2026-10-13-mapped-segment-read.md).

SHA-256: `dec83ef5c0f505414c6aea1fa2ff2e3709bda670d50e63c8744dba4e9da39d7d`.
