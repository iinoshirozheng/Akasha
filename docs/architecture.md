# AkashaDB Architecture

AkashaDB starts as an embedded, single-node document and vector database. The Mojo kernel owns data modeling, query planning, indexing, persistence, and compute. Python and HTTP support are adapters and must not become dependencies of the kernel.

## Dependency direction

```text
apps / Python SDK
        |
    bindings
        |
   public API
        |
query + indexes
        |
storage + compute + document + common
```

## Initial write path

```text
validate -> WAL -> mutable memtable -> immutable segment -> manifest publish
```

## Initial read path

```text
filter AST -> planner -> exact/ANN search -> exact rerank -> payload fetch
```

The first exact vector-search slice is implemented as a scalar correctness baseline. Metadata filters and crash-safe persistence are the next milestone. HNSW, hybrid search, Arrow interchange, GPU kernels, and distributed execution remain explicit future work.
