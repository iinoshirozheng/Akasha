# HNSW F32 milestone baseline

Recorded on 2026-08-28. Recall and recorded distance-evaluation counts are
deterministic gates. Wall-clock measurements are local diagnostics only; they
are not portable performance requirements.

## Environment

- Hardware: Apple M4 Pro, 14 logical CPUs, 24 GiB RAM
- OS: macOS 26.5.2 (build 25F84), Darwin 25.5.0, arm64
- Mojo: 1.0.0 (`ed45d567`)

## Automated quality gate

Command:

```text
pixi run mojo run -I src tests/mojo/test_hnsw_quality_gate.mojo
```

The fixed uniform dataset uses SplitMix64 seed `0xD1B54A32D192ED03`, 8,192
points, 64 F32 dimensions, 24 independently generated queries, `k=10`, and
`efSearch=64`. Every metric uses `M=24`, `M0=48`,
`efConstruction=192`, maximum level 32, and level seed
`0xA5A5A5A5A5A5A5A5`.

| Metric | Recall@10 |
| --- | ---: |
| Dot | 0.9625 |
| Squared L2 | 0.9708 |
| Cosine | 0.9875 |

The construction-work gate builds the identical L2 dataset prefix at 512 and
1,024 points. It recorded 4,291,998 and 12,202,115 distance evaluations,
respectively, for a 2.843 ratio. The required limits are recall@10 >= 0.95 for
every metric and a 2N/N construction-distance ratio < 3.5.

## Compact-vector production quality gate

Task 26 reuses the deterministic Task 1 uniform and eight-cluster generators
with the smoke-sized 256 points, 16 dimensions, 12 queries, `k=10`,
`efSearch=64`, `M=24`, `M0=48`, `efConstruction=192`, maximum level 16, and
seed `0xA5A5D00D12345678`. The production path collects compact-HNSW candidate
breadth and exact-reranks it against authoritative F32 MemTable vectors through
`SegmentedHnsw` and `HnswIdOrdinalLookup`. Every supported cell below records
F32 recall@10 1.0, compact recall@10 1.0, and loss 0.0:

| Scalar | Metrics | Uniform loss | Eight-cluster loss |
|---|---|---:|---:|
| BF16 | Dot, squared L2, cosine | 0.0 | 0.0 |
| F16 | Dot, squared L2, cosine | 0.0 | 0.0 |
| I8 | Dot, cosine | 0.0 | 0.0 |

I8 squared L2 remains a configuration error. A direct graph-only diagnostic,
which intentionally omits the required authoritative rerank, exposes
tie-sensitive worst losses of 0.141667 for BF16 cosine, 0.033333 for F16
cosine, and 0.25 for I8 cosine on the eight-cluster fixture. Those values are
not the public search path or the shipping gate, but remain printed by the test
so changes to candidate quality stay visible.

At dimension 16, the F32 vector section is 64 bytes/point, BF16 and F16 are 32
bytes/point (2x smaller), and the I8 vector tape is 16 bytes/point (4x smaller).
I8 dot also stores a four-byte F32 scale per point: its actual vector-plus-scale
payload is 20 bytes/point, a 3.2x reduction. I8 cosine uses the fixed `1/127`
scale and has no per-vector scale section.

## Non-smoke quality benchmark

Command:

```text
pixi run bench-hnsw-quality
```

Both shapes use SplitMix64 seed `0xA5A5D00D12345678`, 10,000 points, 64 F32
dimensions, 100 queries, `k=10`, `efSearch=64`, `M=24`, `M0=48`,
`efConstruction=192`, and maximum level 16. The packed-size number is a stable
estimate from live tape lengths; it excludes allocator capacity and hash-map
overhead and is not a persistence-format promise. The local ANN timer starts
immediately before each `HnswIndex.search` call and stops immediately after it;
query generation, exact FlatIndex search, stats reads, and recall accounting
are outside the timed interval.

| Shape | Metric | Recall@10 | Build distances | Directed edges | Avg visited / query | Avg search distances / query | Packed size estimate | Local ANN ns / query |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform | Dot | 0.948 | 236,372,943 | 466,368 | 2,378.12 | 2,378.12 | 4,855,664 B | 333,220 |
| Eight-cluster | Dot | 1.000 | 73,385,618 | 96,124 | 323.28 | 323.28 | 4,855,664 B | 105,330 |
| Uniform | Squared L2 | 0.961 | 269,865,610 | 427,120 | 2,367.06 | 2,367.06 | 4,855,664 B | 468,400 |
| Eight-cluster | Squared L2 | 1.000 | 132,235,844 | 427,452 | 1,089.27 | 1,089.27 | 4,855,664 B | 190,400 |
| Uniform | Cosine | 0.952 | 213,515,719 | 479,112 | 2,376.06 | 2,376.06 | 4,855,664 B | 331,860 |
| Eight-cluster | Cosine | 1.000 | 132,800,920 | 425,560 | 1,084.68 | 1,084.68 | 4,855,664 B | 187,580 |

The larger benchmark is diagnostic rather than the CI oracle. In particular,
its independent 10,000-point uniform dot sample records 0.948 while the locked
CI dataset clears the required 0.95 gate; both values are retained so future
changes can be compared without moving either dataset or threshold.

## Local latency diagnostic

Command:

```text
pixi run bench-hnsw
```

The existing latency benchmark uses squared L2, 1,000 points, 16 dimensions,
20 repeated queries, `k=10`, `M=16`, `M0=32`, `efConstruction=128`, and
`efSearch=64`. It recorded 4,371,238 build distance evaluations, 112 average
visited slots per query, and 50,000 ns/query. The time value is a local
diagnostic and can vary with load, compiler state, and hardware.

## Final production-HNSW verification

Recorded on 2026-09-07 on the same Apple M4 Pro, macOS 26.5.2 build 25F84,
Darwin 25.5.0 arm64, 14 logical CPUs, 24 GiB RAM, and Mojo 1.0.0
(`ed45d567`). The final run used the same commands and seeded datasets as the
Task 14 baseline:

```text
pixi run mojo run -I src tests/mojo/test_hnsw_quality_gate.mojo
pixi run bench-hnsw-quality
pixi run bench-hnsw
```

The locked 8,192-point recall values remained Dot 0.9625, squared L2 0.9708,
and cosine 0.9875. Construction work also remained 4,291,998 distances at 512
points and 12,202,115 at 1,024 points, ratio 2.843. These deterministic gates
did not regress.

The table compares the original Task 14 10,000-point record with the final
instrumented run. `Build time` sums only the HNSW `add` call durations; Task 14
did not capture this seam, so no honest before value exists. Timing columns are
diagnostic, while recall and counter columns are reproducible contracts.

| Shape | Metric | Recall before → final | Build distances before → final | Final build time | Avg visited/distances before → final | ANN ns/query before → final |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Uniform | Dot | 0.948 → 0.948 | 236,372,943 → 236,372,675 | 10.649 s | 2,378.12 → 2,378.12 | 333,220 → 187,680 |
| Eight-cluster | Dot | 1.000 → 1.000 | 73,385,618 → 73,385,409 | 7.904 s | 323.28 → 323.29 | 105,330 → 94,820 |
| Uniform | Squared L2 | 0.961 → 0.961 | 269,865,610 → 269,865,615 | 10.505 s | 2,367.06 → 2,367.06 | 468,400 → 144,410 |
| Eight-cluster | Squared L2 | 1.000 → 1.000 | 132,235,844 → 132,235,885 | 8.859 s | 1,089.27 → 1,089.27 | 190,400 → 118,870 |
| Uniform | Cosine | 0.952 → 0.952 | 213,515,719 → 213,515,634 | 10.549 s | 2,376.06 → 2,376.08 | 331,860 → 154,790 |
| Eight-cluster | Cosine | 1.000 → 1.000 | 132,800,920 → 132,807,075 | 8.966 s | 1,084.68 → 1,084.70 | 187,580 → 119,310 |

The packed owned-layout estimate stayed 4,855,664 bytes for all six runs. The
actual v2 serialized sidecars were 4,867,460 B (uniform dot), 3,386,484 B
(cluster dot), 4,710,468 B (uniform L2), 4,711,796 B (cluster L2), 4,918,436 B
(uniform cosine), and 4,704,164 B (cluster cosine). Variation is expected
because frozen adjacency serializes actual edge counts rather than mutable tape
capacity. Task 14 recorded only the estimate, so the final benchmark now emits
both fields rather than presenting unlike values as a before/after reduction.

The mmap base uses that sidecar directly and allocates no owned vector or
adjacency copy; pages are demand-paged and share the OS file cache. Per-index
resident bytes are not reliably measurable inside this benchmark because RSS
includes compiler/runtime and shared file-cache pages. Mapped/owned equivalence,
closed-view rejection, offset bounds, and base-plus-owned-delta behavior are
therefore release-tested as invariants rather than reported as a synthetic RSS
number.

Compact scalar evidence remains the production-path table above: BF16 and F16
pass dot/L2/cosine with zero measured public recall loss and halve vector bytes;
I8 dot/cosine passes with zero measured loss and uses 1/4 vector bytes before
the optional dot scale. I8/L2 remains deliberately rejected. The final small
latency diagnostic recorded 4,371,109 build distances, 112 visited slots/query,
and 49,950 ns/query versus 4,371,238, 112, and 50,000 in Task 14.
