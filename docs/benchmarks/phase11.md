# Phase 11 benchmark evidence

Run from the repository root:

```bash
pixi run bench-batch
pixi run bench-phase11
```

The harnesses verify result correctness before printing timings. A local Apple
Silicon run on 2026-08-26 measured:

| Workload | Measurement |
|---|---:|
| 1 query × 10K points | 1.20× batch/sequential speedup |
| 8 queries × 10K points | 2.57× |
| 64 queries × 10K points | 26.28× |
| Owned snapshot capture, 10K × 16D | 160.9 ns/point |
| 8 concurrent WAL batches, 64 mutations | 79.5 µs/mutation |
| Threshold flush foreground portion | 0.663 ms |
| Background compaction drain | 0.793 ms |

These are development-machine observations, not portable latency guarantees.
The committed gates are deterministic IDs/scores, stable input ordinals,
bounded pending maintenance, correct final manifest state, and absence of
worker failures. Phase 12 adds repeatable recall/QPS/p95/memory thresholds for
quantized and persisted indexes.
