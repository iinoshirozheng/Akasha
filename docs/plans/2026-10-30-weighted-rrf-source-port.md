# Q01b: Qdrant weighted RRF source port

The full product scope remains in [the master ledger](2026-10-30-feature-completion.md).
This slice implements branch weights on the existing native/Python/Arrow field
fusion path, with the source-first, functionality-before-optimization workflow.

## Source and contract

- Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`,
  `lib/segment/src/common/reciprocal_rank_fusion.rs`: `position_score`, `rrf_scoring`.
- Public REST `Rrf` in `lib/api/src/rest/schema.rs` requires k >= 1, accepts
  optional F32 weights without a nonnegative constraint. DBSF's public query
  variant does not accept weights.
- Optional weights must match branch count exactly; omission means unit weights.
  F32 formula: `1 / ((rank + 1) / weight + k - 1)`. Weight <= 0 contributes zero
  but retains point IDs. Accumulate in branch/rank order, descending fused score.
- Preserve Akasha's positive k/rank-constant contract, ascending-ID ties, resource
  bounds, captured read view and optional final-field reranking. Reject nonfinite
  weights and fused scores, as with DBSF; document finite-range differences from
  upstream, including finite huge weights yielding infinity when k=1.
- `weights` is RRF-only; using it with DBSF is an error, not an ignored option.
- No durable-format changes, new dependencies, performance work or HTTP/gRPC
  compatibility claim. The universal-query protocol layers remain open in Q01/A01/A02.

## Work and acceptance

1. Extract both Rust functions verbatim from the pinned revision, compile a
   representation-only harness, and freeze bit-exact position/fusion/error cases.
   Include unit/default, fractional, zero/negative, empty/unequal rankings,
   overlap, multiple branches, large constants and F32 rounding boundaries.
2. Port the helper and validation to Mojo; pass weights through field fusion,
   snapshot/collection APIs, native binding, Python and Arrow. Keep the existing
   two-ranking helper consistent. No scoring implementation in Python.
3. Validate native position bits and fused results against Rust fixtures; test
   actual collection retrieval, filters, ANN/IVF, rerank, Arrow ownership,
   reopen, snapshot lifetime, cancellation/budgets, malformed weights and
   collection-close callbacks during conversion.
4. Build native worker/Python extension serially; run affected native modules
   and Python regressions. Record commands/results, provenance and adaptations;
   update the feature ledger and commit without pushing.

Status: implemented and verified for core/Python/Arrow. All four steps above
completed; [validation evidence](../research/2026-10-30-weighted-rrf-validation.md)
records the 300 position / 50 fusion reference cases, 19 native cases and 315
distinct Python cases. Q01 remains open for complete protocol exposure.
