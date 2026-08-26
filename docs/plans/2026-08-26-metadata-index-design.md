# Phase 9: Metadata Index Design

## Goal

Replace per-document metadata scans with a derived in-memory index while
preserving every Phase 4.2/4.3 filter result and the existing durable formats.

## Selected architecture

Each live or deleted point owns one stable ordinal for the lifetime of an open
collection. A dense `Bitmap` addresses those ordinals in 64-bit words and
caches its cardinality. `MetadataIndex` owns the live-point universe, the
point-ID/ordinal mapping, the latest owned fields for each ordinal, keyword
postings, and sorted numeric entries.

String and Bool equality use sparse sorted keyword postings, avoiding one dense
bitmap per distinct high-cardinality value. Int64 and Float64 equality and
range operators use type-specific sorted blocks. A condition materializes one
candidate bitmap. Boolean All, Any, and Negate combine candidate bitmaps with
intersection, union, and live-universe difference. Empty All returns the live
universe and empty Any returns an empty bitmap.

Strict typing is unchanged. Missing fields and fields of another type never
match, including `not_equal`. Therefore `not_equal` is the same-typed field
presence bitmap minus the equality bitmap, not the complement of equality over
all live documents.

## Mutation and recovery

The index is derived state and is never written to WAL, Segment, Manifest, or
the sparse sidecar. Collection open recovers the authoritative MemTable first,
then bulk-loads every current MemTable slot and heap-sorts typed entries in
`O(N log N)`. A document upsert
removes the ordinal's old postings and inserts its new fields only after the WAL
and MemTable mutation succeed. A vector-only upsert clears old metadata.
Delete removes postings and clears the ordinal from the live universe.

Stable MemTable slots and metadata ordinals have the same order. Exact filtered
execution scans bitmap words, materializes only set candidate ordinals, fetches
the corresponding MemTable slot in O(1), and scores its vector. HNSW planning
uses the bitmap's
cached cardinality rather than scanning documents. HNSW and sparse candidates
are accepted by point-ID membership in the same derived index.

## Query flow

```text
FilterExpression
      |
condition -> keyword postings / numeric sorted blocks
      |
Bitmap AND / OR / live-minus
      |
cached cardinality -> QueryPlanner
      |
candidate ordinals -> exact SIMD scoring
                  or HNSW over-fetch + bitmap membership + exact fallback
```

The existing linear evaluator remains the correctness oracle and is used by
equivalence tests, not by indexed production query paths.

## Error handling and compatibility

Expressions and conditions are validated before index evaluation. Unknown
types and malformed operators retain the current errors. Index mutation occurs
only after durable mutation validation and WAL append, so invalid input cannot
partially update derived state or consume a sequence. If index construction
fails during open, collection open fails without publishing partially recovered
state.

Python, HTTP, and Arrow APIs do not change: their existing filter dictionaries
continue to become Mojo `FilterExpression` values. GPU execution is outside
Phase 9; all bitmap and metadata operations are CPU Mojo code.

## Verification

- Unit tests cover bitmap growth, set algebra, cardinality, and bounds.
- Index tests compare every typed operator and nested Boolean expression with
  the Phase 4 linear evaluator, including missing/type-mismatch semantics.
- Mutation tests cover replace, vector-only replacement, delete, and ID reuse.
- Collection tests cover exact, approximate, sparse, and hybrid filtering after
  live writes, WAL recovery, and snapshot recovery.
- A benchmark harness exercises 10,000 and 100,000 indexed documents.
- Completion requires all Mojo/Python tests, crash tests, optimized builds,
  smoke examples, formatter, and `git diff --check`.
