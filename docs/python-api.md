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
`vectors={}` opts into the point format with only the reserved default dense and
sparse fields. Reopening without `vectors` loads its persisted catalog; an
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

`upsert` merges or creates; `update` requires an existing live point; `delete`
removes the whole point. Omitted vectors and `fields=None` preserve existing
values, a vector value of `None` removes that field, and `fields=[]` clears the
payload. Empty sparse vectors and zero-row multivectors remain present. A batch
validates every mutation before writing one WAL envelope; no accepted prefix is
visible on a validation error. NumPy inputs are copied into independently owned
native buffers. Integer inputs must be integral and in range; numeric authority
must be finite after conversion. Reads return owned lists/bytes.

`Point.sequence` covers every point mutation. `Point.document_sequence` tracks
the default dense/payload projection and is zero if the default vector is absent.
Named-only points participate in named search and point scans, but not default
dense queries. Named search defaults to native exact kernels with Float64
accumulation/results. Dense fields configured with `VectorField(hnsw=...)` also
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
`last_search_stats()` reports the field path, graph encoding, traversal and native
rerank counts, including any exact fallback after exhausted filtered search.
Named search accepts `timeout_ns` and `cancellation`, and enforces
`limits.max_candidates` against the captured visible point count. Native builds
check cancellation/deadlines between rows and before publication; graph search
checks before/after its bounded traversal. Python cancellation is sampled at entry
to the synchronous call, as in `search_controlled`.

Named sparse fields use independent root-owned inverted postings. Dot products
multiply and accumulate in Float64 in ascending query-term order. Present empty
vectors and rows with no shared term score zero and can outrank negative matches;
missing fields do not participate. This preserves named exact-search semantics;
the older default sparse API retains its documented nonempty/matching-term rules.

Dense fields also support `mode="ivf", ivf=IvfOptions(nlist=32, nprobe=4,
iterations=8)`. Import `IvfOptions` from `akashadb`; these are the defaults when
IVF mode omits options. IVF uses deterministic L2 coarse partitions, then scores
selected rows with the field's native dtype and dot/L2/cosine metric in Float64.
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

`search_fields([FieldQuery(name, vector, mode="exact", ...), ...], k,
fetch_k=100, rank_constant=60, filter=...)` fuses rankings from one captured read
root. Each branch retrieves at most `fetch_k` results using that field's metric
and selected exact/approximate/IVF mode. RRF adds `1 / (rank_constant + rank)` for each
branch, with ranks starting at one, accumulates in Float64, and breaks ties by
ascending point ID. Duplicate field names are allowed for different queries.
Filters apply to every branch before its Top-K. The aggregate candidate limit
counts the captured visible point count once per branch. `search_fields_record_batch`
offers the same options and directly exports owned Int64/Float64 columns.

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
`BatchWriteResult`. Omitted columns preserve fields and null vector values remove
them. Payload columns replace the payload; omitting all payload columns preserves
it. The complete Arrow batch commits atomically. Producer buffers must remain
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
