# Shared sparse nearest execution

Continue after `f463e22`, under the full feature-completion plan. Q02 and the
other unfinished product capabilities remain open; no performance work resumes.

## Source and contract

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:
`sparse_vector_index/read_view/search.rs` chooses plain search for filtered
cardinality below 5000, otherwise indexed batches/final postings. The sparse
`VectorIndex` ignores SearchParams, including exact. `local_shard/query.rs`
rescoring builds a HasId filter from candidate IDs and invokes normal search.
The existing independent Rust search oracle covers the scoring paths.

1. Route named/default/point-store nearest search, point lookup, hybrid branches
   and sparse candidate reranking through the source-derived postings kernel.
   Exact and approx mean the same thing for sparse fields; dense HNSW-only
   parameters remain invalid. Reuse root-owned artifacts and captured visibility.
2. Remove obsolete flat/dictionary sparse search and per-run sparse copies.
   Separate value/validation definitions from index implementations to keep the
   shared source kernel dependency acyclic. Keep existing public imports intact.
3. Preserve the distinct finite-score recommendation contract. Ordinary nearest
   search uses source TopK admission: NaN, negative overflow and f32::MIN are
   omitted, positive overflow can remain. Extend the source oracle for these
   cases; keep the previous fixture reproducible instead of rewriting evidence.
4. Verify source IDs/F32 bits, zero paths, default/named/point-store/mutable-index
   entry points, candidate restriction, lookup exclusions, 4999/5000 boundary,
   lifecycle, filters, cancellation/budgets and Arrow. Run relevant native suites
   serially, rebuild bindings and run Python regression. Update contracts,
   provenance and validation report, then commit without pushing.

Full sparse configuration/IDF/cardinality estimation, input normalization,
service compatibility and the remaining multivector/datatype/Query API work
remain separate acceptance items; this plan does not claim full Qdrant parity.

## Verification outcome

Implemented and verified for the paths above: 214 source fixtures, 87 native
cases across 17 modules, 1693 distinct Python cases (168 new), and C ABI checks.
One optional Qdrant Edge case was skipped. The full Python invocation's initial
14 compiler-launch environment failures passed when rerun under Pixi; applicable
passing results were reused. See [validation](../research/2026-10-30-sparse-nearest-validation.md).
Q02 and all remaining functional/product gates are still open.
