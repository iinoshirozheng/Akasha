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

Minimal Mojo API:

```mojo
from akasha import PersistentCollection

var collection = PersistentCollection.open("/tmp/my-vectors", 3)
collection.upsert(42, [1.0, 0.0, 0.0])
collection.flush()

var reopened = PersistentCollection.open("/tmp/my-vectors", 3)
var query: List[Float32] = [1.0, 0.0, 0.0]
var results = reopened.search_cosine(query, 10)
```

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
- Versioned little-endian WAL, segment, and manifest formats with CRC32.
- WAL append fsync, immutable snapshot publication, and atomic manifest commit.
- WAL-only and snapshot-plus-WAL recovery, including torn-tail repair.

Text chunks and images can already be embedded externally and stored as vectors.
Persisting the original chunk text, image URI, and metadata payload is planned
for Phase 4. WAL rotation, compaction, metadata filters, HNSW, hybrid retrieval,
Arrow interchange, GPU kernels, and distributed execution remain deferred.
