# Existing Akasha functionality: Qdrant alignment implementation plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Align every existing Akasha capability with the applicable Qdrant implementation and behavior, with executable evidence for shared behavior and explicit treatment of Akasha contracts without a Qdrant equivalent.

**Architecture:** Use Qdrant Edge 0.8.0 source commit `21db2f3ff95d50de3a2b88a741312c056fd1762d` as the reproducible single-node reference, and the same repository for distributed implementation comparisons. Replace obsolete internal algorithms in independently working layers. Preserve Akasha's documented public types, score units, stable ties and durable data through explicit adapters or format migrations; do not silently change public contracts or introduce Qdrant features Akasha does not expose.

**Tech Stack:** Mojo 1.0.0, existing Python/C/Arrow bindings, pinned Qdrant Rust source and Edge Python 0.8.0, current project test and benchmark harnesses.

---

## Scope confirmed by the user

On 2026-10-15 the user chose **Akasha 現有功能全面對齊 Qdrant 的實作與行為**. This includes existing distributed, storage, import/export and service capabilities in the comparison. It does not request every Qdrant-only API. Implementation parity is not performance acceptance: the existing M5/M6 recall, QPS and p95 gates remain unchanged.

Worktree: `.worktrees/qdrant-alignment`, branch `feat/qdrant-alignment`.
Prior reference: `docs/research/2026-10-14-qdrant-source-baseline.md`.

## Coverage ledger

Source evidence, executable checks and current dispositions for every capability
below are recorded in the [alignment evidence ledger](../research/2026-10-15-qdrant-alignment-evidence.md).
That ledger also splits learned SQ8/PQ from raw compact storage and records
their source-backed differential results. The table below retains the
original implementation tasks; it is not a completion checklist.

| Existing capability | Akasha implementation | Qdrant reference area | Initial disposition |
| --- | --- | --- | --- |
| Dense dot/L2/cosine; stable top-k | `compute/{distance,metric,topk}.mojo` | `segment/src/spaces`, `vector_storage/raw_scorer` | Audit numerical behavior; preserve documented squared-L2 and stable-ID ordering through comparison adapters |
| Compact F16/BF16/I8/U8 and binary metrics | `compute/{quantization,field_metrics}.mojo` | dense byte/half metrics, quantization | Audit shared representations; distinguish raw scalar storage from learned quantization; BF16, signed I8 and binary field APIs are Akasha contracts |
| HNSW construction | `index/{hnsw,hnsw_core,hnsw_level}.mojo` | `graph_layers_builder.rs`, `links_container.rs` | Replace symmetric eviction repair and refill with independent heuristic backlink pruning |
| HNSW entries and filtered traversal | `index/{hnsw_core,hnsw_scratch,hnsw_view}.mojo` | `entry_points.rs`, `graph_layers.rs`, `point_scorer.rs` | Replace single-entry admission-only traversal after payload connectivity is integrated |
| Metadata indexes and boolean filters | `index/{metadata,keyword,sorted_postings,sorted_block}.mojo`, `query/{evaluator,index_evaluator}.mojo` | payload indexes, filter optimizer | Verify shared flat scalar predicates and missing-field/negation behavior; add payload graph block generation |
| Planner / exact vs ANN | `query/planner.mojo`, `query/executor.mojo` | `hnsw/read_view/dispatch.rs` | Align cardinality-driven routing with existing resource controls |
| Base/delta updates, deletes, current-source authority | `index/segmented_hnsw.mojo` | segment search, proxy segments, deleted vectors | Align eligibility before distance and merging; preserve captured-generation visibility |
| Authoritative reranking | `query/field_ann.mojo`, `index/segmented_hnsw.mojo` | `vector_index_search_common.rs` | Remove redundant work only where scores and top-k remain equivalent; compact representations still need authoritative scoring |
| Named dense and multi-vector MaxSim | `document/vector_schema.mojo`, `compute/field_metrics.mojo`, `query/field_search.mojo` | multivector scorers, named vector storage | Differential-check presence, shape, aggregation and score units |
| Sparse postings | `index/{sparse,field_sparse}.mojo` | `sparse/src/index/search_context.rs` | Compare candidate admission, zero/negative scores, updates and filtering |
| Hybrid and multi-field RRF / final rerank | `query/{fusion,field_fusion}.mojo` | `segment/src/common/reciprocal_rank_fusion.rs` | Compare rank origin, rank constant and candidate-union ordering; Migrate to Qdrant default 2, zero-based ranks and F32 sums (user approved) |
| IVF | `index/field_ivf.mojo`, `query/field_ivf.mojo` | No direct Qdrant IVF counterpart | Preserve and verify Akasha contract; do not mislabel as Qdrant parity |
| Atomic point and vector/payload mutation | `document/point_state.mojo`, collection mutation paths | segment updater, vector storage, payload storage | Compare upsert/replacement/deletion/replay behavior for shared operations |
| WAL, segments, manifests and recovery | `storage/` | `wal`, segment flush, shard recovery | Retain Akasha durable format; align durability and replay invariants, validate torn writes and restart |
| Mapped HNSW / index readiness | `storage/hnsw_store.mojo`, `index/hnsw_view.mojo` | graph links mmap, HNSW build/publish | New version for directed and supplementary adjacency plus entry pools; v1/v2 fixtures remain readable and validated |
| Background optimization and concurrent reads | generation/lease/compaction and collection locks | segment holder, optimizer, proxy segments | Audit publication critical section and pinned read ownership; verify concurrent mutations and cancellation |
| Snapshot / backup / logical restore | `storage/backup.mojo`, `python/akashadb/{operations,logical_points}.py` | snapshots, Edge snapshot API | Compare recovery invariants; formats remain Akasha-specific |
| Python / C / Arrow / HTTP boundaries | `src/bindings`, `python/akashadb`, service | Edge Python/FFI, service handlers | Verify existing API behavior and ownership; no Qdrant wire-API expansion |
| Distributed routing, replication, failover | `python/akashadb/distributed/` | collection shard/replica/transfer paths | Audit existing documented quorum and query behavior; do not claim Raft equivalence |
| Query budgets, cancellation, metrics | `query/control.mojo`, common metrics, services | query context, cancellation, hardware counters | Preserve public budget/accounting contracts; verify native traversal checks |
| GPU exact/search capability | `compute/gpu`, GPU tests | GPU graph building / scoring | Compare only overlapping semantics; actual-device test remains required for changes |

## Task 1: Establish a reproducible baseline and inventory

- [x] Pin upstream source and retain Apache-2.0 attribution.
- [x] Confirm scope with user; create isolated worktree using the existing installed toolchain.
- [x] Run the nine reference boundary tests on the new worktree.
- [x] Complete source-backed dispositions for the coverage ledger.
- [x] Close the identified learned SQ8/PQ and raw F16 cosine differences; record adapters and remaining acceptance separately.

Commands start with `rtk`. Targeted Mojo command: `rtk proxy pixi run mojo run -I src tests/mojo/<test>.mojo`. Reference differential: `rtk proxy pixi run python -m benchmarks.qdrant_search_reference --output .build/qdrant-source-reference/<new-run>`.

## Task 2: Directed HNSW construction and durable migration

Files: `src/akasha/index/{hnsw,hnsw_core,hnsw_storage,hnsw_view}.mojo`, `src/akasha/storage/hnsw_store.mojo`; `tests/mojo/test_hnsw_{links,invariants,store,store_v1_compat,store_v2,view}.mojo`; durable format documentation.

1. Add a regression fixture where pruning a backlink removes that backlink but retains the new point's independently selected outgoing link. Add a fixture where non-diverse candidates are not refilled merely to reach m.
2. Run the regression against the old implementation and record the failure.
3. Port upstream `fill_from_sorted_with_heuristic` and the reference semantics of `connect_with_heuristic_simple`; preserve Akasha's stable tie policy. Replace production construction calls, not just a benchmark prototype.
4. Version the sidecar so directed graphs are valid only under the new contract. Keep strict legacy decoding, bounds, duplicate/self-edge and level validation. Preserve old fixture bytes; re-encode loaded legacy data in the new format.
5. Verify owned and mapped reopen, bad CRC, CRC-valid malformed edges, truncation, and old fixtures. Run construction/invariant/quality tests.

## Task 3: Entry pool and graph build/search agreement

Files: new `src/akasha/index/hnsw_entries.mojo`, existing HNSW index/core/view/store, reference differential driver and targeted tests.

1. Test first eligible primary, highest eligible extra, promotion, invalid/deleted entries and bounded extra capacity against upstream `EntryPoints`.
2. Integrate pools into construction, owned and mapped search and serialization. Validate every stored entry and ensure empty/missing entries cannot trigger an unintended full scan.
3. Use the existing extracted upstream traversal oracle on integrated production routines; account for explicit stable ties separately.

## Task 4: Payload connectivity and source eligibility

Files: metadata indexes, HNSW storage/build, segmented index, collection publication/recovery paths, filtered and segmented tests.

1. Derive payload blocks from existing indexed scalar fields using upstream cardinality/connectivity rules. Test equality and range blocks and skipped blocks.
2. Build eligible block graphs and union links and primary entries. Support supplementary adjacency in the versioned representation with checked allocations and lengths.
3. Replace filtered search with filter-before-score only after construction and reopen preserve reachability. Test rejected-bridge, replacement, deletion, base/delta, restart and compaction cases end to end.
4. Remove superseded traversal paths and update documented bridge expectations to the new build/search invariant.

## Task 5: Planner, merge and score boundary

Files: planner/executor, segmented HNSW, named field ANN, relevant tests.

1. Differential-check exact and approximate shared cases including dense score conversion and ties.
2. Align exact/graph dispatch using cardinality and storage cost; preserve user-requested exact behavior and resource limits.
3. Use top-k without redundant authoritative rescoring only when stored F32 is exactly authoritative under the metric contract. Preserve necessary compact/cosine reranking and replacement authority.
4. Test per-source candidate merging, negative dot scores, missing named vectors, zero results and cancellation.

## Task 6: Remaining search and mutation features

Files: sparse, field metrics/fusion, metadata evaluators, document mutations, Python API tests and new shared-behavior oracle fixtures.

1. Add deterministic small data fixtures for sparse, named dense, MaxSim, RRF, flat boolean predicates and updates/deletes.
2. Execute them against pinned Qdrant and Akasha, comparing canonicalized score units and explicit tie policies.
3. Correct observed behavior differences in native production paths with narrow regressions. Record non-overlapping features rather than adding unnecessary compatibility layers.

## Task 7: Persistence, concurrency and boundaries

1. Trace WAL acknowledgement through flush/publication/reopen and compare upstream invariants. Run relevant crash and format-compatibility tests after storage edits.
2. Trace query capture through optimization and release; keep publication work outside the critical section where ownership permits. Verify query/update/flush races and resource lifetimes.
3. Cover existing Python/C/Arrow/HTTP and distributed operations with their integration suites. Document each intentional format/protocol distinction and evidence.

## Task 8: Acceptance

1. Run the standard CPU suite and affected crash/distributed/service suites. GPU tests only if GPU code changed and actual hardware is available.
2. Build native artifacts and execute unchanged quality/performance matrices. Do not infer performance from source parity or simulated Linux.
3. Update every coverage row with passing evidence or a concrete remaining gap. Do not mark full alignment complete while required work or acceptance remains.

## Execution record

- Baseline: Mojo `1.0.0 (ed45d567)`; reference boundary tests 9/9 passing in isolated worktree.
- HNSW: directed independent prune/no refill, rounded level sampler, entry pools,
  filter-before-score traversal, payload equality/range block graphs, expanded
  adjacency and HNSW sidecar v3 implemented. Frozen v1/v2 readers retained.
  Production traversal vs extracted upstream Rust: 98/98 cases passed in
  `.build/qdrant-source-reference/entry-levels/summary.json` (result IDs and
  distance counts). Broad HNSW suite plus targeted fixes are recorded under
  `.build/qdrant-alignment/{hnsw-suite,fixes}`.
- Payload graphs are now built for named fields and persisted default bases;
  first flush/reopen, payload-only update, delete and compaction lifecycle tests
  pass. A source audit corrected supplementary graphs to level zero; entry
  records now retain `(slot, level)` across owned/mapped reopen, and malformed
  levels are rejected. Upper-layer links remain unchanged by payload builds.
- Upstream probabilistic connectivity skipping is integrated. Connectivity
  versus unedited Rust methods: 128/128, including exact random consumption,
  `.build/qdrant-source-reference/connectivity-2/summary.json`. Serial L2 build
  versus upstream optimized construction: 24/24 fixtures, all 2,467 ordered
  adjacency rows, `.build/qdrant-source-reference/build-2/summary.json`.
  Random streams, stable field/ID ordering and threshold/capacity policy are
  explicit Akasha adaptations, not bit-identical Qdrant defaults.
- Quality gate remains failing for L2 recall: 0.9458333333 at the fixed 0.95 gate.
  A native Edge run on the same corpus also measured 0.9458333333; this is a
  diagnostic, not a waived gate or a performance pass. Dot/cosine passed.
- User explicitly approved Qdrant public behavior and corresponding docs/tests:
  RRF constant 2 and zero-based ranks, nonzero sparse candidates with F32
  accumulation, whole-point upsert vs partial update. Typed point paths are
  migrated; default and formerly legacy collection writes now use the same
  PointStore authority. Frozen pre-change bytes validate legacy cutover.
  New point WAL v5 distinguishes replacement from historical v4 merge.
- Before migration, the native shared-behavior oracle passed 6/16 cases:
  `.build/qdrant-behavior/before-migration-3/summary.json`. Dense/MaxSim examples
  passed; sparse/RRF/upsert failed. That initial oracle's update case followed
  the mismatching upsert and was contaminated; the runner now isolates it.
- WAL v5 transition, frozen v4 merge fixture, mixed v1-v5 stream, all truncations,
  corruption and point-table replay checks pass. New point checkpoints use v5
  to admit zero sparse weights; the frozen v4 reader still rejects those values.
- Full coverage ledger, CPU/integration/crash/distributed validation, and unchanged
  M5/M6 acceptance are still required. No claim of full alignment yet.

- Native behavior/source oracle: 65/65 in
  `.build/qdrant-behavior/after-migration-3/summary.json`. Covers dense/MaxSim,
  sparse empty/zero/cancellation/overflow cases, exact F32 RRF including a large
  rank constant, replace/update/reopen, and scalar boolean filter composition.
  Four boolean cases use Qdrant Rust core because the Edge Python binding
  converts bool MatchValue to integer; the runner records this limitation.
- CPU validation before the latest HNSW changes: Python/distributed 379 passed,
  one old Arrow contract expectation fixed and 26 Arrow tests passed; then
  affected Python/distributed 174 passed. C API passed; crash suite 23 passed.
  The broader Mojo core sweep and targeted fixes are recorded under
  `.build/qdrant-alignment/{core-suite,fixes}`. Latest payload/entry/storage
  regressions: nine files passed in `payload-final/summary.json`; frozen v1/v2
  sidecars passed in `entry-levels/summary.json`. These are cumulative evidence,
  not a claim that the unmodified CPU quality gate is green.
- Controlled HNSW traversal now checks cancellation inside descent and beam
  loops. New owned/mapped tests cancel during admission and verify interruption
  plus subsequent scratch reuse; named-field control tests also pass.

- Zero cosine vectors now score zero across scalar/SIMD, compact HNSW,
  owned/mapped graph, quantization and GPU exact paths. HNSW v1/v2 retain
  historical zero-vector validation; v3 permits zero rows. The native behavior
  oracle now passes 69/69 (`.build/qdrant-behavior/unified-authority/summary.json`).
  Actual M4 GPU tests passed, including both zero-vector kernel paths.
- All public default/named mutations now use one point WAL and checkpoint
  authority. Legacy independent writers were removed. Empty and zero sparse
  vectors pass through Python/Arrow/native import atomically; zero-scored hits
  are excluded in both posting and snapshot scan paths. Frozen sparse WAL v1
  and segment v1/v2 codecs preserve their historical validation rules.
- Added 17 frozen legacy database fixtures (8,245 bytes plus generation recipe
  and SHA-256 manifest), generated with unmodified `f6a938a` sources. They cover
  identity migration, malformed input, retained HNSW and checkpoint cutover.
  Full-table PointStore checkpoint compaction was removed from the writer lock;
  existing captured-prefix background compaction handles publication/backpressure.
- Unified authority checks: PointStore/persistent batch/sparse/migration tests,
  background publication 20/20, field envelopes 8/8, C API, and Python/distributed
  382 passed with one skip; the remaining trace-schema test was corrected and
  all three operation tests passed. Storage operations and five affected crash
  files all pass in `unified-crash-fixes/summary.json`; three other crash files
  passed unchanged in `unified-recovery-final/summary.json`.
- Planner work: removed the historical 2*k and dimension/ef cost shortcuts.
  Dispatch follows cardinality, sharing its N/8 threshold with payload graphs.
  N/8 and the 64-point readiness floor remain explicit Akasha tuning; they are
  not Qdrant's default 10,000 KiB setting. Exact bitmap cardinality uses a
  deterministic graph decision at equality instead of random estimation.
  Planner regression: two failures before the change, 10/10 afterward.

- Named HNSW dispatch now checks field presence and filter cardinality before
  constructing a graph. A failing-build injection proved the old path built an
  unused graph; all four named HNSW tests now pass, including concurrent first
  queries and cancellation. Root-cached graphs reuse their field row population.
- Full Python/distributed/service suite after planner integration: 383 passed,
  one skip. Subsequent replica audit found split dense/sparse writes, missing
  parent-directory synchronization and unsafe retry after an uncertain journal
  append. Replica/snapshot application now uses one point batch; shared directory
  synchronization and write poisoning/recovery were added. New failure tests plus
  protocol/multiprocess tests: 28/28. Empty sparse hybrid queries also now match
  native behavior (multiprocess regression passes).
- Quality reference is now reproducible via
  `benchmarks/qdrant_quality_gate_reference.py`: three fresh native Edge runs
  all produced L2 recall 0.9458333333; each checked its exact IDs against an
  independent F64 oracle. Evidence: `quality-reference-repro/summary.json`.
  This does not waive or modify the 0.95 Akasha gate.
- Integration sweep uncovered two production issues: no-op flush invalidated a
  shared read root, and exact completion after HNSW exhaustion treated named-only
  points as missing default-vector sources. No-op publication now preserves the
  root; exhausted default scans skip absent default vectors (3/3 projection tests).
  Old companion-file and sparse-preserving-upsert assertions are being migrated
  while retaining snapshot/Arrow leases, compaction races and replay coverage.

- Mixed scalar payload audit expanded the native oracle from 69 to 109 cases:
  initially 81/109, now 109/109. Integer/string MatchExcept includes other present
  types, numeric ranges compare Int64/Float64 through Float64, and integer equality
  remains exact. Direct evaluation, sorted postings and metadata index agree;
  `test_qdrant_payload` passes its three upstream-derived regressions.
- The 35-file integration sweep and targeted fixes now have passing results for
  every file. Further fixes preserve no-op read roots while retrying failed derived
  caches, publish same-sequence HNSW downgrades before rotating both WALs and
  retiring old sidecars, and require recovery after uncertain point publication.
  Eight final affected test files pass in `integration-final/summary.json`, including
  two crash files and the actual M4 GPU snapshot suite.
- Latest rebuilt native Python/distributed/service validation: 387 passed, one
  skipped; C API also passes. Raw compact differential adds ten passing live/reopen
  F16 Dot/L2 and U8 Dot/L2/cosine cases (119 comparisons total). F16 cosine is a
  separately recorded mismatch, not a passing case: normalized-half versus raw-half
  authority changes the score by up to 0.0002112131 in this corpus.
- The full source/evidence audit is now in the linked ledger. It explicitly records
  learned SQ8/PQ algorithm gaps, necessary authoritative reranking, planner policy
  adaptations and the limits of distributed/GPU/API correspondence. No full
  alignment or performance completion is claimed.
- Completed the unchanged three-corpus warm matrix with three fresh serial trials:
  matched recall 36/36; speed parity 3/36, overall FAILED. Raw reports remain in
  `warm-matrix/`; [results](../benchmarks/2026-10-15-qdrant-alignment-warm.md) preserve
  all failed cells and distinguish this from the still-failing fixed L2 gate.
- PQ training now uses upstream first-row initialization, F64 sums/means,
  independently converging subvectors (`1e-5`) and empty-cluster reseeding.
  Training is capped at 10,000 source-ordered sampled rows; deterministic
  reservoir sampling and SplitMix64 replace upstream random permutation/RNG.
  Unedited Rust Lloyd methods versus production: 20/20 exact centroid fixtures
  (`qdrant-source-reference/pq-after/summary.json`), versus 8/20 before. Native
  IVF 3/3 and Python IVF 25/25 pass; the deadline regression now uses a genuinely
  large assignment pass because a large iteration cap cannot defeat convergence.
- SQ8 now follows upstream global scale/offset, codes 0..127, query quantization,
  cosine preprocessing and score correction. Raw Dot/L2 and normalized cosine
  have separate root-owned artifacts, preserving build-once/pinned ownership.
  Native quantized plain scan without rescore: 0/27 before, 27/27 after
  (`qdrant-source-reference/sq8-rounded/summary.json`). SQ8 integration 8/8 passes.
  Explicit F32 multiplication boundaries prevent FMA from changing corrected
  small scores. Quantizers are in-memory derived version 2; no durable codebook
  migration is needed. PQ scoring/cosine alignment is still outstanding.
- SQ8 constant/all-zero coverage expands the passing native score oracle to 45/45.
  PQ now trains normalized cosine separately, prepares query-centroid lookup tables
  once and sums encoded centroid scores without renormalizing trained centroids.
  Native PQ scoring with 512 points and captured native trained codebooks improved
  from 14/18 to 18/18. The common native runner is now
  `benchmarks/qdrant_quantized_reference.py --codec sq8|pq`; training remains
  independently checked against unedited Rust methods. The fixed L2 and full
  speed acceptance gaps remain unchanged.
- F16 cosine now derives Qdrant-style prepared halves from raw native values:
  F32 normalization, half rounding and F32 dot, with F64 MaxSim aggregation.
  The storage format is unchanged. Expanded native behavior oracle: 141/141
  (`qdrant-behavior/half-cosine-aligned/summary.json`), including tiny/zero/unit
  boundaries and live/reopen raw-value retention. Dense half fixtures use exact
  score equality. Independent Python IVF/MaxSim oracles pass 77/77; native
  field-metric tests pass 6/6. Original F32 ingestion and SIMD summation remain
  explicit comparison adapters, not claims of bitwise equality on every input.
- Removed the unused construction refill option; neighbor selection 15/15 and
  extracted construction 24/24 (2,467 adjacency rows) pass. Follow-up profiling
  identified per-expanded-node list allocation, unlike Qdrant's reusable buffers.
  In-place filtering and reused neighbor/score buffers preserve the 98/98 search
  oracle, scorer boundary tests and cancellation. Old/new/old saved-graph checks
  preserve all results/counters across twelve cells; QPS improves in this run,
  but two p95 cells regress. The linked buffer report explicitly keeps this
  diagnostic separate from fresh Qdrant acceptance.
- Final Python/distributed/service run after F16 and traversal-buffer changes:
  387 passed, one skipped; `pixi run test-c` passes. Native field metrics 6/6,
  IVF 3/3, field rerank, distance dispatch and reference scorer tests pass.
  The fixed L2 quality failure remains recorded; the CPU quality suite is not
  reported as wholly passing.
- Committed the alignment as `4e44f3c`. Continued profiling found that the new
  scorer had not reused the existing four-row F32 distance kernel. Integrated
  it after filtering/capping; extended scorer tests cover groups, tails, caps
  and reused buffers against single-row bits for owned/mapped storage. The
  extracted traversal now checks both scalar and batched F32 paths (98/98 each);
  construction remains 24/24 with 2,467 matching adjacency rows. Targeted Mojo
  checks and 387 Python/distributed/service tests pass (one skip). Two serial
  saved-graph orders preserve all results/counters, with high-dimensional ANN
  improvement and inconsistent 128D timings. Full acceptance and raw evidence
  are recorded in the [scoring report](../benchmarks/2026-10-16-qdrant-score-batch.md).
- The new three-corpus, three-trial fresh matrix completes with matched recall
  36/36 and speed 6/36, still FAILED. Thresholds and ef selection are unchanged;
  all filtered ANN cells still fail. The previous 3/36 matrix is a separate
  snapshot, not a paired measurement attributing all changes to this patch.
- Final rebuilt C client passes. The rerun fixed quality suite remains 3/4:
  Dot .9541666667 and cosine .9583333333 pass, L2 .9458333333 fails, and the
  subquadratic construction check passes. Complete raw timing/source/validation
  evidence is retained in the scoring report's compressed archive.
- Source admission now follows Qdrant's internal-slot deletion check with a
  shared live-base bitmap, maintained by source mutations. Segmented HNSW
  21/21, related lifecycle 47/47, Python/distributed 387 passed/one skipped and
  rebuilt C client pass. Both serial saved-graph orders preserve all results
  and counters; all filtered ANN cells improve QPS/p95 in both orders.
  Fresh acceptance remains FAILED: recall 36/36, speed 5/36, with no passing
  filtered ANN cell. The fixed L2 probe finds all nodes reachable but all 13
  missed neighbors unscored at ef=64. Thresholds and production ef are unchanged.
  See the [source bitmap report](../benchmarks/2026-10-16-qdrant-source-bitmap.md).
- Base-level metadata-read removal was tested and withdrawn because saved-graph
  gains were small/inconsistent; the [rejected probe](../benchmarks/2026-10-16-hnsw-base-level-probe.md)
  retains its matching oracles and all regressions (`6822da3`).
- Added a base-slot-to-metadata-ordinal projection, pinned to both the base-source
  lifetime and metadata lookup identity. Repeated queries share it; appends
  resolve only missing IDs; new lookup owners rebuild it. Original segmented
  21/21, new ownership/append/reorder/promotion tests 3/3, related Mojo 69/69,
  rebuilt Python/distributed 387 passed/one skipped and C client pass.
  Both saved-graph orders retain identical results/counters and improve every
  filtered ANN QPS cell, with one first-order filtered p95 regression.
- Latest fresh warm acceptance: recall 36/36, speed 4/36. Mixed acceptance:
  recall 36/36, speed 10/36, combined write+flush 5/9. All 5,184 query audits,
  18 reopen checks and nine Arrow leases pass. Fixed quality remains 3/4 with
  L2 .9458333333 below .95. First-filter timing tradeoffs and complete evidence
  are in the [base ordinal report](../benchmarks/2026-10-16-qdrant-base-ordinals.md).
  Full M5/M6 remains FAILED; thresholds and ef selection remain unchanged.
- Rejected a heap item-movement prototype after matching 52 Mojo cases and both
  98-fixture upstream search paths: uniform-128 all regressed in both saved-graph
  orders. Five native captures then localized current hot paths, with 335 matching
  pre/postflight query pairs. See the [heap/profile evidence](../benchmarks/2026-10-16-hnsw-heap-profile.md).
- Mapped current flags now reuse the existing inline bounded scalar load. The
  52 related Mojo tests pass; saved-graph results/counters remain identical.
  Three longer confirmation pairs improve uniform-128 all QPS 5.4–6.6%; all
  nine ANN median QPS/p95 ratios improve, while initial regressions and unchanged
  exact-control tails remain recorded. Latest fresh warm recall is 36/36 and
  speed 4/36; mixed recall 36/36, speed 13/36 and write+flush 5/9. All 5,184 query
  audits, 18 reopen checks and nine Arrow leases pass. Full M5/M6 remains FAILED;
  fixed L2 and platform/capacity/concurrency gaps are not waived. The
  [current-flag report](../benchmarks/2026-10-16-qdrant-current-flag.md) separates
  paired local gains from the fresh acceptance snapshots.
- Bounded upper-layer query seed reuse closes the fixed L2 quality gate:
  228/240 = .95 at unchanged ef=64, versus 227/240 before. Dot .9541666667,
  cosine .9583333333 and construction growth 3.4405554 pass. Integer hit-total
  aggregation corrects the old floating accumulation error at exactly .95.
  Construction remains single-entry; queries use the best at-most-ef already
  scored final-upper candidates in one frontier, informed by Faiss's shared
  frontier design. The source oracle explicitly excludes this query adaptation.
  A 1152-query integration probe matches the standalone candidate's results and
  counts, including its retained one-hit regression. Sorted seed transfer was
  simplified to an unordered drain with identical results and distance work.
  Paired public timings remain mixed, so speed/platform/capacity/concurrency
  requirements stay open. See the [upper-seed report](../benchmarks/2026-10-16-hnsw-upper-seeds.md).
  Complete local CPU validation passes 152 Mojo files / 1036 cases, 387 Python/
  distributed/service tests (one skip), rebuilt C client, three examples and
  both quality smoke tasks. The full suite exposed and corrected two obsolete
  zero-cosine/sparse test contracts; legacy rejection rules remain tested.

- Checked-ID reuse in `score_points` was tested and rejected: fewer ID loads
  preserve results/counters but regress real independent-filter timing in two
  of three pairs. All evidence is retained in the
  [probe report](../benchmarks/2026-10-16-hnsw-id-reuse.md). Production restored
  to `3dafe2a`; the next isolated hypothesis uses the existing paired exact
  kernel in authoritative reranking, without skipping candidates or checks.

- Paired authoritative reranking is retained after 70 targeted Mojo cases,
  387 Python/distributed passes (one skip), C/examples and quality smokes.
  Saved-graph high-dimensional ANN median QPS improves 7.3–12.6%; all 18
  high-dimensional mixed QPS/p95 pairs improve with identical IDs and work.
  Low-dimensional mixed independent p95 regression remains explicitly open.
  New native acceptance is warm quality 36/36, speed 7/36; mixed matched
  quality 33/36, speed 14/36, write+flush 5/9. Akasha passes all mixed recall
  cells; three Qdrant real correlated cells fall below .95 and receive no
  speed comparison. See the [complete evidence](../benchmarks/2026-10-16-hnsw-paired-rerank.md).
  No full M5/M6 completion, native Linux or concurrent/nonresident gate is claimed.

- Three bounded heap prototypes are rejected after assembly, 82 related Mojo
  cases, both 98-fixture search paths and paired saved/mixed timings. The final
  movement prototype improves all nine saved-graph ANN medians but retains
  mixed low-dimensional regressions. Production and the Python binary are
  restored to `3de6e1c`; three independent heap model/error tests are retained.
  Five refreshed native captures preserve 335 pre/post query pairs and identify
  bitmap lookup as a concrete next low-dimensional hot path. The
  [complete probe evidence](../benchmarks/2026-10-16-hnsw-bounded-heap.md)
  retains every variant and regression. Accepted gates remain warm speed 7/36,
  mixed speed 14/36 and write+flush 5/9; no new gate or platform claim is made.

- Bitmap membership now retains logical index errors while reading a word whose
  bound follows from the owned bitmap shape. Overflow-safe word counting fixes
  a reproduced Int.MAX boundary failure. All 18 filtered ANN QPS pairs improve
  in both saved-graph and mixed diagnostics; low-dimensional saved medians gain
  5.4–5.7%, with exact-query and p95 regressions explicitly retained.
  Validation passes 149 related Mojo cases, search 98/98 on both scoring paths,
  construction 24/24, 387 Python/distributed cases (one skip), C/examples and
  fixed/smoke quality gates. Latest fresh native acceptance is warm quality
  36/36, speed 6/36; mixed matched quality 36/36, speed 15/36; write+flush 3/9.
  Full M5/M6 and remaining platform/capacity/concurrency requirements stay open.
  See the [bitmap evidence](../benchmarks/2026-10-16-bitmap-bounded-read.md).
