# Qdrant query-plan oracle

Pinned Qdrant: `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Regenerate with `rtk proxy python scripts/qdrant_query_plan_reference.py`.

The generator compiles the unchanged body of `planned_query.rs` (starting at
`MAX_PREFETCH_DEPTH`), the complete `validation.rs` implementations and the
original `ShardQueryRequest.prefetches_depth` / `ShardPrefetch.depth` methods.
Source hashes, extracted-unit hashes and complete Rust scaffold hash are stored
in `plans.json`. The native test consumes all 103 cases: 99 successful plans and
4 validation failures. Inputs include root/leaf/nested MMR, fusion/vector
rescoring, root offsets, empty candidates, inherited filters and depths 64/65.

Adapters replace external dependencies and transport types. Vectors and filters
are labels; `Filter.merge_opts` concatenates conjunction labels. Driver code
constructs postorder input and reports the actual plan's leaf retrieval limits,
filter ancestry and rescore stages. It does not reproduce planning in Python.
This is not a server, protocol, distributed merge, scoring, storage or HNSW
oracle. Existing recommendation/discovery/MMR/fusion fixtures cover reused
scorers separately. See `docs/research/2026-10-30-universal-query-validation.md`.
