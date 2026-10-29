# Python API

Build the Mojo extension before importing the local package:

```bash
pixi run build-python
PYTHONPATH=python python -c 'import akashadb; print(akashadb.__version__)'
```

`akashadb.Collection(path, dimension)` owns an embedded Mojo
`PersistentCollection`. `upsert`, `apply_batch`, sparse updates, delete,
flush, lookup, and every query execute in the compiled kernel. `close()` drains
background maintenance before releasing the collection directory lock.

## Atomic mutations

```python
from akashadb import BatchMutation, Collection, PayloadField

collection = Collection("/tmp/python-batch", 3)
commit = collection.apply_batch(
    [
        BatchMutation.upsert(
            1,
            [1.0, 0.0, 0.0],
            [PayloadField("chunk", "string", "owned text")],
        ),
        BatchMutation.delete(9),
    ]
)
print(commit.first_sequence, commit.last_sequence)
```

The return value names the contiguous accepted sequence range. Validation failure
changes neither durable nor live state. An append/fsync error can leave a complete
durable envelope even when the call raises. After that error, or a failure while
publishing committed batch state, new operations fail with `requires reopen`.
Close and reopen the collection to recover the entire accepted batch or discard
its incomplete tail. Previously captured snapshots remain valid; do not infer
that an I/O exception means the batch is absent on disk.

## Dense batches and filters

```python
filters = [
    {
        "kind": "condition",
        "name": "language",
        "operator": "eq",
        "type": "string",
        "value": "zh-TW",
    },
    {
        "kind": "condition",
        "name": "page",
        "operator": "ge",
        "type": "int",
        "value": 10,
    },
]
results = collection.search_batch(
    "cosine",
    [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
    10,
    num_workers=4,
    filters=filters,
)
```

`filters` is optional. When present, its length must equal the vector count;
each dictionary uses the same bounded condition/all/any/negate shape as
`SearchRequest.filter`. Result lists remain aligned to input vectors.

A condition's `type` describes its query literal. Integer and string `eq` match
only that stored type; `ne` also includes other present scalar types, following
Qdrant MatchExcept. Numeric ranges and floating-literal comparisons include both
integer and float values after Float64 conversion, so integers above 2^53 may
round in range comparisons. Boolean conditions match only booleans. Missing
fields fail field conditions; an outer `negate` includes those missing fields.

`upsert_columns` validates column-shaped Python data and copies it through
Python values. It is not a zero-copy Arrow C Data interface.

`upsert_record_batch` imports a producer's Arrow C Data schema/array capsules
into a one-shot `ArrowBatchLease`, validates the complete schema and offsets,
and keeps the imported owner alive through the synchronous Mojo call. Primitive
buffers reach the compiled binding without an intermediate Python list.
Persistence still copies accepted values once into WAL/MemTable-owned memory.

`search_record_batch(collection, request)` runs any `SearchRequest` directly into
owned `int64` ID and `float32` score columns. It uses the same limits, filters,
errors and ordering as `Collection.search`, without staging Python result rows.
The native result list is copied once into NumPy columns (12 bytes per result),
which PyArrow retains without another data copy. Batches and slices remain valid
after collection close; the last Arrow owner releases the output buffers.

```python
from akashadb import SearchRequest, search_record_batch

batch = search_record_batch(
    collection, SearchRequest("cosine", 10, vector=query_vector)
)
selected = batch.slice(0, 5)
collection.close()
print(selected.column("id"))
```

`results_to_record_batch` remains available to convert existing Python
`SearchResult` sequences into an independently owned batch with the same schema.

Projected reads use `Collection.get(id, projection=Projection(...))`.
`include_vector=False` omits the embedding, `fields=None` selects every payload
field, and a tuple selects only named fields.

## Snapshot batch scanning

`scan_record_batches` captures one immutable view immediately. It yields PyArrow
RecordBatches in run/slot order, with at most `batch_size` rows each; batches do
not cross run boundaries. Later updates, deletes, flushes and collection close
do not change that view. Use a context manager when stopping before exhaustion:

```python
from akashadb import scan_record_batches

with scan_record_batches(
    collection,
    batch_size=1024,
    columns=("id", "vector"),
    payload_schema={"chunk": "string", "page": "int"},
) as scanner:
    print(scanner.schema)
    for batch in scanner:
        process_batch(batch)
    print(scanner.stats)
```

Core columns are `id` (I64), `sequence` (U64), `vector` (fixed-size F32 list),
`sparse_term_ids` (I64 list) and `sparse_weights` (F32 list). The default includes
all except sequence. A missing sparse field is null; present fields preserve
their ragged lengths. The existing writer rejects empty sparse vectors.

Payload remains schemaless in storage, so the caller specifies projected field
types as `string`, `int`, `float` or `bool`. Output names use the `payload.` prefix.
Missing fields become null; a present value with a different type raises and
closes the scanner. No preliminary whole-collection schema discovery occurs.
An empty `columns` projection is supported, including zero-column batches with
their row counts preserved. `filter` accepts the same expression dictionaries
as `SearchRequest.filter` and runs against the captured point state.

One-row dense vectors borrow their immutable native buffer and retain its read
generation through a real Arrow C Data release callback. Multi-row vectors and
ID, sequence, sparse and payload columns are gathered directly into final native
buffers. Owned columns retain no generation pin. Arrow handles schema and capsule
exports; no raw addresses appear in this public API. Batches, child columns and
slices survive scanner and collection close. The last borrowed consumer releases
its generation and can reclaim retired files, including from another thread.

`cancellation=CancellationToken()` is checked between Python batch calls. Native
scan and export loops also check `deadline_ns` (absolute monotonic nanoseconds,
zero disables) cooperatively. `max_candidates` defaults to the collection's query
limit and bounds total visited physical slots, including filtered/tombstoned
slots. `max_batch_bytes` defaults to 64 MiB and caps aligned output buffer
allocations; exceeding it closes the scanner with an error. Reduce batch size
for large payloads. The byte limit excludes retained source generations,
selection descriptors and Arrow metadata. A cursor has one consumer; separate
cursors can retain independent snapshots.

`stats` counts returned rows/batches, visited slots, logical materialized buffer
bytes (including offsets and validity, excluding allocation padding) and borrowed
bytes. These are not process RSS or a claim of zero-copy multi-row storage. The
[scanner measurements](benchmarks/2026-09-30-arrow-scanner.md) include RSS and
explicitly account for the different ownership paths.
# Native named vectors and atomic point batches

`export_ndjson` / `import_ndjson` preserve complete typed point states with the
[versioned logical format](formats/logical-point-format.md), including points
without a default dense vector. Import into a collection created with the same
`config` and `vectors`; all imported fields commit as one point batch. Missing
fields clear the corresponding values on overwritten IDs. Legacy unversioned
document imports remain supported. Physical backups also preserve the catalog.

Pass `vectors={name: VectorField(...)}` when creating or migrating a collection.
Every new collection uses the point format; omitting `vectors` creates only the
reserved default dense and sparse fields, just like `vectors={}`. Existing legacy
collections migrate on their first open. Reopening without `vectors` loads its
persisted catalog; an
explicit different catalog is rejected. The catalog is immutable after cutover.

```python
from akashadb import Collection, PointMutation, VectorField

db = Collection("example", 2, vectors={
    "image": VectorField(3, dtype="f16", metric="cosine"),
    "tokens": VectorField(2, dtype="bf16", kind="multivector", metric="dot"),
    "bits": VectorField(9, dtype="binary", kind="binary", metric="hamming"),
})
db.apply_point_batch([PointMutation.upsert(
    1, vector=[1, 2], vectors={"image": [1, 2, 3], "tokens": [[1, 0], [0, 1]]},
)])
hits = db.search_field("image", [1, 2, 3], 10)
point = db.get_point(1)
db.close()
```

`upsert` replaces or creates the entire point: omitted vectors are removed and
`fields=None` becomes an empty payload. `update` requires an existing live point
and preserves omitted vectors and payload. `delete` removes the whole point. A
vector value of `None` removes that field, and `fields=[]` clears the payload. Empty sparse vectors and zero-row multivectors remain present. Cosine accepts zero vectors and queries; either zero operand produces similarity 0. A batch
validates every mutation before writing one WAL envelope; no accepted prefix is
visible on a validation error. NumPy inputs are copied into independently owned
native buffers. Integer inputs must be integral and in range; numeric authority
must be finite after conversion. Reads return owned lists/bytes.

`Point.sequence` covers every point mutation. `Point.document_sequence` tracks
the default dense/payload projection and is zero if the default vector is absent.
Named-only points participate in named search and point scans, but not default
dense queries. Named search defaults to native exact kernels with Float64 results.
Dense and multivector accumulation uses Float64, except F16 cosine. F16 cosine
normalizes native half inputs in Float32, rounds normalized components to half,
then accumulates their dot product in Float32, following Qdrant's half metric.
Zero and near-unit squared lengths use Qdrant's preprocessing thresholds.
Raw stored vectors are retained; the comparison to Qdrant uses these canonical
half inputs, since Qdrant otherwise normalizes the original Float32 ingestion
values before storing half values. MaxSim sums the row scores in Float64.
Sparse accumulation uses Float32. Dense fields configured with `VectorField(hnsw=...)` also
accept `mode="approx"`, `ef_search`, and `rerank_k`. Each field uses its own
dimension, metric and graph encoding; candidates are reranked from native
authoritative values into Float64 scores. `rerank_k=0` uses `max(k, ef_search)`;
an explicit value must be at least k and bounds the number reranked. Both ef and
the candidate budget must fit that field's configured `max_ef_search`. Exact mode
rejects ANN-only options. Binary and multivector fields use their exact kernels.

Graphs are built lazily outside the writer lock and shared by queries/snapshots
of the same immutable root. Updates and reopen acquire a new root and build new
named-field graphs on first use; named graphs currently have no durable sidecar.
The persisted default HNSW graph has its separate retained-base recovery path.

Approximate dense dispatch uses the available vector population and filtered
cardinality, rather than `k`, `ef_search`, or an empirical scan-cost estimate.
Collections with fewer than 64 available vectors use exact search; a filter
matching fewer than `max(1, available_vectors // 8)` vectors also uses exact
search. The same threshold controls supplementary payload graph construction.
These are Akasha tuning values, not Qdrant's default byte-budget setting. An
exact cardinality at the threshold takes the graph path deterministically.

`last_search_stats()` reports the field path, graph encoding, traversal and native
rerank counts, including any exact fallback after exhausted filtered search.
For default segmented ANN, `distance_evaluations` counts preliminary graph/delta
scoring, while `reranked_candidates` counts authoritative scoring afterward.
A delta scan whose admitted IDs all fit its candidate breadth skips preliminary
scoring, so zero preliminary distances can accompany a nonzero rerank count.
Planned exact scans count their scoring in `distance_evaluations`; in that path,
`reranked_candidates` reports retained hits and must not be added as extra
scoring work.
Named search accepts `timeout_ns` and `cancellation`, and enforces
`limits.max_candidates` against the captured visible point count. Native builds
check cancellation/deadlines between rows and before publication; graph search
checks before/after its bounded traversal. Python cancellation is sampled at entry
to the synchronous call, as in `search_controlled`.

Named sparse fields use independent root-owned inverted postings. Dot products
multiply and accumulate in Float32 in ascending query-term order, matching
Qdrant. Only nonzero scores participate: empty vectors, no shared terms and
exactly cancelling contributions produce no hit. Negative scores remain valid.
An empty named sparse query returns no results.

Dense fields also support `mode="ivf", ivf=IvfOptions(nlist=32, nprobe=4,
iterations=8)`. Import `IvfOptions` from `akashadb`; these are the defaults when
IVF mode omits options. IVF uses deterministic L2 coarse partitions, then scores
selected rows with the field's native score contract above, returning Float64.
`nlist` is 1–256, `nprobe` is 1–`nlist`, and training iterations must be positive;
all three require integers. Effective lists are limited to present field rows,
and probes are clamped to that count. Probing every list equals exact search.
With fewer probes, filters may leave fewer than k results: IVF does not expand
the probe budget automatically. HNSW ef/rerank controls cannot be combined with IVF.

IVF builds on first use per immutable root and `(field, nlist, iterations)`;
changing probes, k or filters reuses the index. It retains centroids and membership,
not a second vector corpus. Writes/reopen cause a new build on first use, and no
IVF sidecar is persisted. Training uses a temporary Float32 projection for all
five dense dtypes; original native values remain authoritative for scoring.
Cancellation, deadlines and candidate limits apply as for named search.
`last_search_stats()` exposes `ivf_partitions`, `ivf_probed_partitions`, visited
rows and native rerank counts. Arrow search and `FieldQuery(..., mode="ivf",
ivf=...)` accept the same options.

`search_field_by_id(name, id, k, ...)` queries a named field using a vector
already stored in a point. Lookup and search use one captured read root, and the
source point ID is excluded **before** Top-K / HNSW admission / IVF scoring.
Excluding the source does not consume a result slot. HNSW can still traverse an
excluded vertex. Payload filters constrain results, not source-vector lookup.
The method accepts the same exact/approx/IVF controls, filters, deadlines and
candidate limits as `search_field`.

```python
hits = collection.search_field_by_id("text", 42, 10)
hits = collection.search_field_by_id(
    "text", 42, 10, lookup_from=examples, lookup_field="reference",
)
```

`lookup_from` is another open `Collection`; omission or explicit self lookup
uses the searched collection's single root. `lookup_field` defaults to the
searched field's name. With a different collection, coincident IDs remain
eligible in the searched collection. Its source view is captured independently;
this does not create a cross-collection transaction. Native `ReadSnapshot` and
`PersistentCollection` expose `search_field_by_id(..., lookup=source_snapshot)`.
Explicit native snapshots can retain older source values across mutation/close.
Same-collection identity across reopen is checked using canonical directory paths.

Lookup supports all existing native vector kinds and scalar types under the
current typed-query contract: source kind, dimension and scalar must match the
target field. Missing/deleted points, missing vector fields and incompatible
types are errors. Empty sparse source vectors return no hits; empty multivector
queries are rejected. Query values remain native owners and are never passed
through Python lists. Stored values retain Akasha's existing raw-vector semantics;
Qdrant storage preprocessing and cross-datatype conversion require their separate
compatibility work. Reference selection/exclusion is source-ported; this API
does not claim complete Qdrant Query API compatibility.

`akashadb.arrow.search_field_by_id_record_batch` accepts the same options and
returns owned Int64 ID / Float64 score columns that survive collection close.
See [source reference cases](../tests/fixtures/qdrant-point-lookup/README.md).

`search_fields([FieldQuery(name, vector, mode="exact", ...), ...], k,
fetch_k=100, rank_constant=2, filter=...)` fuses rankings from one captured read
root. Each branch retrieves at most `fetch_k` results using that field's metric
and selected exact/approximate/IVF mode. RRF adds `1 / (rank_constant + rank)` for each
branch, with ranks starting at zero and contributions/sums in Float32, and breaks ties by
ascending point ID. Duplicate field names are allowed for different queries.
Filters apply to every branch before its Top-K. The aggregate candidate limit
counts the captured visible point count once per branch. `search_fields_record_batch`
offers the same options and directly exports owned Int64/Float64 columns.

Pass `weights=[3.0, 1.0, ...]` to set an RRF weight for each branch in query
order. The list must match the branch count; `None` means all weights are 1.
Qdrant's F32 contribution is `1 / ((rank + 1) / weight + rank_constant - 1)`
for positive weights. This adjusts the rank before taking its reciprocal;
it is not multiplication of the unweighted score. Zero and negative weights
contribute zero but retain their returned IDs, including in final rerank
candidate selection. All branches still run and count against resource limits.
Weights must be finite after F32 conversion. Nonfinite fused results are rejected,
including overflow caused by very large positive weights at `rank_constant=1`.
`weights` is supported only with `fusion="rrf"`; DBSF rejects an explicit list.
Arrow accepts the same `weights` keyword. The unchanged legacy hybrid search
entry points use equal weights; use named `FieldQuery` branches for weighted fusion.

```python
hits = collection.search_fields(
    [FieldQuery("text", text_vector), FieldQuery("image", image_vector)],
    10,
    fetch_k=100,
    weights=[3.0, 1.0],
)
```

Source and bit-exact fixtures: [weighted RRF port](../tests/fixtures/qdrant-rrf/README.md).

Pass `fusion="dbsf"` to use Qdrant distribution-based score fusion instead of
the default `fusion="rrf"`. DBSF converts each branch's returned scores to F32,
normalizes them with sample variance and `mean +/- 3 * standard_deviation`, then
sums contributions for matching IDs in branch order. Empty branches contribute
nothing; singleton and constant branches contribute 0.5 per result. Scores are
not clamped to [0, 1]. Nonfinite inputs or normalization/aggregation overflow
raise a validation error. This is a finite-range adaptation of the upstream port.

DBSF uses the branch's returned score units directly, as Qdrant's score-fusion
function does. It does not invert L2/Hamming/Jaccard distances; callers should
choose similarity-scored branches when larger values should contribute more.
Fused scores sort descending with ascending point-ID ties. `rank_constant` is
still validated as a positive integer but only affects RRF. `fetch_k`, filters,
candidate budgets, cancellation and optional final-field reranking apply to both
modes. `search_fields_record_batch(..., fusion="dbsf")` exposes the same native
path; HTTP's existing default-vector search route does not yet expose this API.

```python
hits = collection.search_fields(
    [FieldQuery("text", text_vector), FieldQuery("image", image_vector)],
    10,
    fetch_k=100,
    fusion="dbsf",
)
```

Source and native fixtures: [DBSF port](../tests/fixtures/qdrant-dbsf/README.md).

Pass `rerank=FieldQuery("tokens", query_matrix)` to score a bounded candidate set
with another field. Each first-stage branch retrieves `fetch_k` hits, RRF selects
at most `fetch_k` unique IDs, and the final exact field query returns the best k
of those candidates. Both stages use the same captured read root. This supports
dense/sparse retrieval followed by native MaxSim or packed Hamming/Jaccard scoring,
and works with all existing native final-field kinds and metrics. Rerank queries
must use exact mode; candidate branches may use exact, HNSW or IVF.

Results contain the final field's Float64 scores in its metric direction, with
ascending IDs for ties. Missing final fields and empty document multivectors are
excluded. Filters apply before candidate selection. A limited candidate set can
return fewer than k; no full-corpus expansion occurs. Increasing `fetch_k` changes
candidate recall and work, not the final scoring formula. The aggregate candidate
limit includes another `min(fetch_k, visible_points)` for reranking. Cancellation
and deadlines are checked during both stages. Final stats use `field-rerank`,
`base_candidates` counts the selected input IDs, `reranked_candidates` counts
final scores, and `retained_candidates` counts returned hits. Distance evaluations
remain aggregate across stages. `search_fields_record_batch` accepts the same
`rerank` argument and exports final scores directly.

`akashadb.arrow.upsert_point_record_batch` accepts `id`, optional `vector` and
`sparse`, `vectors.<name>`, and `payload.<name>` columns, returning a
`BatchWriteResult`. Each row replaces the whole point: omitted columns and null
vector values remove fields. Payload columns replace the payload; omitting all
payload columns clears it. The complete Arrow batch commits atomically. Producer buffers must remain
unchanged during the synchronous call and may be released after it returns.

`scan_record_batches(..., vectors=("image", "tokens"))` projects named fields as
nullable Arrow columns. Numeric dense fields use fixed-size lists, multivectors
use lists of fixed-size lists, binary fields use fixed-size bytes, and sparse
fields use `list<struct<term_id: int64, weight: float32>>`. F16/F32/I8/U8 retain
their Arrow primitive types. BF16 uses UInt16 **bit patterns** with field metadata
`akashadb.dtype=bf16`; importing BF16 without that metadata is rejected. Scans
support `document_sequence` alongside the point `sequence`. Single-row numeric
and binary buffers retain the captured generation through Arrow C Data ownership;
gathered buffers have independent ownership, and slices survive scanner/collection
close. `search_field_record_batch` accepts the same search options and emits owned
Int64 IDs and Float64 scores.

### Qdrant behavior migration

All upserts replace whole points (including omitted fields and payload),
sparse searches exclude zero scores, and RRF defaults to constant 2 with
zero-based ranks and Float32 accumulation. Use `PointMutation.update` for partial
changes. Older WAL v4 is replayed with its historical merge semantics; new writes
use WAL v5. Complete point checkpoints use Segment v5, which permits zero sparse
weights; existing Segment v4 remains readable with its original validation.
`upsert_sparse` accepts empty vectors and zero weights and updates only that field.
Default collection opens also perform the catalog migration, so supply any named
fields on that first open. See the
[field envelope contract](formats/field-envelopes-format.md) for upgrade behavior.


## Recommendation queries

`Collection.recommend_field(name, positive, negative=None, k=10, *,
strategy="average_vector", mode="exact", ef_search=None, lookup_from=None, lookup_field=None,
filter=None, cancellation=None, timeout_ns=None)` executes all three Qdrant
recommendation strategies in Mojo. Each example is an integer point ID or a raw
vector matching the target field's kind/dimension; IDs resolve from the selected
lookup collection and field. Raw numeric inputs become F32 query values before
preprocessing and conversion to the target datatype. Source IDs are excluded
before Top-K only when lookup identifies the target collection. Both positive
and negative IDs are excluded; repeated examples still contribute repeatedly.

```python
hits = db.recommend_field(
    "image", positive=[42, [0.2, 0.8, 0.1]], negative=[19],
    k=10, strategy="best_score",
)
```

- `average_vector` requires a positive example. Dense/sparse values are averaged
  in F32, then combined as `positive + positive - negative` when negatives exist.
  Sparse terms use a sorted union with zero for missing values. Multivector
  inputs concatenate positive rows and append negated negative rows.
- `best_score` chooses the largest similarity in each set; a tie chooses the
  negative set. The selected score passes through Qdrant's signed scaled fast
  sigmoid. Positive-only and negative-only requests are valid.
- `sum_scores` separately accumulates all positive and all negative similarities
  in F32 and subtracts the totals. Positive-only and negative-only are valid.

Dot/cosine use higher-is-better internal similarity. Custom L2 scores use
**negative squared distance** before the best/sum reduction. Only average-vector
results apply Qdrant's final Euclidean square root, so their public L2 units
are distance, unlike Akasha's existing `search_field` squared-L2 contract.
Scores are F32 values exported through the native Float64 result columns.
Ties keep Akasha's ascending ID ordering. Sparse average queries omit zero
results; sparse custom queries include zero/nonoverlap results. Missing fields,
empty stored multivectors and excluded IDs never occupy a result slot.

`recommend_field_record_batch` in `akashadb.arrow` exposes the same options and
returns owned `id: int64` and `score: float64` columns. Native `ReadSnapshot` and
`PersistentCollection` expose `recommend_field` using `RecommendationExample.point`
and `.raw`; a native lookup snapshot can outlive its source writer. Recommendations count as
queries in collection telemetry. `max_query_batch` bounds the total examples;
`max_k`, `max_candidates`, cancellation and deadlines apply. Nonfinite results
are rejected. Binary recommendation is unsupported by the upstream strategies.

`mode="approx"` requires a dense field configured with HNSW. All three strategies
score each visited candidate with the same prepared query used by exact search;
best/sum do not substitute a single averaged query. `ef_search` defaults to the
field's configured search breadth and must be positive and within its maximum.
It is invalid in exact mode. Native APIs use `approximate=True, ef_search=...`.
Filtering, same-collection source exclusion and shadowed-row visibility apply
before candidates enter graph traversal. Candidates use the native stored field
values even when the graph uses another scalar representation.

Stats identify `recommendation_hnsw`, `recommendation_exact`, or a documented
planner fallback (`recommendation_small_collection`, `recommendation_selectivity`,
`recommendation_ann_exhausted`). An empty eligible set reports
`recommendation_empty`; the backend is `qdrant-recommendation-f32`. Custom-score
distance counts include each positive/negative example similarity. A small or
selective dataset uses exact search; insufficient graph results also trigger an
explicit exact fallback. A full result count does not guarantee exact recall.
The repeated-vector quality diagnostic remains open even at high ef; see the
[ANN validation and limitation](research/2026-10-30-recommendation-ann-validation.md).

Sparse/multivector indexed recommendation and universal REST/gRPC/C exposure
remain required work. F32 scalar
pipelines have independent upstream fixtures. Native F16/U8 conversion and
Akasha BF16/I8 extensions have regression coverage but not a full upstream
cross-datatype oracle yet. Integer metric accumulation is widened to Int64.
Akasha retains raw typed authority: recommendation reconstructs cosine's stored
representation from those native values. For low-precision fields, this cannot
recover the original pre-ingestion F32 input; full canonical storage alignment
requires the separate Q02/Q06 audit/migration. No existing stored values change.

Source and verification: [recommendation port](plans/2026-10-30-recommendation-source-port.md)
and [exact validation](research/2026-10-30-recommendation-validation.md).
