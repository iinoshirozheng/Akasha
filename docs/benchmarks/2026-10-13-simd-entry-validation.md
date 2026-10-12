# SIMD collection-entry validation probe — not adopted

An isolated one-function change replaced `PersistentCollection._validate_vector`'s
scalar finite-value loop with the existing `_prepare_f32_query(_DOT_METRIC, values)`.
Dimension validation remained first; dot preparation checks finiteness without
calculating a norm. No cache, format, scoring kernel or planner change was added.

**Not adopted:** full warm quality passes 36/36 for both versions, but strict
speed passes fall from 17/36 baseline to 16/36 prototype in this trial set.
Most high-dimensional differences are small, and the measurements do not show
a reliable improvement sufficient to justify replacing the existing path.
Production remains the mapped-recovery implementation `406eccd`.

The three rotating baseline/prototype/Qdrant triples per corpus retain the
same 8,192-point workloads, frozen efs, 64 measured queries plus three warmups,
K=10 and .95 recall gate. Every paired ID, F32 score bit and execution statistic
matches. Qdrant is Edge 0.8.0 and Mac builds use Mojo 1.0.0 with the Apple M4 /
Metal 4 flags. Each trial remains an independent QPS-and-p95 gate; medians do
not erase failed trials.

| Corpus / mode | Median QPS after/before | Median p95 after/before |
| --- | ---: | ---: |
| Uniform 128 / all | 1.039 | .984 |
| Uniform 128 / correlated | 1.229 | .499 |
| Uniform 128 / independent | .976 | 1.191 |
| Uniform 128 / selective | .879 | 1.203 |
| Uniform 1536 / all | 1.005 | .927 |
| Uniform 1536 / correlated | 1.006 | .993 |
| Uniform 1536 / independent | .999 | 1.002 |
| Uniform 1536 / selective | 1.031 | .939 |
| Real 1536 / all | 1.002 | .986 |
| Real 1536 / correlated | 1.000 | 1.002 |
| Real 1536 / independent | 1.011 | 1.006 |
| Real 1536 / selective | .995 | .964 |

The prototype passed 51 relevant Mojo tests: three new entry-validation cases,
nine SIMD, 14 persistent-filter, eight persistent-batch and 17 incremental HNSW
cases. New coverage checks NaN/Inf at every lane and tail, all three exact
metrics, approximate-query rejection, failed upserts preserving the existing
point, dimension errors preceding finite-value errors, and acceptance of
finite extrema, signed zero and subnormals. A fresh isolated extension was
built from its copied binding entry. Full Python, C ABI, Linux and mixed suites
were not rerun for this rejected probe.

Reviewing the original selective stack profile against its exact binary
confirmed that the sampled `_search_candidates` offsets 2400 and 2456 lie in
the fused candidate finiteness/norm/product loop. The sample aggregates
multiple instruction offsets; it does not isolate a percentage for each
operation. The original profile placed about 70% of main-thread samples in
that function, whereas independent-query validation plus norm preparation was
about 3%. These observations support refocusing on the dominant scoring and
mapped-distance work, not expanding the entry-validation change.

The [raw evidence](2026-10-13-simd-entry-validation.json.gz) contains the full
matrix, all latencies and response audits, source/binary identities, exact
driver and tests, validation logs, and the original binary's disassembled
candidate loop. Original sampling evidence remains in the
[resumed profiling archive](2026-10-12-mapped-probes.md).

SHA-256: `7131adc72705737c44ae414dd131c1fefbcd314b4944c889b03380dff2bb7728`.
