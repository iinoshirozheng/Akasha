# Single-Node Production MVP Roadmap

## Goal

Complete Akasha's remaining single-node Production MVP without adding GPU or
distributed execution. The Mojo kernel remains authoritative for document
semantics, persistence, indexing, and query execution. Python, HTTP, and Arrow
remain adapters.

## Delivery sequence

The remaining work is split into five independently testable phases:

1. Phase 4.3: Boolean metadata filter expressions.
2. Phase 5: storage lifecycle and single-process ownership.
3. Phase 6: HNSW approximate search and filter-aware planning.
4. Phase 7: sparse retrieval and hybrid rank fusion.
5. Phase 8: Python, HTTP, and Arrow-facing adapters.

Every phase keeps the previous public APIs working, runs the complete regression
suite, commits to a dedicated branch, merges to `main`, and pushes before the
next phase starts.

## Phase 4.3: Boolean filters

Replace the AND-only list boundary with an owned expression tree containing
Condition, And, Or, and Not nodes. Existing `search_*_filtered` methods continue
to accept `List[FilterCondition]` as an implicit AND for compatibility. New
`search_*_where` methods accept one `FilterExpression`.

Expressions have configured depth and node limits, own cloned condition values,
short-circuit deterministically, and preserve Phase 4.2 strict missing/type
semantics. Empty And matches, empty Or does not match, and Not has exactly one
child. Expressions remain query-only and do not change storage formats.

## Phase 5: Storage lifecycle

Add an exclusive collection lock acquired by `PersistentCollection.open` and
released when the collection value is destroyed. A second process or live
collection in the same process cannot open the same path for writing.

Flush becomes a checkpoint:

```text
write + fsync new full snapshot
  -> publish + fsync manifest
  -> atomically replace WAL with an empty file + directory fsync
  -> remove obsolete unreferenced snapshots
```

The ordering guarantees that a crash either replays the old WAL or opens the
new manifest snapshot. WAL rotation never occurs before manifest publication.
Cleanup only targets filenames parsed and validated as Akasha snapshots inside
the exact collection directory. No background thread or incremental segment
format is introduced.

## Phase 6: HNSW and planning

Implement an in-memory HNSW index over the latest live vectors with deterministic
level generation from point IDs, bounded neighbor lists, greedy descent, and
best-first layer search. Durable WAL/Segment state remains authoritative; the
graph is rebuilt on open and updated on upsert/delete.

Public approximate methods expose `ef_search` and return the existing
`SearchResult`. A small planner selects exact scan for small collections or
selective metadata expressions and HNSW for sufficiently large unfiltered
queries. Filtered approximate search over-fetches graph candidates, applies the
expression, and exact-reranks accepted candidates. If it cannot produce `k`
matches, it falls back to exact filtered search, preserving correctness.

## Phase 7: Sparse and hybrid retrieval

Add caller-provided sparse vectors as sorted `(term_id, weight)` pairs. Phase 7
does not embed or tokenize text inside the database. Sparse vectors are validated
for unique ascending non-negative term IDs and finite non-zero weights.

An in-memory inverted index supports sparse dot-product Top-K. Sparse state is
stored as a typed document field encoding only at the adapter boundary in this
MVP; the Mojo collection exposes a companion durable sparse sidecar committed by
the manifest checkpoint sequence. Recovery rejects a sidecar whose sequence
does not match the manifest and rebuilds it from newer WAL sparse mutations.

Hybrid search runs dense and sparse retrieval independently and fuses stable
ranked IDs with reciprocal-rank fusion. Ties use ascending point ID. Metadata
expressions are evaluated before candidates enter either ranking path.

## Phase 8: Adapters

Expose stable Python request/result models, typed exceptions, collection
lifecycle, document mutations, exact/approximate/hybrid queries, and payload
conversion. Python remains an adapter and never implements query or durability
semantics.

The FastAPI application adds health, collection open/close, upsert, delete,
flush, get, and search endpoints with validation and deterministic error
responses. A local adapter boundary serializes requests to the Mojo kernel; it
must be usable in tests without a network server.

Arrow support is batch-oriented. The adapter accepts and returns Arrow-compatible
column dictionaries with point IDs, fixed-size vectors, scores, and typed flat
payload columns. A trusted in-process Arrow C Data bridge remains optional until
Mojo exposes a stable ABI for the ownership contract; the MVP must not pretend
zero-copy when it is copying.

## Cross-phase guarantees

- Mojo stable and Pixi remain the only kernel build requirements.
- Existing v1/v2 WAL and Segment data continues to open.
- New formats are versioned, checksummed, bounded, and documented.
- Invalid input never consumes a sequence or partially mutates durable state.
- Search ties remain deterministic by ascending point ID.
- Every crash-sensitive ordering has a subprocess crash test.
- Every public feature has a runnable example and root-package import test.
- No phase claims completion without full tests, crash tests, build, smoke, and
  format verification.

## Explicit non-goals

GPU kernels, quantization, distributed shards, replication, consensus,
multi-writer transactions, background compaction, and remote object storage are
outside the selected single-node Production MVP.

