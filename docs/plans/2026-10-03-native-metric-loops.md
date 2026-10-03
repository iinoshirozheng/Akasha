# Native F64 metric loop specialization

Baseline: `7b53ce9`, Python binary
`7db8a2d6b20436c5efdc71dd92565d58c4037448c32fbd7bfbee6a81c19910a6`.

Named per-run profiling retains all 804 selected-ef query samples and verifies
IDs, F64 score bits and statistics against the preceding fixed-corpus run.
Native reranking takes about 32% of uniform-1536 all/correlated/independent
query time. The installed M4 binary's `_numeric_score[f32]` executes three
F64 FMAs and two conditional selections per dimension for Dot: two norms are
computed even though their results are unused. L2 has the same extra norms.
The compiler only hoisted the L2-versus-Dot branch, not the cosine branch.

Use three explicit loops selected once by metric in `_numeric_score`.
Keep native F64 conversions, sequential accumulation, cosine normalization,
zero-norm errors, checked Span indexing and all callers unchanged. No SIMD
reduction, prepared-query cache, pointer borrowing or new abstraction.
This affects named dense and MaxSim exact/rerank paths, not default F32 HNSW.

Local reference Qdrant `lib/segment/src/spaces/simple.rs` has separate metric
kernels. Its F32 reduction/pre-normalization is not Akasha's native F64
authority contract, so reuse only the outer metric-selection pattern.

Verify frozen baseline score bits across five scalar kinds, three metrics,
odd/even and high dimensions, cancellation/extreme inputs and MaxSim. Run
affected Mojo suites before full isolated Python/C ABI/examples. Build from
the copied binding entry and include tree; retain production binary until
validation and uninstrumented paired measurements support adoption.

Measure complete fixed named curves in both versions, including all failed
recall cells and slow samples. Inspect emitted code to confirm the two unused
norm accumulations disappear. Profile timestamps only attribute cost and are
not public latency results. Do not infer Qdrant parity from named diagnostics.
Freeze drivers, samples, sources, assembly, hashes and logs without changing
existing archives. M5/M6 remain open until their original gates pass.

## Follow-up after metric-only measurement

Metric-only branching passed 30 targeted Mojo, 358 full Python, C ABI/client
and three examples, with all 4,824 paired named samples bitwise/statistically
identical. Uniform-1536 selected QPS gains are only 2–5%; several other cells
regress. Do not promote it yet.

The emitted code also initializes checked-Span error strings on every indexed
coordinate. Test the standard `std.iter.zip` over the two borrowed Spans, with
an explicit equal-length guard before iteration (so zip cannot silently shorten
invalid input). Keep original per-coordinate metric branches to isolate this
second change against unchanged production. Owners remain with callers; no raw
pointer or retained borrowed API is introduced. Add a failing dimension-mismatch
regression and run the existing score-bit fixtures. Compiler-confirmed `zip`
is available in the installed Mojo 1.0.0; official API:
<https://mojolang.org/docs/std/iter/zip/>.

## Outcome

Adopt only equal-length validation plus `std.iter.zip` on the original metric
body. Do not combine the metric-only branch prototype into production. The full
iterator diagnostic and three complete 128D follow-up pairs retain identical
results/score bits/stats, high-dimensional gains and all first-run/repeated
regressions. See the benchmark report for per-trial ratios. Final isolated
validation: 31 targeted Mojo, 358 full Python, C ABI/client and three examples;
promotion: 7 Mojo, 91 Python and C client. M5/M6 remain open.
