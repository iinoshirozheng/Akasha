# Third-party source notices

Akasha contains adaptations of open-source database implementations. Port-specific
revisions, original source hashes, modified files and executable reference evidence
are recorded in [the source-port ledger](docs/upstream/ports.json).

## Point/path conditions and deterministic slice hashes

`query/point_condition.mojo`, `query/evaluator.mojo` and their context integration
translate Qdrant `types.rs`, `payload_storage/query_checker.rs` and
`common/utils.rs` at `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Native owned predicates and retained catalogs replace storage handles; nested
identity isolation and whole-path null/empty behavior follow the source.

`compute/siphash.mojo` translates zero-key SipHash-2-4 from siphasher 1.0.3,
commit `451f67d73a772cba325728109bbfa247750ed076`, `src/sip.rs` and
`src/common.rs`. Copyright 2012-2016 The Rust Project Developers;
Copyright 2016-2026 Frank Denis. The upstream [COPYING notice](docs/upstream/licenses/siphasher-COPYING.txt)
offers MIT or Apache-2.0; this adaptation uses Apache-2.0, whose full text is
included in [the retained Apache license](docs/upstream/licenses/qdrant-Apache-2.0.txt).
Owned byte lists and native UInt64 operations replace Rust slices and wrapping
operations; round ordering, constants, canonical bytes and output are unchanged.
The actual crate supplies reference hashes, with archives checked against
Qdrant's lockfile. See `tests/fixtures/qdrant-point-filter/` and port D03f.

## Polygon geometry and robust orientation

`src/akasha/document/geo_polygon.mojo` translates Qdrant v1.19.0 GeoPolygon
validation and conversion (`74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0),
geo 0.33.1 polygon containment and winding-number coordinate position
(`5ab50b072e34a915a33eaa46c80763d51d61295e`), and geo-types 0.7.19 exact ring
closure (`981be9feea12cdede572fb252064536cb8b287b1`). GeoRust code is copyright
(c) 2017 The GeoRust Project Developers, MIT OR Apache-2.0; the chosen
[MIT license](docs/upstream/licenses/geo-MIT.txt) is included. The geo-types
repository license at its pinned revision was checked against this copy.

`src/akasha/compute/robust_orientation.mojo` translates robust 1.2.0 `orient2d`
and its reachable expansion arithmetic, commit
`654f34cb8cdb3ae21bf59ef3472f92652942cd74`. Copyright 2017 The Spade Developers;
Copyright 2020 The GeoRust Project Developers. It is MIT OR Apache-2.0; the
chosen [MIT license](docs/upstream/licenses/robust-MIT.txt) is included. The
source credits Jonathan Richard Shewchuk's adaptive precision predicates.
Mojo uses bounded active expansion lists and separate rounded products; there
is no replacement geometry algorithm. Native exact-bit tests compare against
the actual crate; a separately traced source copy verifies branch coverage.

The fixture generator reuses original Qdrant checker code and actual pinned
GeoRust dependencies. Source units, archives, locks, adapters and verification
are recorded under `tests/fixtures/qdrant-polygon/` and port `D03e-geo-polygon`.

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

### JSON paths and Unicode identifiers

`document/json_path.mojo` and formula variable/default integration port Qdrant
`lib/segment/src/json_path/{parse,mod}.rs` and
`index/query_optimization/rescore_formula/parsed_formula.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0). Native bounded cursors
replace nom combinators; quoted/raw key grammar, UInt64 indexes, canonical
display and path operations follow the source.

`document/unicode_alphanumeric.mojo` contains generated ranges derived from the
Rust project's Unicode 17.0.0 Alphabetic/N data and character classifier in
Rust 1.97.1, licensed MIT OR Apache-2.0. The MIT license is retained at
`docs/upstream/licenses/rust-MIT.txt`. Source URLs and hashes, generator, oracle
and native artifact hashes are recorded in `docs/upstream/ports.json` and the
JSON-path fixture. There is no runtime Rust/nom/Python classification dependency.
The reference-only Cargo dependency graph is pinned in the fixture's Cargo.lock.

### Rich payload value access and mutation

`document/payload_path.mojo` ports the JSON value get/set/remove routines from
Qdrant `lib/segment/src/json_path/mod.rs` and `merge_map` from
`lib/segment/src/common/utils.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Bounded owned Mojo arenas adapt serde_json trees; map ordering and swap removal
follow Qdrant's `preserve_order` configuration. Payload binary v2 is Akasha's
versioned durable representation, not Qdrant's on-disk codec. The oracle compiles
unchanged source bodies; see `tests/fixtures/qdrant-payload-values/README.md`.
`query/evaluator.mojo` also ports one-level array and null/MatchExcept checks
from `lib/segment/src/payload_storage/condition_checker.rs` at the same revision.
Rich values without a dedicated field index use this check in the metadata
index; the source oracle compares both direct and indexed results.

### Collection payload mutations

`document/payload_update.mojo` and `storage/payload_update.mojo` adapt Qdrant
`lib/shard/src/update/payload.rs`, `update/helpers.rs`, `update/mod.rs`, `operations/payload_ops.rs`
and `lib/segment/src/segment/entry.rs` at the same Apache-2.0 revision. They reuse
the ported JSON-path/map operations and native filter evaluator. Ordered top-level
DocumentField lists preserve Akasha's per-field depth limits. The existing
writer lock and atomic replacement WAL batch replace Qdrant's segment/chunk
plumbing; native row sequences and acknowledgment results remain distinct.
See `docs/research/2026-10-30-payload-mutations-validation.md` and the port registry.

### Rich payload formula retrieval

`query/formula_payload.mojo` and formula/default integration port the
authoritative payload retriever from Qdrant
`lib/segment/src/index/struct_payload_index/read_view/value_retriever/helpers.rs`
and value/default selection in `index/query_optimization/rescore_formula/formula_scorer.rs`
at the same Apache-2.0 revision. The DocumentField root adapter reuses the ported
JSON paths; one-level flattening, wildcard suffix, missing vs null and typed
numeric defaults follow the source. The new oracle compiles the original parser,
retriever and scorer together with real serde_json values. See
`tests/fixtures/qdrant-formula-payload/README.md` and `docs/upstream/ports.json`.
Dedicated typed-index retrievers, date expressions and full protocols remain open;
the subsequent geographic port is described below.

### Typed Arrow payload ingress

`src/bindings/arrow_payload.mojo` and `python/akashadb/arrow_payload.py` adapt
Arrow array buffer access, child slicing and validity rules and Lance's null
masking/garbage-list rules to Mojo-owned JSON values. Arrow Rust array, buffer,
data and schema 58.4.0 are pinned by Lance's Cargo.lock. Apache Arrow copyright
2016–2026 The Apache Software Foundation; Apache-2.0 license and original notice
are retained in `docs/upstream/licenses/arrow-Apache-2.0.txt` and
`docs/upstream/licenses/arrow-NOTICE.txt`. Lance's `rust/lance-arrow/src/list.rs`
and `struct.rs` at `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` are Apache-2.0,
copyright The Lance Authors; its license is retained in
`docs/upstream/licenses/lance-Apache-2.0.txt`.

The independent reference executable compiles those unchanged Lance units and
uses actual Arrow IPC 58.4.0 / JSON 58.3.0 to produce fixtures. Rust remains a
test-generation dependency only. Archive checksums, source hashes, adaptations
and limits are recorded in `tests/fixtures/rich-arrow` and the port registry.

### Typed Arrow payload export and numeric conversion

`src/bindings/arrow_payload_export.mojo` follows the same Arrow/Lance nested
array, offsets, validity and required-child rules. `arrow_buffers.mojo` extracts
the existing C Data buffer owner without changing its ABI/release behavior.
Numeric narrowing adapts Arrow 58.4.0 `cast_numeric_arrays`/`try_numeric_cast`/
`num_cast`, num-traits 0.2.19 `NumCast`, and half 2.7.1's `NumCast for f16`.
The F16 path retains the source's intermediate F32 rounding. Akasha additionally
rejects nonfinite output and keeps its existing strict numeric type families.

Arrow's Apache-2.0 license/notice are listed above. Half and num-traits are
MIT OR Apache-2.0; the original MIT files are retained at
`docs/upstream/licenses/half-MIT.txt` and `docs/upstream/licenses/num-traits-MIT.txt`.
The independent Arrow cast executable and archive/source hashes are in
`tests/fixtures/rich-arrow-export`. No Rust numeric runtime is introduced.

### Native JSON owned-value reader

`src/akasha/document/json_reader.mojo` adapts serde_json 1.0.151 `de.rs`
integer/decimal/exponent parsing, SeqAccess/MapAccess grammar and `read.rs`
escape, surrogate and UTF-8 rules. `json_number_tables.mojo` contains the
original `de.rs` POW10 literals. The explicit profile uses std/preserve_order,
without float_roundtrip or arbitrary_precision; native resource limits and
PayloadValue storage are Akasha adaptations. This does not claim Lance/jsonb
numeric equivalence.

serde_json is MIT OR Apache-2.0. Its original MIT license is retained at
`docs/upstream/licenses/serde-json-MIT.txt`. Source/archive hashes, exact Cargo.lock
and the independent 5,630-case reference are in `tests/fixtures/json-value`.
Rust and Python are reference/test infrastructure, not the native parser runtime.

### Arrow StringView and Lance JSON reference

`src/bindings/arrow_payload.mojo` and `arrow_payload_export.mojo` adapt Arrow
58.4.0 `arrow-data/src/byte_view.rs` view layout/validation and `ffi.rs` variadic
buffer-length trailers. Existing Arrow Apache-2.0 license and NOTICE apply.
Mojo preserves active null masking and uses the existing owned C Data allocator.

The independent reference compiles pinned Lance `lance-arrow/src/json.rs`
unchanged and calls jsonb 0.5.6 to record source contracts, alongside actual
Arrow StringViewBuilder/IPC output. Its text parser remains reference-only;
the native binary-value port is described below. Pinned dependency checksums,
licenses/upstreams and source hashes are in `tests/fixtures/lance-json/sources.json`.

### Native JSONB binary values

`src/akasha/document/jsonb.mojo` adapts jsonb 0.5.6 databend container/entry
layouts, compact numeric/extension encoding and decoding, and array/object
builders from `core/databend/{constants,jentry,ser,de,builder,util}.rs`.
Copyright 2023 Datafuse Labs. Apache-2.0; the original license is retained at
`docs/upstream/licenses/jsonb-Apache-2.0.txt`. Source/archive identities and the
independent actual-crate oracle are in `tests/fixtures/jsonb-codec/sources.json`.
Native adaptations add complete-consumption/UTF-8/bounds/resource validation
before owning bytes, use Mojo's standard sort for ObjectBuilder's sorted keys,
and keep outer nullability independent. Neither Rust nor Python implements the
binary codec at runtime. Text parsing/formatting and durable integration remain
separate work; this is not a full jsonb/LanceDB implementation.

### Geographic point validation and formula distance

`document/geo.mojo`, geographic formula integration and input conversion adapt
Qdrant GeoPoint/GeoPointShadow validation and formula schema/parse/scoring at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
Haversine distance and the mean-radius constant are ported from GeoRust `geo`
0.33.1, commit `5ab50b072e34a915a33eaa46c80763d51d61295e`,
`geo/src/algorithm/line_measures/metric_spaces/haversine.rs`.
Copyright (c) 2017 The GeoRust Project Developers. GeoRust is licensed
MIT OR Apache-2.0; this port includes the MIT notice at
`docs/upstream/licenses/geo-MIT.txt`. The original registry archive checksum,
source hash and oracle Cargo.lock are recorded in `docs/upstream/ports.json`.
The Rust oracle runs Qdrant's unchanged GeoPoint methods/retriever/scorer with
the actual pinned geo crate. There is no runtime Rust or Python geometry engine.

### Datetime parsing and formula expressions

`document/datetime.mojo` and the datetime formula/binding integration adapt
Qdrant's DateTimeWrapper parsing/timestamp and formula behavior from
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).
The native parser's fixed format modes specialize chrono 0.4.45's reachable
`format/{parse,scan,parsed}.rs` branches. Calendar validation, ordinal tables,
epoch/timestamp and UTC conversion follow `naive/` and `datetime/` source at
`170338250e836976a211e64728ec956e45e78a39`. Copyright (c) 2014--2026 Kang
Seonghoon and contributors; parsing portions copyright (c) 2015 John Nagle.
Chrono is MIT OR Apache-2.0; its original license file is retained at
`docs/upstream/licenses/chrono-LICENSE.txt`.

`chrono_tables.mojo` is generated from chrono's literal calendar tables and
Rust's `core/src/unicode/unicode_data.rs::white_space` lookup/table. The latter
uses the Rust Project's MIT/Apache-2.0 license; the retained MIT notice is
`docs/upstream/licenses/rust-MIT.txt`. The source-unit hash is pinned and its
classification was compared with the oracle compiler over every Unicode scalar.
The port registry records source/archive/table hashes and the actual compiler
and source-toolchain versions separately. Python generates source fixtures and
literal tables only; it does not parse or score dates at runtime. The oracle
executes Qdrant's original wrapper/retriever/scorer with the actual chrono crate.

### Plain payload predicates and nested filters

`query/payload_condition.mojo`, `query/evaluator.mojo`, `query/filter_ast.mojo`
and metadata integration adapt Qdrant `payload_storage/condition_checker.rs`,
`payload_storage/query_checker.rs`, `types.rs` and `json_path/mod.rs` at
`74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0). Field match/set/plain-text,
range, count, empty/null, geographic predicates, nested object scope and minimum
matches follow these sources. DateTime and geographic arithmetic reuse the
chrono/GeoRust ports described above. Text-any splitting reuses the pinned Rust
Unicode whitespace table.

The oracle compiles original checker methods, Boolean combinators and JSON paths
with pinned serde_json, chrono and geo crates. Akasha expression dictionaries and
DocumentField roots replace upstream transport/storage plumbing. Index-specific
text behavior and polygon evaluation are not claimed by this slice. See
`tests/fixtures/qdrant-payload-filter/README.md` and `docs/upstream/ports.json`.

### Lance materialized bitmap scalar target

`src/akasha/index/lance_scalar.mojo` and `lance_bitmap.mojo` adapt Lance
`scalar/btree.rs`, `scalar/bitmap.rs` and `lance-index-core/src/scalar.rs` at
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` (The Lance Authors, Apache-2.0).
DataFusion common 54.1.0 ScalarValue equality supplies typed bitwise Float64
identity; its Apache-2.0 license and original NOTICE are retained at
`docs/upstream/licenses/datafusion-LICENSE.txt` and `datafusion-NOTICE.txt`.
Rust core `f64::total_cmp` at `ded5c06cf21d2b93bffd5d884aa6e96934ee4234`
supplies the signed-bit ordering transform (Rust Project, MIT OR Apache-2.0;
existing `docs/upstream/licenses/rust-MIT.txt`). Existing Lance/Arrow/roaring
notices apply to the reused source and independent oracle.

The native port uses owned sorted key arrays, source-ported Roaring sets and
bounded immutable result publication. It does not include Lance file codec,
cache, shard merge or DataFusion execution. The Rust reference executes original
methods with real Arrow/DataFusion/roaring and transport/store adapters only;
these crates are test infrastructure, not new runtime dependencies. Pinned
source/unit/archive hashes and adaptation scope are in `tests/fixtures/lance-bitmap`
and `docs/upstream/ports.json`.
