# Q04a universal query and nested prefetch

Status: native query-tree slice implemented and verified; full Q04 remains open. Source: Qdrant 74f3e85b9473c62560006c043e13737ce6b48412.

Port planned_query.rs, local_shard/query.rs and collection_query.rs semantics:
ordered sources, parent filters into leaves, global local-ID exclusion,
candidate-ID union for vector rescoring, each prefetch's own limit/threshold,
root offset and source-specific MMR stages. Keep native captured roots and
resource limits. No performance work.

Deliver a working Mojo query tree and thin Python/Arrow API for existing
nearest/recommend/discovery/context, RRF/weighted RRF/DBSF, MMR and ID-ordered
no-vector queries. Reuse prepared scorers and sparse/HNSW execution; do not
route each branch through independently acquired snapshots. Parent filters
and all referenced IDs must be resolved before retrieval.

Native input follows the existing flat filter-arena pattern: ordered postorder
nodes, single parent per node, root last, bounded nodes and source depth 64.
The Python boundary only serializes the public tree and captures lookup owners.
Mojo validates and plans the tree, selects candidates, scores and applies limits.

Compile upstream planner functions as an independent oracle; exercise public
query pipelines, filters/exclusions, thresholds/offset, empty branches, malformed
trees, root/nested MMR, snapshot changes, cancellation and total work bounds.
Keep full protocol, order-by, formulas, sampling, feedback and batch/projection
operations in the master ledger until separately implemented and verified.


## Delivered evidence

- Native postorder planner and retained-root executor; native snapshot/collection,
  Python `QueryRequest`/`Collection.query`, and Arrow `query_record_batch`.
- Unedited upstream planner/validation/depth functions generate 103 cases
  (99 valid, 4 rejected). Native assertions compare source stage selection,
  retrieval limits, parent filter chains and depth errors.
- Four new native tests and 110 new Python cases cover source planning,
  execution, filters/ID exclusions, lookup/snapshot lifetime, MMR distinctions,
  dense HNSW/native datatypes, sparse/MaxSim, fusion and work/deadline limits.
- Full Python: 2115 passed, 1 optional Edge test skipped. Relevant native suite:
  14 passed (query 4, MMR 5, discovery 4, recommendation ANN 1).
- No persistence format or optimizer changes. Full product/platform gates remain
  open. See [validation](../research/2026-10-30-universal-query-validation.md).
