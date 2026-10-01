# Four accumulator groups in F32 HNSW

The existing HNSW F32 kernels used one native-width accumulator chain. The
existing exact SIMD implementation and the local Qdrant `simple_neon.rs` use
four independent register groups for long vectors. HNSW now uses four groups
at dimensions >= 64, retaining the narrow loop below that boundary. Owned
query/member, member/member and mapped query/member use the same reduction
order. Packed BF16/F16/I8 kernels are unchanged.

This changes floating-point reduction order, so newly built approximate graphs
can differ at near ties. It does not change stored vector bytes, sidecar format,
public exact reranking or the reported native SIMD width. Loading an older
graph remains supported. Mapped loads still perform range checks and return
copied SIMD values; no mapping pointer escapes its owner.

## Microbenchmark

Apple M4 Pro, macOS ARM64, Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.
`pixi run mojo run -I src benchmarks/mojo/compact_distance_bench.mojo`
runs all 11 backend tags at D=31/384/768/1536, five samples of 2,000 changing-slot
calls each. No other builds or tests ran during either measurement. These are
successive baseline/changed runs, not randomized repeated process trials.

Median nanoseconds per distance at D=1536:

| F32 metric | Query before | Query after | Member before | Member after |
| --- | ---: | ---: | ---: | ---: |
| Dot | 258.0 | 83.5 | 246.0 | 94.5 |
| L2 | 264.5 | 89.5 | 255.0 | 94.0 |
| Cosine | 257.5 | 88.5 | 246.0 | 92.0 |

[All raw samples](results/2026-10-01-hnsw-accumulators.json) retain compact dtype
results and checksums as well. Microkernel improvements do not establish
Qdrant parity.

## Verification

- `test_hnsw_accumulators.mojo`: 3 tests, 24 dimension/metric combinations;
  independent Float64 accumulation over prepared F32 values, query/member and
  member/member tolerances, exact owned/mapped equality, result/ID equality,
  closed mapping and invalid-slot rejection. Dimensions 31/63/64/65/127/384/769/1536.
- `test_distance_dispatch.mojo`: 13 tests pass, including all 11 owned/mapped/
  segmented backend pairs and public dispatch counters.
- `pixi run check-hnsw-quality`: six locked smoke cells all Recall@5 = 1.0.
  These dimension-16 cells check short-path stability, not high-D acceptance.
- `pixi run build-python`: native extension rebuilt successfully.

## Full high-dimensional paired run

`pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps python benchmarks/qdrant_compare.py --output .build/qdrant-compare/hnsw-four-groups-1536 --dimension 1536 --trials 1`

The same 8192-point F32 dot workload, updates/deletes and query/oracle checksums
as the [retained-base baseline](2026-10-01-hnsw-base-reopen.md) passed all four
matched Recall@10 >= .95 cells. No concurrent builds/tests ran during sampling.
This is one fresh paired trial; Qdrant graph construction is not seeded.

| Stage | Retained-base baseline | Four-group F32 |
| --- | ---: | ---: |
| Ingest/build, seconds | 78.077 | 38.147 |
| New-process reopen, seconds | 3.859 | 2.108 |
| Mutation flush, seconds | .137 | .135 |
| All-points warm QPS | 145.13 | 171.59 |

The original pre-retention reopen cost was 75–76 seconds. OS page cache was
not evicted in any of these reopen measurements.

| Filter | Selected ef | Akasha recall | Qdrant recall | Akasha/Qdrant QPS |
| --- | ---: | ---: | ---: | ---: |
| All | 512 | .99375 | .99375 | .426 |
| Correlated | 512 | .9859375 | .9765625 | .177 |
| Independent | 512 | .9828125 | .9796875 | .183 |
| Selective exact | 32 | 1.0 | 1.0 | .284 |

[Raw paired report](results/2026-10-01-hnsw-four-groups-1536.json.gz) includes
source and binary hashes, configuration, raw latencies and query results.
The build improvement is much larger than the query improvement; remaining
query costs require separate measurement. Native `sample <pid> 5 1` profiling
was rejected by host process-inspection permissions; no privileged retry was
used. This slice does not establish Qdrant parity or complete M5/M6.
