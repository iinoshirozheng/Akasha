# AkashaDB

AkashaDB is an experimental embedded document and vector database kernel written in Mojo. It currently provides validated `Float32` distance primitives and a deterministic in-memory exact Top-K index, alongside the architectural boundaries for persistence and document filtering.

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

Run the development-only HTTP adapter:

```bash
pixi run serve
```

## Architecture

The Mojo kernel under `src/akasha` never depends on Python or FastAPI. Language bindings live under `src/bindings`, and runnable adapters live under `apps`. See [`docs/architecture.md`](docs/architecture.md) for the dependency direction and initial data paths.

## Current milestone

Implemented:

- Dot product, squared L2 distance, and cosine similarity.
- Input validation for empty, mismatched, and zero-norm vectors.
- An owning in-memory `FlatIndex` with deterministic Top-K ordering.
- Stable ascending point-ID tie-breaking for equal scores.

Next milestones are metadata filters and crash-safe local persistence. HNSW, hybrid retrieval, Arrow interchange, GPU kernels, and distributed execution remain deferred.
