# Query model

Status: exact vector retrieval, bounded Boolean metadata filtering, and point
document lookup implemented; hybrid retrieval planned.

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

`search_dot_filtered`, `search_l2_filtered`, and `search_cosine_filtered` accept
a list of `FilterCondition` values combined with AND. Conditions run before
vector scoring. String and Bool support equality and inequality; Int64 and
finite Float64 also support range comparisons. A missing field or different
payload type never matches, including for `!=`. An empty condition list is
equivalent to unfiltered search.

`FilterExpression.condition`, `all`, `any`, and `negate` build owned Boolean
trees for `search_dot_where`, `search_l2_where`, and `search_cosine_where`.
Evaluation short-circuits before scoring. Empty All is true, empty Any is false,
and Negate contains exactly one child. The flat arena representation is bounded
to 16 levels and 256 nodes and is validated again at the query boundary.

Phase 4.2 uses a linear payload scan and does not persist filter state or a
metadata index, so v1/v2 storage compatibility is unchanged. The future query
model will add OR/NOT expression trees, indexed candidate generation, result
fusion, exact reranking, projection, and limits. A planner can later choose
between filtered exact search and approximate search based on selectivity.
