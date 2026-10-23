# Separate bounded Top-K rejection from heap insertion

Baseline is `8ba04ce`, kernel `3ec07dc3…`, Mojo 1.0.0 (`ed45d567`), Apple M4.
The unchanged exact-scan path in the previous frontier profile spent 7.74% of
main-thread samples in BoundedTopK; this denominator includes Python audit work.
The current F32 offer is an outlined 892-byte function with an approximately
2 KiB stack frame, even when a full heap rejects the candidate.

In an isolated source/package, split the existing offer into its small admission
comparison and a private insertion method. The latter keeps the original append,
sift and root replacement operations. Preserve runtime score direction, ID ties,
F32/F64 bits, capacity, drain/reuse, List checks and ownership. No inline annotation,
new cached threshold, comparator, unsafe view or heap algorithm is introduced.
This differs from the rejected official heap and HNSW heap-shift experiments.

Check compiled code before extensive measurement: the compiler must naturally
inline admission or otherwise remove material work from rejected offers. Validate
with the existing Top-K tests and an independent sorted-list oracle covering
both score types/directions, changing occupancy, duplicate/tied IDs, signed zero,
extremes, infinity and drain/reuse. Then run affected query tests and the original
fixed three-trial warm/mixed Qdrant cohort, retaining every sample and failure.
Broaden integration and named diagnostics only if evidence supports adoption.

Keep production source and binaries unchanged during evaluation. Benchmarks,
builds/tests and compression run serially. Freeze all source, commands, failures,
identities, disassembly and samples under `.build/2026-10-04-topk-admission` before
a semantic commit. A local adoption decision does not change the strict original
Recall@10 ≥ .95 / QPS ≥ Qdrant / p95 ≤ Qdrant gates or complete M5/M6.

## Outcome

Stopped at the compiled-code gate; not adopted. The compiler inlined the new
insertion method back into offer. F32/F64 offer remain 223/219 instructions with
the same stack frame; the exact caller remains 1,114 instructions and four static
offer calls. No public benchmark or broader integration was warranted by this
result. This is not a claim of measured equal latency.

Both sources pass eight targeted Mojo tests, including three new independent
oracle tests retained as `tests/mojo/test_topk_oracle.mojo`. Production engine and
binaries remain unchanged. Initial generic test compile errors and a premature
assembly read of the copied baseline binary are retained separately; the latter
was excluded and replaced by build-success/hash-guarded candidate disassembly.
