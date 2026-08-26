# Phase 13 GPU benchmark evidence

Actual-device validation is separate from the portable suite:

```bash
pixi run test-gpu
pixi run bench-phase13-gpu
```

On Apple silicon, install the optional compiler when Xcode requests it:

```bash
xcodebuild -downloadComponent MetalToolchain
```

The test gate executes Mojo kernels on the accelerator and compares dot,
squared-L2, cosine, tails, exact ties, filtered candidates, IDs, and Float32
scores with the CPU SIMD oracle. A skip or `used_gpu == false` fails this gate.
The portable test suite separately covers no-device/disabled fallback and an
injected launch failure.

One Apple silicon run on 2026-08-26 measured end-to-end squared-L2 latency over
2,000 points at 32 dimensions, including allocation, host mapping, kernel
launches, synchronization, and result mapping:

| Batch | CPU ns/query | GPU end-to-end p95 ns/query |
|---:|---:|---:|
| 1 | 197,000 | 13,802,000 |
| 8 | 193,375 | 1,717,875 |
| 32 | 9,438 | 484,469 |

This first kernel is a correctness baseline. Its Top-K kernel assigns one
thread per query and fresh buffers are allocated for each call, so it is not
expected to beat the mature CPU path on these small fixtures. The committed
planner therefore retains a configurable crossover threshold; future tuning
can add resident buffers and parallel reductions without changing query
semantics. These timings are not portable guarantees.
