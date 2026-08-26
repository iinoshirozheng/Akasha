# Query model

Status: exact, parallel, quantized, and HNSW dense retrieval; sparse/hybrid
retrieval; bounded Boolean metadata indexing; and point lookup implemented.

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
a list of `FilterCondition` values combined with AND. Conditions generate
candidate bitmaps before vector scoring. String and Bool use sparse sorted
equality postings; Int64 and finite Float64 use sorted equality/range blocks. A
missing field or different payload type never matches, including for `!=`. An
empty condition list is equivalent to unfiltered search.

`FilterExpression.condition`, `all`, `any`, and `negate` build owned Boolean
trees for `search_dot_where`, `search_l2_where`, and `search_cosine_where`.
Bitmap evaluation composes intersection, union, and live-universe difference.
Empty All is true, empty Any is false, and Negate contains exactly one child.
The flat arena representation is bounded to 16 levels and 256 nodes and is
validated again at the query boundary.

The metadata index is derived and never authoritative. It is maintained after
each successful collection mutation and either loaded from a validated derived
cache or bulk-rebuilt in `O(N log N)` from stable MemTable slots after
WAL/Segment recovery, so v1/v2 storage compatibility is unchanged. Cached
bitmap cardinality lets the planner choose filtered exact execution or HNSW
without first scanning all payloads. Exact execution iterates selected slots;
HNSW and sparse/hybrid paths use the same point-ID membership set.

`PersistentCollection.snapshot()` freezes dense vectors, payloads, sparse
vectors, and the metadata index at one sequence. Its exact, Boolean-filtered,
sparse, hybrid, batch, and `get` methods remain stable while the live collection
is replaced, deleted, flushed, or compacted. Closing the snapshot releases its
manifest-generation pin.

`search_*_batch` captures one snapshot for every input query and preserves
input ordinal order. `search_*_where_batch` additionally accepts exactly one
`FilterExpression` per query. Each worker owns a bounded Top-K heap; metric
ordering and ascending-ID tie rules are identical to the sequential methods.
Small batches retain a sequential path. Python exposes the same behavior as
`Collection.search_batch(..., filters=[...])`.

Snapshots expose `search_*_parallel` and `search_*_where_parallel` for exact
single-query CPU parallelism. Fixed ordinal ranges and range-ordered heap merge
produce the same IDs, raw scores, and ascending-ID ties as scalar execution.

`search_sq8_*` builds a per-dimension scalar codebook; `search_pq_*` accepts a
subquantizer and centroid count and trains deterministic bounded-iteration
centroids. With `rerank_k=0`, returned scores are reconstructed/centroid
approximations. With `rerank_k >= k`, the approximate index selects candidates
and original Float32 vectors produce final metric scores. A larger candidate
set improves recall at extra CPU cost.

`search_device_*_batch[use_accelerator=True]` returns a `DeviceBatchResult`
containing per-query results, `used_gpu`, a planner/fallback reason, and planned
device bytes. The device kernels preserve input order and ascending-ID ties;
Float32 GPU scores are differential-tested against SIMD with a `1e-4`
tolerance. `_where_batch` device variants evaluate each metadata expression
before scoring. `use_accelerator=False` compiles a portable CPU-only path for
hosts without an optional device compiler.

For one condition, lookup is proportional to keyword posting discovery or
`O(log N + M)` numeric range discovery plus bitmap materialization, where `M`
is the number of matches. Boolean set operations are linear in bitmap words.
Projection and distributed query execution remain future work.
