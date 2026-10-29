# Q03b discovery/context implementation and validation

Date: 2026-10-30. Starting commit: `d1d6e45`. Mojo 1.0.0 (ed45d567),
macOS ARM64. Feature/correctness work only; no performance acceptance.

## Implemented scope

Mojo collection/snapshot `discover_field` and `discover_field_reported` support
target-only discovery, target plus context pairs and context-only queries.
Python `Collection.discover_field` and Arrow `discover_field_record_batch`
expose target/positive/negative vectors or IDs, named fields, lookup collection/
field, filtering, limits, cancellation and deadlines. Source IDs are excluded
before candidate selection only for the target collection. Captured roots own
both target data and external lookup vectors through writer update/close.

Exact dense/sparse/MaxSim scoring uses the source F32 reducers. Dense HNSW
discovery searches context for up to 10 entries, selects the highest graph level
(last eligible tie), then traverses with the complete discovery scorer.
Context-only uses one custom traversal. Sparse uses all eligible custom scores
in exact/approx, including nonoverlap. The existing native planner's explicit
exact fallbacks remain observable in stats.

Recommendation and discovery share `field_scored.mojo`; the obsolete
`recommendation_execution.mojo` was removed. Sparse recommendation dispatch
stays in `field_recommendation.mojo`; shared raw/ID resolution lives in
`field_examples.mojo`, preserving the existing public RecommendationExample.
There is no parallel Python scoring implementation.

## Source and oracle

Pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0:

- `segment/vector_storage/query/context_query.rs`: pair loss and context sum.
- `segment/vector_storage/query/discover_query.rs`: pair/query rank and score.
- `collection/src/discovery.rs`: lookup, exclusions, validation, zero-limit.
- `segment/index/hnsw_index/hnsw/read_view/search.rs`: two-stage search.
- `segment/index/hnsw_index/graph_layers.rs`: custom entry selection/fallback.
- Existing portable scalar Dot/L2/cosine, sparse score and MaxSim source ports.

`scripts/qdrant_discovery_reference.py` compiles the unedited scoring methods
and custom-entry selector. It produces **336 cases**: 120 reducer, 168 vector
and 48 custom-entry cases. Native F32 finite scores compare by bits; NaNs compare
by classification. The 168 vector cases cover 1,176 candidate scores. Python
tests compare score/ranking results and Arrow ownership. Seventy-two dense
fixtures are also exercised on real HNSW traversal with complete 112-point
graphs; these establish scorer integration, not production ANN recall.

Adapters and boundaries are recorded in the fixture README and port ledger.
The normal-entry oracle stub supplies explicit eligible primary entries; it
does not replace an oracle for Qdrant graph construction/default entry handling.
The recommendation fixture regenerated during scaffolding remained byte-identical.

## Defect found and fixed

Fixture 10, candidate 6 (zero dense vector, Dot) initially produced `0.5` instead
of upstream `-0.5`. The shared Mojo dot accumulator started at positive zero,
while Rust `Iterator::sum::<f32>` starts at negative zero. For an all-negative
example dotted with a zero vector, this changes the signed zero observed by
discovery's `total_cmp`, changing one pair's rank. The shared metric now preserves
the source identity. MaxSim also uses the source's explicit strict `>` update,
including its handling of NaN similarities.

Discovery/context may produce NaN after finite-vector arithmetic overflow.
Their finite final scores are bounded; a heap-only positive-infinity sentinel
implements upstream OrderedFloat NaN-first ranking and is converted back to NaN
on output. Exact and two-stage HNSW overflow tests cover this behavior. Existing
recommendation finite-score validation remains unchanged.

## Verification

- Rust fixture regeneration: passed; source functions compiled directly.
- `rtk proxy pixi run build-python`: passed.
- `PYTHONPATH=python:. rtk proxy pixi run python -m pytest tests/python -q`:
  **2005 passed, 1 skipped** (optional Qdrant Edge integration), three existing
  dependency/type warnings. Includes **262 new discovery cases**.
- Targeted native verification: **42 passed across 8 modules**:
  discovery 4, HNSW entries 5, recommendation 5, recommendation ANN 1,
  sparse recommendation 3, MMR 5, HNSW search layer 17, point lookup 2.
  Entry tests additionally prove that custom entries change the traversed
  component and that scratch reuse cannot carry an earlier entry into a query.
- `rtk proxy git diff --check`: passed during review; repeated before commit.

Logs: `.build/discovery-validation/`. Native checks use
`rtk proxy pixi run mojo run -I src tests/mojo/<module>.mojo`.
The Python extension and all eight native test modules were compiled against
the final engine changes. The C ABI/native worker were not rebuilt this slice;
the new APIs are not exposed there, and existing default traversal is covered
by the native layer and Python regression tests. No durable schema or GPU
behavior changed; crash/GPU suites were not repeated.
No native Linux host was available; that acceptance remains user-deferred.

## Remaining gates

Q03 remains in progress: nested prefetch/fusion MMR, universal query, discovery
batch and offset/projection options, REST/gRPC/C ABI exposure remain pending.
Multivector HNSW, complete low-precision/canonical-storage and SIMD scoring,
Qdrant planner/graph equivalence and broader recall remain open alongside Q02/Q06.
Native ascending-ID ties and existing graph upper-layer seed adaptations are
retained. Historical repeated-vector recommendation recall and M5/M6 failures
were neither removed nor retuned. All general DB, LanceDB, UI, security, cluster
and operations tasks remain in the master ledger; this slice does not establish
whole-product parity.
