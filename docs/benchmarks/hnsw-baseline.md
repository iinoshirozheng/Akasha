# HNSW F32 milestone baseline

Recorded on 2026-08-27. Recall and recorded distance-evaluation counts are
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

## Non-smoke quality benchmark

Command:

```text
pixi run bench-hnsw-quality
```

Both shapes use SplitMix64 seed `0xA5A5D00D12345678`, 10,000 points, 64 F32
dimensions, 100 queries, `k=10`, `efSearch=64`, `M=24`, `M0=48`,
`efConstruction=192`, and maximum level 16. The packed-size number is a stable
estimate from live tape lengths; it excludes allocator capacity and hash-map
overhead and is not a persistence-format promise.

| Shape | Metric | Recall@10 | Build distances | Directed edges | Avg visited / query | Avg search distances / query | Packed size estimate | Local ns / query |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform | Dot | 0.948 | 236,372,943 | 466,368 | 2,378.12 | 2,378.12 | 4,855,664 B | 837,490 |
| Eight-cluster | Dot | 1.000 | 73,385,618 | 96,124 | 323.28 | 323.28 | 4,855,664 B | 602,250 |
| Uniform | Squared L2 | 0.961 | 269,865,610 | 427,120 | 2,367.06 | 2,367.06 | 4,855,664 B | 790,300 |
| Eight-cluster | Squared L2 | 1.000 | 132,235,844 | 427,452 | 1,089.27 | 1,089.27 | 4,855,664 B | 659,620 |
| Uniform | Cosine | 0.952 | 213,515,719 | 479,112 | 2,376.06 | 2,376.06 | 4,855,664 B | 1,003,090 |
| Eight-cluster | Cosine | 1.000 | 132,800,920 | 425,560 | 1,084.68 | 1,084.68 | 4,855,664 B | 859,020 |

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
visited slots per query, and 51,550 ns/query. The time value is a local
diagnostic and can vary with load, compiler state, and hardware.
