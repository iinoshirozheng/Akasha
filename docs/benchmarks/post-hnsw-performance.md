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
