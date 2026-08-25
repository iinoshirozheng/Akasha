# Exact Vector Search Design

## Scope

The first search milestone implements owned `Float32` vectors, exact distance functions, and an in-memory flat Top-K index. It does not implement persistence, upsert semantics, metadata filters, SIMD specialization, HNSW, Python bindings, or GPU execution.

## Public behavior

- `dot_product(lhs, rhs)` returns a raw dot-product score; larger is better.
- `l2_squared_distance(lhs, rhs)` returns squared Euclidean distance; smaller is better.
- `cosine_similarity(lhs, rhs)` returns cosine similarity; larger is better.
- All distance functions reject empty vectors and mismatched dimensions.
- Cosine similarity rejects either zero-norm vector.
- `FlatIndex(dimension)` owns records added through `add(id, values)`.
- Search rejects non-positive `k` and query dimension mismatches.
- Search returns at most `min(k, index size)` raw scores, ordered best-first.
- Equal scores are ordered by ascending point ID for deterministic results.

## Architecture

Distance primitives live in `akasha.compute.distance`. `FlatIndex` and `SearchResult` live in `akasha.index.flat` and depend only on compute primitives and prelude collections. Public package exports expose the API without introducing Python or server dependencies.

The first implementation is intentionally scalar and serves as the correctness oracle for later SIMD, approximate, and GPU implementations.
