# Resumed profiling and rejected mapped-vector probes

The three pinned workloads were reconstructed from the immutable October 2
artifact and their checksums matched exactly. Each has 8,192 points, K=10,
64 measured queries plus three warmups per filter, seed 12345, and the original
replacement/delete state. Both engines' databases were rebuilt through their
public adapters. Fresh Akasha packages were built from copied source trees and
copied binding entry points; the stale root Python extension was not used.

| Workload | Verified SHA-256 |
|---|---|
| uniform-128 / Dot | `9cf402d6b6917046a9422f0800dddf740ecc9e50505abb41c11a25a2cd8e97a0` |
| uniform-1536 / Dot | `7b23e99079bb26134339ac2866df5ad6042776b2bc8f09a035198ce7d77d5c41` |
| real-1536 / Cosine | `1d1572212d5f703e74cc842dcc44693f198680594eab9438e72e9d014143b091` |

## Profile and decisions

Native stack sampling of real-1536 independent queries attributed about 52%
of main-thread samples to the mapped HNSW distance kernel, 9% to checked
reranking and 6% to owned delta distance scoring. Query validation and stable
norm preparation together were about 3%. Selective queries used exact scans;
about 70% of main-thread samples were in `_search_candidates`.
Repeated queries used to collect samples are diagnostic only and add no
acceptance samples or recall observations.

Two isolated prototypes retained close/bounds checks and the same numerical
accumulation order:

| Probe | Evidence | Decision |
|---|---|---|
| Checked `MappedBytes` scalar loads after validating the full vector range | Three paired independent-query QPS ratios: .984, 1.017, .974 | Not adopted; no stable gain |
| One SIMD32 mapped load split into two sequential SIMD16 accumulations | Longer 32-pass diagnostics improved QPS by about 2.6–4.0%; short trials were noisy | Not adopted; full warm results did not support an overall gain |

The SIMD32 probe passed 29 targeted Mojo tests (accumulators, mapped vectors,
distance dispatch and HNSW views). Query IDs, Float32 score bits, execution
statistics and warmup outputs remained identical in the paired checks.
Three rotating baseline/probe/Qdrant trials over all three corpora produced
27 serial workers and 36 comparison cells per Akasha version. Every quality
cell passed, but strict speed acceptance passed only **19/36** baseline cells
and **18/36** probe cells. Both matrices are **FAILED**. Real independent
queries improved consistently in these three warm pairs, while real all
regressed in two pairs; the local gain is insufficient to adopt the change.

The probe's mixed experiment completed the three uniform-128 triples, then
the unmodified baseline hung on uniform-1536. The unfinished experiment is
retained as a failure, not compared as a complete matrix. Diagnosis led to
the separately adopted [maintenance state fix](../research/2026-10-12-maintenance-shared-state.md).
Neither mapped-vector prototype is in production source.

## Environment and remaining gates

The Apple M4 Pro host has 24 GB RAM and other active applications. A recorded
host observation showed approximately 16.9 GB swap in use and no thermal
warning. All benchmark workers and builds were serial, and all trials,
including noisy or failed trials, were retained. The fresh 19/36 warm result
is not a paired improvement over the historical 16/36 result: host state and
rebuilt graphs differ.

The previously sandbox-blocked distributed suite now ran successfully:
**10 passed**, using the freshly rebuilt `a710aa5` baseline package. This is
local network validation; it does not establish Linux runtime, GPU device,
memory-limit, sustained nonresident or concurrent-client performance gates.

[Raw profiles, reports, prototype diffs, binary identities, test logs and
drivers](results/2026-10-12-mapped-probes.json.gz), SHA-256
`9d392e56d3d224b8ecd8012a6cb0d7b375bb905096cbad1bd122528b16e9f813`.
The [separate fix report](../research/2026-10-12-maintenance-shared-state.md)
contains the completed post-fix mixed matrix: quality 36/36, speed 17/36.
M5/M6 remains open under the unchanged per-cell QPS and p95 requirements.
