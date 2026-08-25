# SIMD Exact Search and Bounded Top-K Design

## Scope and decisions

Phase 2 keeps the scalar distance functions as the correctness oracle and adds three CPU-SIMD equivalents for `Float32`: dot product, squared L2 distance, and cosine similarity. Public SIMD functions retain the scalar API's validation rules and reject non-finite input before entering pointer-based kernels. Kernels use the host `simd_width_of[DType.float32]()` for complete chunks and a scalar loop for the tail, so dimensions need not be a multiple of the hardware width. HNSW, threads, quantization, GPU execution, and platform-specific intrinsics remain out of scope.

Exact Top-K changes from selecting one winner per full scan to one full vector scan feeding a runtime-sized bounded heap. The heap root is always the worst retained result. A better candidate replaces the root and is sifted down; worse candidates are discarded. Metric direction and ascending-ID tie-breaking are explicit inputs, preserving current deterministic behavior. Final output is sorted best-first. This changes the search cost from roughly `O(k * N * d)` to `O(N * d + N * log(k) + k * log(k))`, while retaining the existing `FlatIndex` public API.

## Error handling and verification

Scalar and SIMD functions reject empty vectors, dimension mismatches, NaN, and positive or negative infinity. Cosine additionally rejects zero norms. Tests compare SIMD against scalar results for dimensions smaller than, equal to, and not divisible by the host SIMD width. Top-K tests exercise capacity, replacement, metric direction, deterministic ties, and integration with `FlatIndex`.

The phase is complete only when focused red-green tests, the full Mojo/Python suite, optimized build, smoke test, and formatter all succeed. A benchmark is added as an executable harness, but this phase does not promise a speedup until release-mode measurements demonstrate one. The Pixi build task also creates `.build/` so a clean checkout is reproducible.
