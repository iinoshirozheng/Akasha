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
