# Prepare each F32 exact-scan query once

2026-10-02. Continue the authorized M5/M6 performance work under the user's
strict per-cell matched-recall QPS/p95 gate.

## Evidence and design

`FlatIndex._search` and `PersistentCollection._search_candidates` score the same
immutable F32 query against many authoritative vectors. The existing checked
SIMD kernel rechecks every query component for each candidate and recomputes
its cosine norm. Keep that kernel and its established SIMD width, accumulator
order, scalar tail, score polarity and candidate checks. Add a compile-time
prepared-query specialization; prepare finiteness and the cosine squared norm
once within each exact scan, after its existing empty-result return.

Use the existing scalar, SIMD and checked-pair APIs; add no package, persistent
cache, retained pointer or new public API. The prepared norm is a local F32 scalar
and is valid only for the unchanged query and metric during the synchronous
borrow. Candidate finiteness cannot be assumed: legacy F32 record readers
preserve raw bits. Zero-norm rejection remains after candidate validation.

The initial prototype also prepared HNSW rerank queries. Its public ANN benefit
was inconsistent; forcing the kernel inline further regressed some ANN cells.
Keep checked pair scoring for HNSW and scope the adopted change to exact scans.
The rejected prototypes and all slower samples remain part of the evidence.

## Validation and measurement

- Compare every score bit with the established arithmetic across SIMD widths,
  tails, dimensions through 1536, three metrics and varied magnitudes. Check every
  component's NaN/infinity rejection, mismatches, zeros, signed zero, finite
  extrema, underflow and overflow outcomes. Repeated public searches must prepare
  a mutated caller query anew; empty collections and late invalid candidates keep
  their validation behavior.
- Reuse relevant collection, segmented HNSW, filtered, delta-scan and incremental
  score tests. Run Python and C ABI/build checks. Persistence bytes, publication,
  crash ordering and GPU kernels are unchanged; retain their applicable prior
  results rather than claiming a new full CPU/crash/GPU run.
- Use the frozen corpora, oracles, filters and selected ef values. Compare saved
  baseline, candidate and pinned Qdrant in separate serial processes, rotating
  BAQ/AQB/QBA order. Keep first queries, warmups, all timed samples and failures.
  Compare before/after IDs, score bits and execution stats; require independent
  exact oracles and recall >= .95 before comparing speed.
- Apply QPS >= Qdrant AND p95 <= Qdrant to every cell, with no tolerance or
  cross-cell offsets. Also refresh resident read/write/flush comparison and
  retained Arrow leases. These experiments do not establish nonresident parity.
