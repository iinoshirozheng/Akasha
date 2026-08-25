# Query model

Status: exact vector retrieval and point document lookup implemented; filtering
and hybrid retrieval planned.

The current Mojo API exposes exact dot-product, squared-L2, and cosine Top-K
searches through `FlatIndex` and `PersistentCollection`. Scores remain in their
native metric scale: larger is better for dot product and cosine, while smaller
is better for L2. Equal scores use ascending point IDs as a deterministic
tie-break.

Search results intentionally contain only a point ID and score. Use
`PersistentCollection.get(result.id)` to retrieve an owned `DocumentRecord`
with its latest vector, sequence, and flat typed fields. This keeps scoring
independent of payload size while supporting text chunks, image references, and
scalar metadata. Vector-only `upsert` replaces the record with empty fields;
`upsert_document` atomically replaces both vector and payload; delete makes
`get` return `None`.

Phase 4.2 will introduce field predicates and define whether filtering happens
before or after vector scoring. Until then, filtering is deliberately not part
of the storage API. The future query model will separate vector retrieval,
document filtering, result fusion, exact reranking, projection, and limits. The
planner will choose between filtered exact search and approximate search based
on candidate selectivity.
