# SIMD validation for authoritative reranking

The public authoritative F32 scorer validated both vectors with a scalar
finite-value check before every score. At D=1536 this cost approximately 1 µs,
while the prevalidated SIMD dot cost approximately 94 ns. The finite check now
uses bounded SIMD chunks plus a scalar tail. Empty/mismatched inputs and every
NaN/infinity remain errors; no input validation is removed. Floating-point
scoring and its reduction order are unchanged by this slice.

`pixi run mojo run -I src benchmarks/mojo/rerank_distance_bench.mojo` runs five
samples of 20,000 changing-row calls at D=31/64/384/1536. On Apple M4 Pro with
the pinned Mojo 1.0.0, medians at D=1536 are:

| Component | Before, ns | After, ns |
| --- | ---: | ---: |
| Validation alone | 994.4 | 145.4 |
| Prevalidated dot | 94.35 | 92.35 |
| Authoritative dot including validation | 1056.5 | 217.45 |

[Raw samples](results/2026-10-01-rerank-validation.json) include all dimensions
and checksums. Sampling ran without concurrent builds/tests; it is a paired
microbenchmark, not a Qdrant throughput result.

Verification: 9 distance, 6 SIMD distance and 10 flat-index tests pass. The
added SIMD test places positive infinity, negative infinity and NaN at every
position of dimensions 3/16/17/31/63/64/65/127, covering both operands and scalar
tails; finite subnormals remain accepted. After rebuilding the native binding,
the full Python suite passes **203 tests**, including Qdrant harness checks,
typed independent metric oracles and real Arrow ownership tests.
