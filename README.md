# AkashaDB

AkashaDB is an experimental embedded document and vector database kernel written in Mojo. It currently provides validated scalar and CPU-SIMD `Float32` distance primitives plus a deterministic in-memory exact Top-K index, alongside the architectural boundaries for persistence and document filtering.

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

Next milestones are crash-safe local persistence and metadata filters. HNSW, hybrid retrieval, Arrow interchange, GPU kernels, and distributed execution remain deferred.
