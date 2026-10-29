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

### Discovery and context queries

`query/discovery.mojo`, `discovery_scorer.mojo` and `field_discovery.mojo`
port Qdrant `segment/vector_storage/query/{discover_query,context_query}.rs`
and `collection/src/discovery.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
`query/field_scored.mojo` and `index/hnsw_entries.mojo` adapt the two-stage
`discover_search_with_graph` in `index/hnsw_index/hnsw/read_view/search.rs`
and the custom-entry branch of `graph_layers.rs::get_entry_point`.

The former `recommendation_execution.mojo` is now shared as `field_scored.mojo`;
the sparse recommendation dispatcher remains in `field_recommendation.mojo`.
Shared point/vector resolution moved into `field_examples.mojo`, preserving the
public RecommendationExample type. Existing source attribution still applies.
Scorers preserve Rust total_cmp, non-NaN min behavior, the signed-zero identity
of Iterator::sum and source MaxSim's strict greater-than maximum update. NaN
discovery scores use an infinity sentinel only for native heap ordering, then
return as NaN. Native stable ID ties, exact planner, run visibility, graph
lineage and raw-storage preprocessing adaptations remain.

The independent Rust oracle compiles unedited score and custom-entry methods;
container/filter/normal-entry fallback stubs are documented adapters. It is
not a full server, graph construction/traversal, SIMD or datatype/storage oracle.
See `tests/fixtures/qdrant-discovery/README.md`,
`docs/research/2026-10-30-discovery-validation.md` and `docs/upstream/ports.json`.


### Universal query planning and nested prefetch

`query/query_plan.mojo` and `query/universal.mojo` adapt Qdrant's
`lib/shard/src/query/planned_query.rs`, `validation.rs`,
`lib/collection/src/shards/local_shard/query.rs`,
`lib/collection/src/operations/universal_query/collection_query.rs`, and
`lib/collection/src/collection/query.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
The native postorder arena replaces recursive ownership while retaining ordered
sources, inherited filters, global local-ID exclusion, candidate unions, limits,
offsets and root/nested/leaf MMR stage distinctions. Native resource limits,
fixed read roots, finite-score checks and ascending-ID fusion ties remain.

The Rust planner oracle compiles the complete unchanged planner and validation
bodies with opaque vector/filter/transport type adapters. It does not execute a
Qdrant server or prove shard merging, scoring or protocol compatibility.
See `tests/fixtures/qdrant-query-plan/README.md` and `docs/upstream/ports.json`.

### Numeric score formulas

`query/formula.mojo`, the formula branches of `query/query_plan.mojo` and
`query/universal.mojo`, and the bound expression conversion adapt Qdrant
`segment/index/query_optimization/rescore_formula/{formula_scorer,parsed_formula}.rs`,
`segment/segment/read_view/formula_rescore.rs`, `shard/query/formula.rs`,
local-shard formula rescoring and REST expression schemas at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).

Native bounded arenas, flat payload values, retained read roots, resource limits
and stable ID ties replace allocation/transport/storage plumbing. Numerical
evaluation and decay follow the source. The Rust release oracle compiles eight
unchanged upstream function bodies; date/geo adapters are deliberately unusable
and unexercised. Full JSON-path/date/geo/rich-payload and protocol behavior remain
open. See `tests/fixtures/qdrant-formula/README.md`,
`docs/research/2026-10-30-formula-validation.md` and `docs/upstream/ports.json`.
