# AkashaDB

AkashaDB is an experimental embedded vector database kernel written in Mojo. It
provides validated CPU-SIMD `Float32` exact search and a crash-recoverable,
single-writer storage engine built from a binary WAL, latest-state MemTable,
immutable snapshot segments, and an atomic manifest.

## Requirements

- macOS Apple Silicon or Linux x86-64
- Pixi
- A C linker (`xcode-select --install` on macOS or GCC on Linux)

## Get started

```bash
pixi install
pixi run test
pixi run build
pixi run smoke
pixi run test-crash
```

Run the persistent collection example:

```bash
pixi run example-persistent
```

Store a vector with a flat typed document payload, then retrieve the complete
document through a search result ID:

```mojo
from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)

var collection = PersistentCollection.open("/tmp/my-vectors", 3)
var fields = List[DocumentField]()
fields.append(
    DocumentField("chunk_text", PayloadValue.string("Vector database notes"))
)
fields.append(DocumentField("page", PayloadValue.integer(7)))
fields.append(DocumentField("verified", PayloadValue.boolean(True)))
collection.upsert_document(42, [1.0, 0.0, 0.0], fields^)
collection.flush()

var reopened = PersistentCollection.open("/tmp/my-vectors", 3)
var query: List[Float32] = [1.0, 0.0, 0.0]
var conditions = List[FilterCondition]()
conditions.append(
    FilterCondition.greater_or_equal("page", PayloadValue.integer(5))
)
var results = reopened.search_cosine_filtered(query, 10, conditions)
var document = reopened.get(results[0].id)
var chunk = document.value().get_field("chunk_text").value().as_string()
```

`upsert(id, vector)` remains available for vector-only records. The document
API accepts at most 1,024 unique, non-empty field names and a 16 MiB encoded
payload. Values are explicitly tagged as `String`, `Int64`, finite `Float64`,
or `Bool`. `get(id)` returns an owned record containing its vector, sequence,
and fields; deleted or unknown IDs return `None`.

Typed metadata filters are available for dot-product, squared-L2, and cosine
search through `search_*_filtered`. Conditions are combined with AND and run
before vector scoring. String and Bool support `==` and `!=`; Int64 and finite
Float64 additionally support `<`, `<=`, `>`, and `>=`. Missing fields and type
mismatches do not match, including inequality. Phase 4.2 performs a linear
payload scan without a metadata index.

For Boolean logic, build a bounded expression and use `search_*_where`:

```mojo
var alternatives = List[FilterExpression]()
alternatives.append(
    FilterExpression.condition(
        FilterCondition.equal("kind", PayloadValue.string("article"))
    )
)
alternatives.append(
    FilterExpression.negate(
        FilterExpression.condition(
            FilterCondition.equal("archived", PayloadValue.boolean(True))
        )
    )
)
var expression = FilterExpression.any(alternatives^)
var results = reopened.search_cosine_where(query, 10, expression)
```

`FilterExpression.all`, `any`, and `negate` form an owned flat-arena tree.
Empty All matches and empty Any does not. Expressions are limited to 16 levels
and 256 nodes. The Phase 4.2 `search_*_filtered` AND-list methods remain
supported.

Run the exact-search microbenchmarks:

```bash
pixi run bench-distance
pixi run bench-flat
```

Run the development-only HTTP adapter:

```bash
pixi run serve
```

## Architecture

The Mojo kernel under `src/akasha` never depends on Python or FastAPI. Language bindings live under `src/bindings`, and runnable adapters live under `apps`. See [`docs/architecture.md`](docs/architecture.md) for the dependency direction and initial data paths.

## Current milestone

Implemented:

- Dot product, squared L2 distance, and cosine similarity.
- Scalar correctness-oracle and hardware-width CPU SIMD kernels.
- Input validation for empty, mismatched, non-finite, and zero-norm vectors.
- An owning in-memory `FlatIndex` with one-pass bounded-heap Top-K selection.
- Stable ascending point-ID tie-breaking for equal scores.
- `PersistentCollection` upsert, delete, exact search, flush, and reopen.
- Atomic vector-plus-payload `upsert_document` and owned point lookup with
  `get`.
- Flat typed document fields for chunk text, image URIs, MIME types, and scalar
  metadata.
- Versioned little-endian WAL, segment, and manifest formats with CRC32.
- WAL append fsync, immutable snapshot publication, and atomic manifest commit.
- WAL-only and snapshot-plus-WAL recovery, including torn-tail repair.
- Backward-compatible WAL and segment readers for Phase 3 version 1 data;
  subsequent writes and snapshots use payload-aware version 2 formats.
- Strict typed AND metadata filters evaluated before exact SIMD scoring for all
  three vector metrics.
- Bounded Boolean All/Any/Negate filter expressions with pre-score evaluation.

Text and image bytes are not embedded by the database: callers generate vectors
externally and may persist the original text or an image URI as fields. Filtered
search returns candidate IDs and scores; callers resolve payloads with `get`.
Metadata indexes, WAL rotation, compaction, HNSW, hybrid retrieval, Arrow
interchange, GPU kernels, and distributed execution remain deferred.
