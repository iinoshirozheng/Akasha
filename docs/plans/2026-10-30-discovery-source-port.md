# Q03b discovery/context source port

Status: implemented and verified for the scoped native/Python/Arrow paths.
Feature correctness only; no tuning or performance gate. Full Q03 remains open.

Source pin: Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0.
Read `segment/vector_storage/query/{discover_query,context_query}.rs`,
`collection/src/discovery.rs`, HNSW `read_view/search.rs` and `graph_layers.rs`.

1. Compile unedited upstream rank/loss/score methods with the existing portable
   scalar metric scaffold. Cover signed zeros, NaNs, infinities, rounding,
   dense/sparse/directional MaxSim and all three current metrics.
2. Port reducers and prepared scoring to Mojo. Share exact/HNSW execution with
   recommendation; preserve that public API and all previous contracts.
   Discovery final scores are bounded or NaN: map NaN to an ordering sentinel
   internally to preserve upstream OrderedFloat ranking, restore NaN on output.
3. Resolve target and context IDs against captured roots; exclude only local
   references before selection. Add collection/snapshot/Python/Arrow APIs,
   cancellation and resource validation. `k=0` returns empty before query
   resolution, matching the upstream single-query discovery path.
4. Dense HNSW discovery performs context search for up to 10 entry candidates,
   then discovery traversal from the highest-level eligible candidate (last
   tie), falling back to ordinary entries when none qualify. Context-only uses
   ordinary custom traversal. Retain native planner, stable ID ties and existing
   HNSW traversal lineage; do not claim graph-identical or REST/gRPC parity.
5. Verify source fixtures, native snapshots/entry selection, Python/Arrow,
   exclusions/filter/reopen/update, invalid inputs, controls and ANN integration;
   run the existing recommendation and named-query regression coverage.
6. Record hashes, notices, API documentation and acceptance evidence; commit
   locally on main. Keep nested prefetch, multivector HNSW, datatype/storage,
   full source planner and protocol gates explicitly pending in the master plan.

Acceptance: 336 upstream cases; 42 native tests across 8 modules; complete
Python suite 2005 passed / 1 optional skip, including 262 new discovery tests.
See [validation and remaining scope](../research/2026-10-30-discovery-validation.md).
