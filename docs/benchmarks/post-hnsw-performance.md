# Post-HNSW performance measurements

## Environment and interpretation

Measured locally on 2026-09-07: Apple M4 Pro, Mojo 1.0.0 (`ed45d567`), MAX
26.5.0, optimized compiler defaults. These numbers are diagnostic measurements,
not portable latency promises. Durable formats and the existing deterministic
quality datasets remain unchanged.

## 32: MemTable and borrowed access

Command: `pixi run mojo run -I src benchmarks/mojo/memtable_bench.mojo`.
Each case inserts unique IDs, 64 F32 values and a 256-byte string payload,
looks up all IDs (owned `get`), and materializes sorted owned records once.
The scrambled permutation is `(ordinal * 7919) % count`. Baseline is main
`71f86cf`; raw logs and its compiled executable are in `.build/post-hnsw/`.

| Points / ID order | Ingest before / after (ms) | All owned gets before / after (ms) | Sorted owned records before / after (ms) |
| --- | ---: | ---: | ---: |
| 4,096 / reverse | 8.230 / 1.822 | 6.919 / 0.500 | 39.897 / 0.758 |
| 16,384 / reverse | 112.267 / 6.531 | 110.056 / 2.266 | 617.973 / 4.170 |
| 65,536 / reverse | 1,733.674 / 26.045 | 1,719.959 / 9.799 | 9,816.712 / 16.530 |
| 65,536 / scrambled | 1,810.174 / 24.354 | 1,720.835 / 25.907 | 5,086.979 / 31.227 |

These are one sample per cell, sufficient to identify the large algorithmic
cost, not p95 estimates. The derived ID dictionary adds memory proportional to
slot count (including tombstones). Live count reads one maintained integer.
Owned output sorts lightweight integer IDs with the standard-library sort;
the entry slots themselves do not move except at the existing recovery merge
boundary, which rebuilds the lookup and count.

Exact, filtered, parallel and GPU preparation paths borrow immutable slots.
Filtered candidate lists contain ordinals, not copied records. Snapshot export
copies each returned vector and payload once. SQ8/PQ preparation preserves ID
ordering, and rerank uses ID lookup plus borrowed F32 values. WAL and segment
encoding still request owned records explicitly.

## GPU correctness baseline before 32

`pixi run test-gpu` passed all three actual-device tests. The existing
`phase13_gpu_bench.mojo` at 2,000 points and 32 dimensions reported:

| Batch | CPU ns/query (one sample) | GPU end-to-end p95 ns/query (five samples) |
| ---: | ---: | ---: |
| 1 | 209,000 | 13,102,000 |
| 8 | 57,875 | 1,688,625 |
| 32 | 12,593.75 | 493,812.5 |

Five-sample nearest-rank p95 is the maximum. CPU and GPU sample policies differ;
these numbers locate a problem and must not be used as a generalized speed ratio.

## 33: Production-path quality and scaling workloads

`pixi run check-post-hnsw-quality` exercises all 11 supported metric/scalar
pairs at 512 points × 32 dimensions, with replacements, deletes and four filter
modes. All 11 cells passed a 0.95 mean recall gate; the three ANN modes had zero
fallback, while the selective mode explicitly reported exact execution.
`test_segmented_hnsw.mojo` also passed all 18 tests after extracting the internal
candidate seam. The existing locked datasets and thresholds are unchanged.

The larger diagnostic runner is `benchmarks/post_hnsw.py`:

- `--profile representative`: 22 cells, two seeds, all 11 metric/scalar pairs,
  8,192 points, 384/768/1536 dimensions, uniform/clustered distributions and
  25/75/100 percent initial base sizes. Each cell has 10 percent replacements,
  approximately 2.5 percent deletes, 64 measured queries per filter mode and
  three warmups. IDs are shuffled with deterministic Fisher–Yates.
- `--profile full`: the full cross-product of those dimensions, seeds,
  distributions, base ratios and metric/scalar pairs.
- `--profile scaling --queries 32`: 4,096, 16,384 and 65,536 points at 64
  dimensions. Timings separate initial ingestion, explicit base construction,
  delta ingestion and later mutations; all include actual collection work.
- `--profile cell --points 16384 --dimension 768 --metric cosine --scalar bf16
  --seed 67890 --base-percent 75 --update-percent 10`: one reproducible cell.

Each output directory contains a provenance manifest, raw logs, per-query JSON
and aggregate CSV. Timings cover public collection calls, including filter,
planner, traversal and authoritative F32 rerank. They exclude Python/HTTP,
initial snapshot capture and diagnostic candidate extraction. Paired exact/ANN
call order alternates across queries in the current runner; p50/p95 use nearest
rank over the recorded query samples. Hardware/load still affect timing.

Candidate recall is measured by a separate untimed call to the same production
candidate collector, before any exact fallback or rerank. Final recall and
fallback reason come from the public query. ANN-only modes fail if they use exact
fallback. The selective mode has a nonempty ~1/32 filter and reports its exact
execution separately. Large workloads are diagnostic by default; an explicit
`--min-recall` can enforce a threshold without changing any existing CI gate.

Initial larger observations (seed 12345, ef=128, 64 queries/mode):

| Workload | All / correlated filter / independent filter Recall@10 | ANN exact fallback |
| --- | --- | --- |
| 8,192 × 384, uniform dot F32, 25% initial base | 0.9078125 / 0.8921875 / 0.8625 | 0% |
| 8,192 × 768, clustered dot BF16, 75% initial base | 1.0 / 1.0 / 1.0 | 0% |

These observations demonstrate why the small deterministic gate cannot establish
quality across workloads. The first run used exact-first paired timing; use its
recall/counter data, not a strict CPU/ANN latency ratio. Expanded results will be
recorded as the matrix finishes.

## 34: Snapshot GPU resource reuse and ragged batches

`GpuSnapshotState` owns one serialized MAX stream and F32 device image. Collection
GPU calls retain a cached `ReadSnapshot`; writes drop the collection's reference,
while active queries keep their own lease. Sequence/generation changes select a
new snapshot. Scratch storage is reused within budget, trimmed when a later
budget is smaller, and discarded after a stream failure. Filtered batches use
one positions buffer and per-query offsets, including empty candidate sets.

Seven actual-device tests passed, including four new cache/ragged/concurrent
cases. CPU planner/fallback, batch and snapshot regressions also passed. The new
`gpu_pipeline_bench.mojo` uses three warmups, 31 paired CPU/GPU samples, alternating
measurement order and differential verification outside timing. Cold GPU uses
the stateless entry point; resident GPU reuses one snapshot. Snapshot capture is
outside these measurements. Profiling syncs are a separate diagnostic call.

| L2 workload | Before 34 snapshot GPU p50 (ms) | 34 resident GPU p50 (ms) | 34 cold GPU p50 (ms) |
| --- | ---: | ---: | ---: |
| 2,000 × 32, batch 1 | 12.664 | 12.079 | 13.210 |
| 2,000 × 32, batch 32 | 14.772 | 14.523 | 15.628 |
| 8,192 × 384, batch 1 | 54.518 | 45.949 | 54.971 |
| 8,192 × 384, batch 32 | 65.283 | 57.079 | 65.940 |

Baseline source was extracted from `94ff55f`; all 31 samples in each of six
workloads passed ID/score differential checks before and after. One HNSW quality
build occupied another CPU core during this diagnostic comparison; these are
not the final planner calibration measurements. At 2,000 × 32, batch 1, a
resident profiling call reported zero buffer allocations, zero vector upload,
0.528 ms query mapping, 0.130 ms distance+sync, 10.904 ms serial Top-K+sync and
0.617 ms readback. Resource reuse removes the data preparation cost, but serial
Top-K still dominates. Host mapping times are not device-only DMA timings.

## 35: fused distance and parallel Top-K

The MAX 26.5 [`persistent_topk_block`](https://github.com/modular/modular/blob/max/v26.5.0/max/kernels/src/nn/topk_bitonic.mojo)
was inspected. It consumes a dense score tensor and emits 32-bit column indices;
Akasha needs fused scoring, ragged candidates and 64-bit public-ID ties. The new
kernel uses the same partition/merge approach: 256 points per block, cooperative
warp dimension sums, compile-time metric selection, shared-memory partial Top-K,
and a deterministic block merge. Query and point norms are computed once. No
batch×points score matrix is allocated. Arbitrary configured block sizes retain a
scalar-per-point path when they cannot form full warps.

All eight actual-device tests passed, including 72 dense/ragged configurations
with N=769, D=33, K=1/10/257/800, block sizes 7/32/256, negative and >32-bit IDs,
ties crossing tiles, empty/singleton candidate sets and partial final tiles.
Four planner tests passed, including a 128×100,000×32 workload under 32 MiB whose
old dense score matrix alone would require 51.2 MB. Very large K still needs
O(tiles×min(K,256)) partial storage and repeated block reductions; it is not a
constant-memory sort. Non-finite norm arithmetic falls back to the CPU contract.

Same 31-sample paired harness, seed and machine as 34 (one background HNSW build
was still running; diagnostic figures, not universal speed guarantees):

| N | D | Batch | 34 resident p50 ms | 35 resident p50 ms | 35 cold p50 ms | CPU p50 ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2,000 | 32 | 1 | 12.079 | 2.149 | 3.206 | 0.017 |
| 2,000 | 32 | 32 | 14.523 | 4.198 | 5.038 | 0.424 |
| 8,192 | 384 | 1 | 45.949 | 2.581 | 11.842 | 0.473 |
| 8,192 | 384 | 32 | 57.079 | 6.239 | 15.058 | 3.301 |

Resident 8,192×384×32 now retains 12,857,752 device bytes. Stage profiling separates
`distance_partial_topk_sync_ns` from `merge_sync_ns`; both include launch and
synchronization overhead. These GPU paths remain slower than CPU at these shapes.
Raw logs: `.build/post-hnsw/gpu35-*`; compile and execute the same commands as 34.

## 36: compact loads and accumulator measurements

A 2-second native `sample` of the original 8,192×1,536 uniform F16 build placed
1,512/1,664 main-thread samples in member/member distance and 133 in query/member
distance. Allocation had one sample. The original run was stopped after more than
40 minutes without a complete cell; its partial timing is not reported as a result.
The evidence prioritizes scalar decode over another build-scratch refactor. Existing
construction/search scratch and reciprocal-link contracts remain in use.

Generated ARM64 assembly confirmed per-byte bounds checks, scalar `fcvt` and stack
lane insertion. The dot specialization already eliminated the unused L2 arithmetic.
Owned and mmap distance paths now use bounded packed loads. Float conversion keeps
finite-value checks; I8 widens packed signed bytes and still validates the maximum
code and safe accumulation bound. Mapped loads return copied SIMD values and do not
expose raw pointers beyond their owner. Tails and unaligned ranges remain bounded.

`compact_distance_bench.mojo` covers all 11 supported backend tags and dimensions
31/384/768/1536, five samples of 2,000 calls with changing slots. On Apple M4 Pro,
median nanoseconds/call at D=1,536 (dot):

| Scalar | Query before | Query after | Member before | Member after |
| --- | ---: | ---: | ---: | ---: |
| F32 | 274.5 | 285.0 | 274.0 | 287.5 |
| BF16 | 2986.5 | 340.0 | 5555.5 | 351.0 |
| F16 | 3062.5 | 346.5 | 5608.0 | 353.0 |
| I8 | 3947.0 | 291.5 | 3829.5 | 322.0 |

Assembly now contains packed `fcvtl`, BF16 `shll`, and I8 `sshll` conversions. The
portable implementation does not assume native integer dot-product instructions.
The separate accumulator benchmark compares one/two/four native register groups:
at D=1,536, dot was roughly 281/137/76 ns and L2 290/154/81 ns. General exact SIMD
kernels use four groups at dimensions >=64 and keep the original narrow short-vector
loop. HNSW floating accumulation order is retained.

Validation includes all 65,536 encodings for each F16/BF16 representation, signed
I8 extension, invalid/truncated/closed mmap access, high-dimensional scalar/SIMD
comparison, all 11 owned/mapped/segmented backend pairs, compact rerank quality and
existing locked F32 quality gates. The broader production matrix is separately
reported under 33; microkernel timings do not imply collection-level speedups.

Reproduce:

```sh
pixi run mojo run -I src benchmarks/mojo/compact_distance_bench.mojo
pixi run mojo run -I src benchmarks/mojo/simd_accumulator_bench.mojo
pixi run mojo build --emit asm -I src benchmarks/mojo/compact_distance_bench.mojo -o /tmp/compact.s
```
