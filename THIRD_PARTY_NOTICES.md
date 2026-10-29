# Third-party source notices

Akasha contains adaptations of open-source database implementations. Port-specific
revisions, original source hashes, modified files and executable reference evidence
are recorded in [the source-port ledger](docs/upstream/ports.json).

## Qdrant

Project: <https://github.com/qdrant/qdrant>

The DBSF normalization in `src/akasha/query/score_fusion.mojo` and its integration
in `src/akasha/query/field_fusion.mojo` adapt Qdrant's
`lib/segment/src/common/score_fusion.rs` from commit
`74f3e85b9473c62560006c043e13737ce6b48412`. The code has been translated to Mojo,
uses typed score lists, and adds finite-range validation. Original behavior is
checked through an extracted Rust reference with representation-only shims.

Weighted RRF in `src/akasha/query/fusion.mojo` and its field-fusion integration
adapt `position_score` and `rrf_scoring` in
`lib/segment/src/common/reciprocal_rank_fusion.rs` at the same commit. Adaptations
include Mojo containers, finite-range validation and ascending point-ID ties.
The reference harness compiles both original functions without modifying them;
its container/type shims and output tie canonicalization are recorded with the
fixtures in `tests/fixtures/qdrant-rrf/`.

Stored-point queries in `src/akasha/query/field_lookup.mojo` adapt reference
resolution and same-collection exclusions from Qdrant's
`lib/collection/src/common/fetch_vectors.rs` and
`lib/collection/src/operations/universal_query/collection_query.rs` at that same
commit. The native dense/sparse/HNSW/IVF retrieval paths accept the resulting
exclusion set before selecting candidates. The reference harness also extracts
`VectorQuery::get_referenced_ids` from
`lib/collection/src/common/retrieve_request_trait.rs`. Akasha uses retained
native vector owners, collection directory identity and its existing typed
query/scoring contract; protocol/status and storage-preprocessing compatibility
remain separate work.

Recommendation transforms, metrics and execution in
`src/akasha/query/recommendation.mojo`, `recommendation_metrics.mojo` and
`field_recommendation.mojo` translate the same revision's
`lib/collection/src/recommendations.rs`,
`lib/segment/src/vector_storage/query/reco_query.rs`,
`lib/common/common/src/math.rs`, `lib/sparse/src/common/sparse_vector.rs`,
and the segment's `spaces`, `data_types/primitive.rs`, and `query_scorer`
implementations. The port uses owned Mojo vectors, retained read generations,
bounded Top-K and finite-result validation. F32 scalar reference functions,
sparse merges and MaxSim are compiled unedited for differential tests.
BF16/I8 are Akasha extensions, integer metric accumulators are widened, and
raw native cosine storage is preprocessed when preparing recommendation values.
This exact-query port does not claim full server, datatype, storage or ANN parity.

Dense recommendation ANN integration in `recommendation_scorer.mojo`,
`recommendation_execution.mojo` and `index/hnsw_query_scorer.mojo` follows the
same revision's `vector_storage/query_scorer/custom_query_scorer.rs`,
`index/hnsw_index/point_scorer.rs` and `graph_layers.rs`: a prepared composite
query scores stored candidates during traversal, independently of graph topology.
Akasha adapts higher-is-better similarities to its lower-is-better heap, retains
native run owners and visibility/exclusion masks, and reports planner fallbacks.
Ordinary nearest queries keep their scalar/four-row metric kernels through this
shared boundary. The existing traversal derives from Qdrant Edge commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`, with separately documented bounded
upper-layer seed reuse; this change does not claim that whole traversal is newly
ported from v1.19.0. See
[traversal provenance](benchmarks/mojo/qdrant_search_reference.md).
Full recommendation recall, datatype/storage and protocol parity remain open.

Sparse recommendation execution in `src/akasha/index/sparse_search.mojo` and
`query/recommendation_execution.mojo` adapts the same v1.19.0 revision's
`lib/sparse/src/index/search_context.rs` and
`lib/segment/src/index/sparse_index/sparse_vector_index/read_view/search.rs`.
Plain seeks reuse Akasha's ordered-posting helper; batched and final-posting
execution preserve the source's distinct zero-score rules. Native postings lack
reliable suffix maxima, so the source non-pruning branch applies. Native bounded
Top-K keeps ascending public-ID ties and admitted nonfinite recommendation scores
are rejected. The independent Rust scaffold compiles unedited search methods,
`score_vectors` and `lib/common/common/src/top_k.rs`; full server/IDF/planner and
older native nearest-contract migration remain unaccepted.

Qdrant distributes this source under the Apache License, Version 2.0; a copy of
the upstream license is included at [Qdrant license](docs/upstream/licenses/qdrant-Apache-2.0.txt).
No root NOTICE file is present at this pinned revision.

Earlier Qdrant-based ports and their reference paths are described in
[the existing alignment ledger](docs/research/2026-10-15-qdrant-alignment-evidence.md).
F00 in the full feature plan keeps the historical per-file attribution audit open;
the new port ledger does not claim that audit is already complete.

### Shared sparse nearest execution

The Q02d sparse SearchContext port also serves default/named nearest search,
point lookup, candidate reranking, and mutable/PointStore adapters. Candidate
restriction follows `lib/collection/src/shards/local_shard/query.rs::rescore`
and `filter_with_sources_ids` at Qdrant revision
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0). The source fixture
generator's `--nearest` mode retains the original methods and TopK and adds
fractional rounding, overflow and threshold cases. The Mojo sparse product
boundary preserves the source's separately rounded Float32 multiplication.
See `docs/research/2026-10-30-sparse-nearest-validation.md` and `docs/upstream/ports.json`.

### MMR diversity selection

`src/akasha/query/mmr.mojo` and `field_mmr.mojo` adapt
`lib/shard/src/query/mmr/mod.rs::maximal_marginal_relevance` and
`lazy_matrix.rs` at Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`
(Apache-2.0). The public options follow the pinned REST schema and universal
query conversion. The native ordered-cell dictionary replaces the allocation
shape of the source matrix, preserving directional scores and selection order.
The Rust oracle compiles the original selection function and existing portable
Qdrant metrics with recorded container/plumbing adapters. Source-equivalent F32
product rounding is shared by sparse, recommendation and MMR paths through
`compute/f32.mojo`. Full service/SIMD/datatype equivalence remains open.
See `docs/research/2026-10-30-mmr-validation.md` and `docs/upstream/ports.json`.
