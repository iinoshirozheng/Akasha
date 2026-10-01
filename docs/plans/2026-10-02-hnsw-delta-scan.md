# Bounded exact scoring of a small HNSW delta

Keep the existing immutable base and mutable delta graphs, mutation paths and
durable formats. Select exact scoring for the delta of a segmented query only
when all of these conditions hold: a current base exists, physical delta slots
are at most 1,024, slots times dimension is at most 1,572,864 components, and
slots are at most normalized initial ef times M0. Use division to check the
products without overflow. Count inactive slots against both bounds. A delta-only
collection continues to use HNSW.

This follows the existing source admission, prepared query, native distance
backend and bounded heap. Reject inactive and ineligible IDs before computing
distances. Retain the same initial candidate breadth and stable distance/ID
ordering; final public scores still use the authoritative F32 reranker. Preserve
identity, invalid-index, query and demand validation. Record actual distances,
rejections and zero delta descents, with `segmented-delta-scan-*` storage labels.
The base remains HNSW and the merged result remains approximate.

Local Qdrant `plain_vector_index/read_view/search.rs` bounds unindexed scans by
vector bytes/cardinality; its HNSW read view also has cardinality-based plain
search paths. The isolated Akasha sweep has 108 cells across three corpora,
four sizes, three ef values and three processes. Every scan matches the independent
Float64 oracle. It explicitly shows regressions at real 1536D, 1,024 slots/ef10
and 4,096 slots/ef32. The proposed bounds exclude both. They are conservative
work limits derived from this diagnostic, not a universal hardware cost model.

Acceptance: policy boundary/overflow tests; owned and mapped base with every
supported graph scalar/metric; replaced/deleted/reinserted delta IDs, filters,
empty admission, score ties and source counters; invalid identity/query/demand;
existing recovery/overlay cache, public Python and C tests. Measure public mixed
workloads in three alternating pairs, then compare Qdrant. Preserve low-recall
cells, slow trials and prototypes. Benchmarks run serially without other builds,
tests or archive compression. Resident measurements cannot close the nonresident
or controlled-cold gates.
