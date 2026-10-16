# Qdrant alignment: implementation and validation evidence

Reference: `reference/qdrant-edge-0.8.0`, commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`; native `qdrant-edge-py==0.8.0`.
Akasha worktree: `feat/qdrant-alignment`, based on `f6a938a`, Mojo
`1.0.0 (ed45d567)`. This is an audit of existing Akasha capabilities, not a
claim of complete Qdrant API, storage-format, cluster, quality or speed parity.
The earlier [source baseline](2026-10-14-qdrant-source-baseline.md) describes
the pre-integration implementation; this document records the subsequent work.

All upstream paths below are relative to that pinned checkout. Checks are
cumulative: later focused runs supersede the failures they fixed, while earlier
unaffected passing results remain applicable. Local `.build` artifacts retain
the failed runs as well as the successful ones.

## Search and construction

| Capability | Upstream implementation inspected | Akasha change and executable evidence | Disposition |
| --- | --- | --- | --- |
| Dot/L2/cosine and top-k | `lib/segment/src/spaces/simple.rs`; `lib/segment/src/spaces/metric_{f16,uint}/`; raw scorers | Shared native examples and zero cosine cases in `benchmarks/qdrant_behavior_alignment.py`; scalar/SIMD/paired tests | Shared mathematical behavior; squared L2, F64 typed-field accumulation and stable ID ties remain explicit Akasha contracts. Comparison canonicalizes units/ties and records its tolerance. |
| Raw F16/U8 fields | `metric_f16/simple_{dot,euclid,cosine}.rs`; `metric_uint/simple_cosine.rs`; `vector_storage/query_scorer/metric_query_scorer.rs` | All twelve compact live/reopen cases pass; twenty additional F16 cosine dense/MaxSim boundary comparisons pass | F16 cosine now uses F32 normalization, half rounding and F32 dot. Dense scalar fixtures match exactly; MaxSim permits F32/F64 aggregation differences. Raw half authority is retained, so the oracle feeds the same canonical half inputs to Qdrant. Qdrant otherwise normalizes original F32 ingestion values before storing half. |
| BF16, signed I8, binary Hamming/Jaccard | Qdrant storage datatype enum supports F32/F16/U8; learned binary quantization is a different representation | `test_field_metrics`, `test_named_vectors`, `test_quantization`, compact HNSW and frozen sidecar tests | No directly corresponding raw-field contract. Preserve native values, bounds and independent metric oracles; do not equate signed I8 storage with Qdrant scalar quantization. |
| Learned SQ8/PQ | `lib/quantization/src/encoded_vectors_u8.rs`, `encoded_vectors_pq.rs`, `kmeans.rs`; segment `quantized_vectors.rs` | PQ centroids: 8/20 before, 20/20 exact after. SQ8 native scores: 0/27 before, 45/45 after including constant vectors. PQ native trained-codebook scoring: 14/18 before, 18/18 after normalized cosine and centroid lookup tables. Snapshot SQ8/PQ and IVF tests pass | SQ8 padding is computed without storing padding bytes. PQ uses deterministic reservoir/reseeding, explicit centroid/iteration parameters, and separate normalized/raw artifact registries. Native PQ scoring uses captured native codebooks to isolate its unseeded training; the separate Rust oracle covers training. |
| HNSW construction | `index/hnsw_index/{graph_layers_builder,links_container}.rs`; `hnsw/build.rs` | Independent directed backlink pruning, no refill, rounded level sampler, payload level-zero edges. Extracted Rust build comparison: 24/24 fixtures and 2,467 ordered adjacency rows (`.build/qdrant-source-reference/build-2/summary.json`) | Algorithm port verified on fixed serial L2 fixtures. Random stream/ties and payload thresholds are explicit adaptations, not identical upstream defaults. |
| Entries, traversal and connectivity | `entry_points.rs`, `graph_layers.rs`, `point_scorer.rs`, `hnsw/build.rs` | Owned traversal oracle: 98/98 on scalar and batched F32 paths, including distance counts (`four-score-batch-2/summary.json`); mapped scoring separately checked against single-row bits and saved-graph results. Probabilistic connectivity 128/128 including RNG consumption (`connectivity-2/summary.json`) | Eligible primary/extra entries, filter-before-score and bounded frontier integrated with payload connectivity. Stable ties and extra-entry capacity remain Akasha policy. |
| Scalar payload filtering | `payload_storage/condition_checker.rs`; payload field indexes | New `test_qdrant_payload`: direct/indexed numeric coercion, exact Int64 equality, MatchExcept and missing fields; native live/reopen mixed payload cases | Integer/string MatchExcept includes other present scalar types. Numeric ranges use F64 across integer/float storage, including rounding beyond 2^53. Missing fields fail predicates; outer negation includes them. Boolean match uses extracted Rust because Edge 0.8.0 binds bool as int. |
| Exact/ANN planner | `hnsw/read_view/{dispatch,sample_estimation}.rs` | Removed 2*k and dimension/ef scan-cost rules. Planner 10/10; named HNSW 4/4, including failure injection proving exact queries do not build unused graphs | Cardinality dispatch aligned. Akasha N/8 threshold and 64-vector readiness floor differ from Qdrant's configured byte threshold; exact cardinality uses deterministic equality, not sampled estimation. |
| Base/delta authority and rerank | Segment deleted/current vectors, proxy segments; `index/vector_index_search_common.rs` | `test_segmented_hnsw`, `test_point_hnsw_projection`, `test_hnsw_overlay_cache`, field rerank and lifecycle tests | Current-source eligibility precedes scoring. Reranking remains necessary: tests deliberately make graph rows stale while authoritative rows change, and typed fields promise F64 scores. Qdrant's unquantized no-rescore path cannot be copied without changing that invariant. |
| Named dense / MaxSim | `vector_storage/query_scorer` multi-dense scorers and named storage | Native Dot/L2/cosine/zero examples, presence and reopen tests | Shared nonempty MaxSim aggregation verified. Empty stored matrices remain present but unscorable; field shapes/scalars retain Akasha validation. |
| Sparse | `lib/sparse/src/index/search_context.rs` | F32 term-order accumulation, nonzero eligibility, empty/zero/overflow/cancellation examples; posting and snapshot paths; distributed empty hybrid regression | Native differential uses Qdrant sparse index with `full_scan_threshold=0`. Qdrant's filtered plain scan can retain cancellation-zero results; this mode difference is not claimed equivalent. |
| RRF and final rerank | `lib/segment/src/common/reciprocal_rank_fusion.rs`; query fusion processing | Default 2, zero-based ranks and exact F32 arithmetic; native constants 1/2/17/16777216; field rerank tests | Shared fusion verified. Preserve explicit Akasha stable ties and final metric score units. |
| IVF | No corresponding Qdrant index exposed | `test_field_ivf` and Python field IVF tests: probe limits, filters, ownership, reopen and cache reuse | Preserve independently verified Akasha index; no Qdrant parity claim. |

The behavior runner currently reports **141/141 passing comparisons**,
`.build/qdrant-behavior/half-cosine-aligned/summary.json`. F16 cosine previously
failed two cases (maximum delta `0.00021121312367700096`); the expanded corpus
also checks zero/tiny/unit normalization boundaries, MaxSim, raw-value retention
and reopen. Python independent IVF/MaxSim score oracles pass 77/77. It records
native binary/source hashes, adapters and the Edge boolean-binding limitation.
It is a finite regression corpus, not proof that every numerical input agrees.

## Durability, concurrency and public boundaries

Qdrant's `lib/shard/src/segment_holder/flush.rs` captures flushers while holding
consistent segment locks and limits WAL acknowledgement to completed flushes
and pending cleanup dependencies. `lib/collection/src/update_workers/flush_workers.rs`
flushes WAL before acknowledging confirmed segment versions, capped by failures
and `keep_from`. `lib/common/common/src/save_on_disk.rs` publishes atomic files.
These are ordering/ownership references, not a requirement to copy Qdrant's
file formats or asynchronous acknowledgement modes.

Akasha validates and encodes a complete point mutation before append/fsync,
publishes in-memory state afterward, and poisons a handle on uncertain I/O.
Checkpoint data and manifest publication precede both WAL rotations and old-file
retirement. Recovery validates source files before migration/repair. Existing
read leases prevent deleting files still reachable from a captured generation.

| Capability | Upstream reference | Change / evidence | Disposition |
| --- | --- | --- | --- |
| Atomic mutation | `lib/shard/src/update/points/upsert.rs`, `update/vectors.rs`, segment updater | One PointStore authority for default/named/dense/sparse/payload; whole-point upsert removes omitted values, partial updates preserve them. WAL v5 records replacement; historical v4 replay preserves merge semantics. Native update/upsert/reopen comparisons pass | Shared operation behavior aligned. Akasha batch durability/error contracts remain explicit. |
| WAL/checkpoint/recovery | Flush sources above, Edge shard open/flush | Frozen old-writer fixtures (17 cases), mixed v1-v5 WAL, torn/corrupt data and point segment v4/v5 tests; all eight crash files have passing results across `unified-recovery-final`, `unified-crash-fixes` and `integration-final` | Akasha formats retained with versioned migrations. Point segment v5 permits zero sparse weights while frozen v4 validation remains strict. |
| Mapped HNSW/readiness | Graph links mmap and builder publication | Sidecar v3 stores directed/supplementary adjacency and entry levels. Frozen v1/v2 readers; same-sequence downgrade, failed publication, retained WAL and pin retirement regressions pass | Derived format is Akasha-specific; failure cannot publish a partially ready graph. |
| Concurrent reads / optimization | Segment holder lock/flush discipline, segment builder and proxy segments | Background publication 20/20; concurrency, compaction rebase/reclaim and lease tests. No-op flush preserves its read root; failed derived-cache publication retries on a later flush | Captured immutable roots and background compaction retain Akasha snapshot isolation. No claim of identical locking implementation. |
| Snapshot/backup/logical restore | `lib/edge/src/edge_shard/snapshots.rs`, `lib/edge/python/src/snapshots.rs` | Snapshot/backup compaction/Arrow lease tests and backup publication crash test; logical import/export Python tests | Restore atomically validated authoritative state; physical and logical formats remain Akasha-specific. |
| Python/C/Arrow/HTTP | Edge Python boundary, service handlers | Latest Python/distributed suite: 387 passed, 1 skipped. Latest `pixi run test-c`: pass. Arrow empty sparse rows, typed ownership, schema/offset validation, service behavior covered | Existing APIs verified; no Qdrant HTTP/gRPC compatibility layer added. |
| Replication/failover | `lib/collection/src/shards/replica_set/execute_read_operation.rs` and transfer/snapshot paths | Replica applies dense+payload+sparse in one point batch. Journal publication fsyncs file then parent; uncertain append blocks retries until recovery. Four new durability tests; protocol/multiprocess suite 28/28, then full suite above | Existing quorum/placement/term protocol retained. Qdrant has configurable read consistency and its own consensus/transfer design; this is not Raft or wire-protocol equivalence. |
| Query budgets/cancellation/metrics | `graph_layers.rs` stop checks and query-context hardware counters | Owned/mapped descent and beam loops check cancellation; scratch reuse after cancellation, field query controls and public query-control tests pass | Akasha public counter units/resource ceilings remain its contract; no counter-value parity claim. |
| GPU | Qdrant GPU graph/scorer infrastructure | Actual M4 GPU zero-cosine kernels and snapshot suite pass; latest `tests/gpu/test_gpu_snapshot.mojo` passes after unified authority | Akasha GPU exact search is independently checked against CPU semantics. Qdrant GPU graph construction is not the same API; no GPU performance parity claimed. |

The final integration rerun is
`.build/qdrant-alignment/integration-final/summary.json`: metadata field indexes,
HNSW checkpoint cleanup/overlay retry/sidecar publication, snapshot, two HNSW
crash files and actual-device GPU snapshot all pass. Earlier integration failures
are retained in their original logs and superseded by the targeted successful runs.

The traversal also now reuses its neighbor and scoring buffers and filters IDs
in place, following upstream `FilteredScorer`. The 98-case differential remains
exact, including distance counts; cancellation and scorer-buffer reuse pass.
The obsolete refill option was removed (15/15 neighbor-selection tests).
An old/new/old saved-graph diagnostic preserves all result digests and counters
across twelve cells; measured QPS ratios are 1.026–1.252, with two p95 regressions.
See the [buffer reuse report](../benchmarks/2026-10-16-qdrant-search-buffers.md)
for scope, raw artifacts and limitations. It is not a new Qdrant acceptance run.

The subsequent [four-row scorer integration](../benchmarks/2026-10-16-qdrant-score-batch.md)
reuses the existing F32 batch kernel after filtering/capping. Both old/new/old
and reversed saved-graph runs preserve all results and counters. High-dimensional
ANN timings improve in both orders; low-dimensional timings remain inconsistent.
The report distinguishes these diagnostics from fresh Qdrant acceptance.

## Remaining acceptance and implementation work

- Learned PQ training and scoring have separate executable references.
  `benchmarks/qdrant_pq_reference.py` compiles unedited upstream Lloyd methods
  with serial execution and deterministic RNG adapters; 20/20 fixtures match
  exact centroid bits (`.build/qdrant-source-reference/pq-after/summary.json`).
  The 10,000-row sampling cap uses a deterministic uniform reservoir rather than
  Qdrant's permutation; source order is restored before training.
- `benchmarks/qdrant_quantized_reference.py` forces native quantized plain scan with
  rescore disabled and proves materialized quantization plus a difference from
  exact scores. All 45 SQ8 query fixtures pass, including all-zero/constant
  populations (`sq8-constant/summary.json`). With `--codec pq`, 18/18 trained-PQ
  query fixtures pass (`pq-scores-trained-after/summary.json`); codebook/codes
  are mapped to logical IDs by exact retrieved-vector bytes. The earlier
  18/18 case with one centroid per point did not exercise lossy centroid norms;
  the expanded 512-point case exposed and fixed that difference (14/18 before).
  Raw and normalized cosine SQ8 artifacts are built independently per read root.
  The former per-coordinate 0..255 encoder and its unused rounding helper were
  removed. Offset multiplication must round before adding the shift; allowing
  FMA contraction changed cancellation-sensitive scores and failed the oracle.
- F16 cosine uses Qdrant's metric on canonical half inputs without changing
  stored raw values. Hardware SIMD summation order and original F32 ingestion
  rounding remain explicit limits on a bitwise score-parity claim.
- The fixed Akasha L2 quality gate now passes **228/240 = 0.95** through
  bounded reuse of already scored upper-layer query candidates. Dot, cosine
  and construction growth also pass. Dataset, seeds, ef=64, threshold and
  construction remain unchanged; recall aggregation now divides integer totals
  once rather than accumulating per-query Float64 rounding. The earlier
  227/240 Akasha/native-Qdrant diagnoses remain historical evidence.
  This is an explicit post-alignment query optimization informed by Faiss's
  shared-frontier pattern; the Qdrant differential now clearly covers the
  retained single-entry production primitives, not the multi-entry query path.
  See the [quality repair and timing diagnostics](../benchmarks/2026-10-16-hnsw-upper-seeds.md).
  The larger 1152-query probe includes a one-hit L2 regression and a seed below
  .95 in both implementations. Saved-graph timings do not establish a consistent
  speed improvement; all regressions and unchanged exact controls are retained.
- Earlier warm three-corpus, three-trial acceptance after bounded mapped
  current-flag loading (before upper candidate reuse and paired reranking): matched recall 36/36, speed **4/36**, overall **FAILED**.
  The existing symmetric ef grid and all thresholds were retained; see the
  [measurement report](../benchmarks/2026-10-16-qdrant-current-flag.md).
  Earlier matrices, including base-ordinal warm 4/36 and mixed 10/36, remain
  historical snapshots, not paired baselines.
  Fresh serial mixed acceptance passes recall 36/36, speed 13/36 and combined
  write+flush 5/9. All 5,184 query audits, 18 reopen checks and nine retained
  Arrow leases pass. Filtered ANN speed parity remains failed in both phases.
  Full M5/M6 requirements still include lifecycle,
  concurrent/non-resident/type matrices and actual supported-platform evidence.
  Source parity and macOS tests cannot substitute for those measurements.
- The [heap move probe and native profile](../benchmarks/2026-10-16-hnsw-heap-profile.md)
  retain a rejected optimization (52 Mojo tests and both 98-fixture search paths
  pass, but public timings regress) and five unchanged-parent native captures.
  Checked authority scoring accounts for 26–29% of real filtered main-thread
  top-of-stack observations; this is not permission to remove required reranking.

- The [checked-ID scorer reuse probe](../benchmarks/2026-10-16-hnsw-id-reuse.md)
  is rejected. It removes one ID read per scored point, passes 55 Mojo cases
  and the 98-fixture source oracle, but real independent-filter QPS falls
  about 3.5% and p95 rises about 10.2% in two of three saved-graph pairs.
  Source and binary were restored to `3dafe2a`; no speed gate closes.

- [Paired authoritative reranking](../benchmarks/2026-10-16-hnsw-paired-rerank.md)
  reuses the existing checked two-row exact kernel. All 36 saved-graph paired
  cells preserve digests, recall and statistics; high-dimensional ANN median
  QPS improves 7.3–12.6%. A separate mixed before/after matrix preserves 5,184
  query responses, 18 reopen checks and 18 leases; all 18 high-dimensional ANN
  QPS/p95 pairs improve. Low-dimensional mixed independent p95 regresses in
  all three pairs (median +3.1%), so no universal speed claim is made.
  Validation: 70 targeted Mojo cases, 387 Python/distributed passes (one skip),
  rebuilt C client/examples and both quality smokes. Latest fresh native warm
  acceptance: recall 36/36, strict speed **7/36**. Mixed: Akasha recall 36/36,
  matched quality **33/36**, strict speed **14/36**, write+flush **5/9**.
  Qdrant real correlated recall is .9458333333 under the frozen warm ef in
  three mixed cells; those receive no speed comparison or post-hoc retuning.
  All fresh query audits, reopen checks and leases pass. Overall M5/M6 stays
  FAILED; low-dimensional/filtered speed, Linux, concurrent, nonresident and
  type/capacity requirements remain open.
