# Q02a: query by stored point ID and reference lookup

Full Q02 includes average-vector, best-score and sum-score recommendation, mixed
IDs/vectors and lookup/exclusion behavior. This prerequisite slice delivers the
stored-point query and reusable native lookup/exclusion path; the recommendation
strategies remain required work in the master plan.

## Source and design

Pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:

- `collection/common/fetch_vectors.rs`: `ReferencedVectors::get`,
  `resolve_reference` resolve an ID using the selected collection/vector field.
- `collection/operations/universal_query/collection_query.rs`:
  `ids_into_vectors`, `get_referenced_point_ids_on_collection`,
  `exclude_referenced_ids` resolve before scoring, reject absent vectors and
  exclude IDs only from the searched collection (also with another lookup field).
- `collection/recommendations.rs`: same lookup/exclusion semantics will be reused
  by all three subsequent recommendation strategies.

Expose `search_field_by_id(name, id, k, lookup_from=None, lookup_field=None, ...)`
through native collection/snapshot, Python and Arrow. Capture one search root;
default/self lookup must use that exact root. An explicit external snapshot pins
its own source root. Return a retained typed PointField descriptor from native
lookup, without Python materialization. Lookup follows existing native type
contracts (matching kind, scalar and dimension); cross-datatype query conversion
remains explicit Q02 follow-up alongside recommendation vector preprocessing.

Exclusion must happen before Top-K, HNSW admission and IVF selection. Add an
optional ID set to existing retrieval paths, preserving unchanged defaults and
resource/cancellation accounting. HNSW may traverse excluded vertices but must
not return/rerank them; exclusion must survive exact fallback and shadowed runs.
Detect collection identity through the shared pin registry, or canonical stored
directory paths for snapshots retained across reopen. No new durable schema.

## Work and acceptance

1. Native lookup helper and source-derived reference cases (present/missing point,
   missing field, same/other collection and alternate lookup field).
2. Pre-Top-K exclusions in dense/sparse, HNSW and IVF retrieval; reuse existing
   scoring kernels without a new ranking/search algorithm.
3. Capture and expose point query in native snapshot/collection, bindings,
   Python and Arrow. Preserve callback-close checks before native pointer borrows.
4. Test all native field kinds/scalars, payload filters, k without lost slots,
   repeated updates/overlays, HNSW/IVF, snapshot lifetimes, cross-collection ID
   collisions, reopen, invalid lookups, cancellation/budgets and Arrow ownership.
5. Build serially, run relevant regression tests, record provenance/evidence and
   commit. Keep full Q02 and all product tasks open; no optimization work.

Status: implemented and verified for the stated native typed lookup contract,
Python and Arrow. [Evidence](../research/2026-10-30-point-query-validation.md):
52 upstream reference cases, 18 native cases and 410 distinct Python cases passed.
Full Q02 (including recommendation strategies and query preprocessing) remains
open in [the next implementation plan](2026-10-30-recommendation-source-port.md).
