# Native universal query-tree validation

Date: 2026-10-30. Mojo `1.0.0 (ed45d567)`, macOS ARM64.
Pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0.

## Implementation and source boundaries

`query_plan.mojo` ports the universal planner's recursive stages into a bounded
postorder arena. `universal.mojo` executes those stages on one retained target
read generation. All examples resolve first, collecting the union of referenced
local point IDs. Each leaf inherits every ancestor filter; parent vector
rescoring restricts the existing scorer to the union of child result IDs.
Shared exact/HNSW candidate admission and both exact fallbacks enforce that set.

Source paths are `lib/shard/src/query/{planned_query,validation,mod}.rs`,
`lib/collection/src/shards/local_shard/query.rs`,
`lib/collection/src/operations/universal_query/collection_query.rs`, and
`lib/collection/src/collection/query.rs`. Scoring reuses earlier attributed
nearest/recommendation preparation, discovery/context, sparse execution, MMR,
RRF and DBSF ports. No optimizer work or durable format changes are included.

The public native `QueryNode` arena reaches snapshot/collection `query`, with
`ReadSnapshot.query_reported` supplying aggregate statistics. Python
`QueryRequest` only serializes the tree; the bound Mojo parser validates and
captures lookup roots after all Python conversions. Repeated external owners
are retained once; self lookup shares the target root. Arrow returns owned
ID/score arrays through the same execution path.

MMR root, nested and leaf paths intentionally differ as in the pinned source.
Root MMR first nearest-rescores its union, applies threshold and diversifies;
nested MMR directly takes ordered source results without applying its threshold
or candidate count; leaf MMR prefetch contributes nearest candidates only.
Root MMR selects the original request limit before the final offset. Original
scores and source selection order survive. Whole-plan work budgeting uses
reduced copies of the same cancellation/deadline state. MMR's prior-work
parameter avoids charging a preceding stage twice; existing callers retain
their original budget convention.

## Independent reference and test evidence

`scripts/qdrant_query_plan_reference.py` compiles the **unedited** complete
planner/validation bodies and depth methods in a Rust scaffold. The adapters
provide opaque vector/filter labels and transport types. The fixture contains
103 plans: 99 valid, 4 invalid. Native assertions compare effective retrieval
limits, MMR selection/nearest-rescore phases and inherited leaf filter chains.
The reference includes 64/65-depth cases, root offsets and zero MMR candidates.

The public Python suite adds 110 cases, including 72 nested discovery pipelines
checked against the earlier independent Rust score fixtures. Other cases cover
candidate unions, empty unions, ancestor filtering before Top-K, sibling/global
ID exclusions, external lookup collisions, Arrow lifetime, root/nested/leaf MMR,
integer ID ordering above 2^53, cumulative budgets, cancellation/deadline,
malformed/cyclic/deep inputs, closing handles from conversion callbacks,
recommendation strategies, sparse/MaxSim, weighted fusion and dense HNSW over
five native scalar types across reopen/mutation.

Initial test assumptions were corrected from source evidence: Rust MMR
`max_by_key` keeps the last equally relevant candidate. The retained pinned MMR
Rust oracle selected offsets `[3, 0]` for query `[1, 1]` and ordered candidates
`[[5, 0], [4, 1], [0, 5], [1, 4]]`, diversity 1, limit 2. Weighted RRF uses
rank compression, not multiplication by weight. An I8 test mutation was also
corrected to stay within the documented signed-byte domain.

Verified commands and results:

- `rtk proxy python scripts/qdrant_query_plan_reference.py`: 103 cases, 4 errors
  expected from upstream validation.
- `rtk proxy pixi run mojo run -I src tests/mojo/test_universal_query.mojo`:
  4 passed, including all 103 source plans and retained snapshot/lookup ownership.
- `rtk proxy pixi run build-python`: passed.
- `rtk proxy pixi run test-python`: **2115 passed, 1 skipped**; rebuilds the Python
  extension and native maintenance worker. The skip is the existing optional
  Qdrant Edge integration. Three existing binding/FastAPI deprecation warnings.
- Targeted native `test_mmr`, `test_discovery`, `test_recommendation_ann`:
  **5 + 4 + 1 passed**. Logs are under `.build/universal-query-validation/`.
- Total relevant native tests: **14 passed**, across four modules.

## Remaining acceptance

This verifies the native query-tree slice, not the full Q04 or product goal.
Sampling, formula/boosting/feedback, order-by/group/facet/matrix, full cursor,
batch/projection and Qdrant REST/gRPC/C exposure are still open. Query-only
scroll currently returns IDs and zero scores. Rich payload/schema, Lance table
history/interoperability, general transactions/SQL, UI/security/cluster and
operations remain on the master ledger.

Existing native finite-score validation and ascending-ID fusion ties remain;
the source does not specify fusion ties. Full nonfinite/datatype/canonical
storage and SIMD parity is not proven. The oracle does not run an actual Qdrant
server or validate distributed shard merges. Existing source-derived HNSW
lineage/planning and recorded repeated-vector recall gaps remain. No performance
claim follows from these correctness tests.

No full CPU/C ABI/crash/GPU or native Linux acceptance was rerun for this slice.
There are no persistence or GPU changes. Native Linux remains user-deferred;
M5/M6 remain failed/open and optimization remains deferred until functionality
is complete.
