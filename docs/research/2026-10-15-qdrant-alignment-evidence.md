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
  rebuilt C client/examples and both quality smokes. That revision’s fresh native
  warm acceptance: recall 36/36, strict speed **7/36**. Mixed: Akasha recall 36/36,
  matched quality **33/36**, strict speed **14/36**, write+flush **5/9**.
  Qdrant real correlated recall is .9458333333 under the frozen warm ef in
  three mixed cells; those receive no speed comparison or post-hoc retuning.
  All fresh query audits, reopen checks and leases pass. Overall M5/M6 stays
  FAILED; low-dimensional/filtered speed, Linux, concurrent, nonresident and
  type/capacity requirements remain open.

- [Bounded bitmap reads](../benchmarks/2026-10-16-bitmap-bounded-read.md) established
  the preceding accepted production checkpoint (`63794d6`): fresh warm quality 36/36,
  speed 6/36; mixed quality 36/36, speed 15/36, write+flush 3/9.
  The [refreshed concurrent matrix](../benchmarks/2026-10-16-concurrent-current.md)
  passes quality 72/72, but common-HTTP speed only 6/36 (one client) and 12/36
  (four clients). No source optimization or native platform gate can be inferred
  from a changed pass count across separately built graph snapshots.

- [Two source lookup probes](../benchmarks/2026-10-16-hnsw-source-probes.md)
  are rejected after correct oracle results but repeatable mixed timing
  regressions. One dictionary probe and smaller generated code are not enough
  to establish an end-to-end gain. Forced outlining is a distinct optimizer
  experiment, not proof of the cause of the first variant’s regression.
  Production remains the bitmap checkpoint; source and Python binary identities
  match it, with a fresh rebuilt C-client check after restoration.

- [Current sampling and neighbor-tail pairing](../benchmarks/2026-10-16-neighbor-tail-pair.md)
  preserve 335 profile query pairs and reject another measured prototype:
  64 Mojo cases and both source-search paths pass, but roughly 3–5% filtered
  high-dimensional gains retain low-dimensional and individual p95 regressions.
  All 36 warm pairs and 5,184 mixed responses preserve results/statistics;
  18 reopen and 18 lease checks pass. Source/test/Python restore to the bitmap
  checkpoint. No speed, concurrency or platform requirement is newly satisfied.

- [Native Qdrant work counts](../benchmarks/2026-10-16-qdrant-native-work.md)
  use an isolated, instrumented pinned source build; the reference checkout and
  official speed-comparison wheel remain unchanged. 1,608 unique requests match
  wheel IDs/F32 bits in two repeats; all 804 exact count controls pass. Another
  134 same-ef comparisons also match. At matched ef, real correlated work is
  1.860x Qdrant; same-ef controls isolate extra authoritative scoring and the
  605/640 recall miss at ef=128. This supplies previously unavailable native
  operation counts, not a performance acceptance pass. Explicit default exact
  Akasha calls leave approximate-query statistics unchanged and are excluded
  from cross-engine work accounting.

- [Delta admission before preliminary scoring](../benchmarks/2026-10-16-delta-admission-first.md)
  is an accepted search optimization. All-fit scans retain every candidate
  without graph scores; overflow retains the original heap, and authority
  scoring still validates every admitted row. Two prototypes preserve all
  paired IDs/F32 bits, with expected work reductions. Retained B improves real
  correlated QPS about 11% in saved and mixed diagnostics, with low-dimensional
  mixed p95 regressions explicitly unresolved. Fresh warm quality 36/36,
  strict speed 6/36; mixed Akasha quality 36/36, matched quality 33/36, strict
  speed 12/36 and write+flush 3/9. The three unmatched cells are Qdrant real
  correlated recall failures under frozen ef, not waived gates. All 5,184 fresh
  audits, 18 reopens and nine leases pass. Related Mojo/source fixtures and
  387 unique Python/distributed cases pass; initial stale count assertions and
  their targeted reruns are retained. Native Linux, current concurrent load,
  sustained nonresident and full type/capacity/lifecycle acceptance remain open.

- [Mapped point checkpoint recovery](../benchmarks/2026-10-16-point-checkpoint-map.md)
  removes the file-sized encoded buffer from the unified v4/v5 recovery path,
  while preserving owned decoded values and all durable validation. Native
  macOS paired high-dimensional peak footprint falls about 49% (262 to 134 MiB).
  Fifty-five relevant Mojo/crash cases, 387 Python/distributed cases (one skip)
  and C pass. All 5,184 paired mixed responses preserve IDs/F32 bits/statistics;
  18 reopens and 18 leases pass. Mixed tail regressions are retained, and the
  prior formal Qdrant matrix is not relabeled as current acceptance. Remaining
  capacity/nonresident requirements need actual controlled-pressure evidence;
  an emulated Linux follow-up does not substitute for native Linux performance.

- The [corrected capacity follow-up](../benchmarks/2026-10-16-point-map-capacity.md)
  completes 60 emulated Linux workers after preparing fresh/cold Linux-volume
  fixtures outside their caps. All six controls complete; constrained completion
  improves 15/27 to 21/27. Both high-dimensional 192 MiB cases change from 0/3
  to 3/3, while 128 MiB remains 0/3 in both versions. All 84 completed response
  checks match ID/F32 bits. Eighteen Docker-confirmed OOMs remain at the open
  operation. Earlier in-worker preparation failures are preserved separately.
  Zero queries test readable state, not recall or sustained pressure; no Qdrant
  speed or native Linux acceptance is inferred.

- [Streaming compaction](../benchmarks/2026-10-16-point-merge.md) removes the
  second decoded checkpoint table and complete output tape. Both 1536-D corpora
  now complete the 32-block pressure workload at 192/256 MiB in three trials
  each. [F32 tape helpers](../benchmarks/2026-10-16-point-codec-tapes.md) then
  reduce its high-dimensional flush totals by 35–48%, preserving capacity,
  typed bytes and recovery. Relative to the pre-stream baseline, uniform flush
  remains 1.4% slower; mixed query tails regress against the preceding commit,
  including real selective p95 at 1.590x. Both 128 MiB workers still OOM and
  recover all 16 acknowledged rows. The current change passes 94 relevant Mojo,
  388 Python/distributed and C cases, plus 27 Linux-emulated Mojo cases; all
  10,368 native and 5,184 Linux response audits agree. This does not refresh or
  waive formal Qdrant speed, full type/lifecycle, concurrency or native Linux
  requirements.

- [Query controls and native thread intervals](../benchmarks/2026-10-16-codec-query-control.md)
  preserve 25,920 audited responses, 90 exact reopens and 90 Arrow leases. Fixed
  initial-state queries do not reproduce the original real selective 1.590x
  p95 regression; the median ratio is 0.979x. The evolving-state drain control
  removes query/maintenance overlap but changes scheduling, so its near-one
  ratios are diagnostic only. In native interleaved traces, 56 of 57 selective
  requests above 150 microseconds with CPU below 80% overlap a background
  writer-lock section: 41 capture, 15 publication. One waiting request remains
  unexplained. Faster codec jobs increase maintenance frequency in these traces.
  Clock alignment is checked before/after each retained worker; the first
  incompatible-clock run and three build failures are excluded and preserved.
  Production code and formal acceptance are unchanged. The next implementation
  boundary is reducing capture/publication critical work without dropping
  generation validation, file leases or durable publication guarantees.

- [Capture subphase measurements](../benchmarks/2026-10-16-compaction-capture.md)
  show generation/file pinning at 68–83 microseconds median. A tested candidate
  reusing the validated manifest shortens capture locks 8–12%, but regresses
  uniform selective mixed p95 to 2.299x/1.672x and throughput to 0.918x/0.944x.
  It is rejected and production restored. Candidate validation passes 76 native
  Mojo/recovery cases, 388 Python/distributed cases, C, 17 Linux-emulated cases,
  12,960 response audits, 45 reopens and 45 Arrow leases; none is presented as
  new performance acceptance. Next examine a source-owned capture/lease protocol
  outside the writer lock with explicit generation-race retries and corruption
  failures. All remaining formal gates stay open.

- [Unlocked compaction capture](../benchmarks/2026-10-16-unlocked-capture.md)
  moves manifest/catalog/file-lease I/O outside writer and pin-registry locks.
  Post-lease manifest-prefix validation accepts appended tails and rejects
  replaced inputs; strict generation equality was tested and rejected because
  it exhausted the existing budget during harmless concurrent flushes. Eight
  new tests plus existing persistence/concurrency checks pass: 81 native Mojo/
  recovery cases, 388 Python/distributed cases, C and 48 Linux-emulated cases.
  Six uninstrumented pairs per corpus reduce selective p95 to 0.479x/0.858x/
  0.616x and improve QPS to 1.097x/1.076x/1.074x. All 15,552 response audits,
  54 exact reopens and 54 leases agree. Uniform-128 independent p95 remains
  1.065x, with variable trial results; this regression and the publication
  critical section remain follow-up work. The change is retained as a partial
  improvement, without closing or relaxing any remaining formal acceptance gate.

- [Publication profiling and pre-delete durability fencing](../benchmarks/2026-10-16-unlocked-pin-release.md)
  locate 14–20% of successful publication lock time in job-pin release and
  66–72% in durable publication. Moving release past publication was tested
  and rejected: uniform-128 selective QPS falls to 0.925x and p95 rises to
  1.173x; real selective QPS falls in all six pairs. Only the separate
  correctness fix is retained: lease/orphan cleanup syncs observed manifest
  authority before deleting its first obsolete file. Real fsync injection
  reproduces premature deletion on the baseline and verifies preservation,
  retry and reopen with the fix. Retained source passes 53 native Mojo/recovery
  cases, 388 Python/distributed cases, C and 30 Linux-emulated cases. Across
  profile, rejected and retained comparisons, all 33,696 response audits,
  117 exact reopens and 117 Arrow leases agree. The retained fence is not a
  claimed speedup: low-dimensional selective QPS is 0.947x, correlated p95
  1.072x, and uniform-1536 independent p95 1.047x. Full formal speed, capacity,
  type/lifecycle, concurrency and native Linux requirements stay open. Next
  investigate durable publication frequency and size-based merge selection,
  preserving tombstones and coverage rather than copying Qdrant's size sort
  into the current full-base merge.

- [Size-based partial point compaction](../benchmarks/2026-10-19-partial-compaction.md)
  addresses measured full-base rewrite amplification using Qdrant size selection
  and RocksDB contiguous-run principles. Automatic merges retain tombstones in
  existing point v5 deltas; explicit compaction/scheduling still force a full
  base. A three-input policy reduces bytes but increases jobs to 15 and regresses
  low-dimensional selective p95 to 1.467x, so it is rejected. The retained minimum
  of four reduces jobs to ten and logical output bytes 87–90% versus the baseline.
  Selective p95 ratios are 0.938/0.884/0.899 across the three corpora, with all
  throughput medians improved. Uniform-128 all/independent p95 remain regressions
  at 1.072x/1.063x; final disk use grows 5–6% and reopen time 1–2%. Protocol checks
  pass 141 native Mojo/recovery, 388 Python/distributed, C and 61 Linux-emulated
  cases; the final batch policy repeats 32 affected native/Linux cases plus
  Python and C. All 28,512 response audits, 99 reopens and 99 Arrow leases agree.
  No formal speed, 128 MiB capacity, full type/lifecycle, concurrency or native
  Linux gate is closed. The remaining low-dimensional tails and retained base
  lifetime must be included in subsequent formal mixed/lifecycle verification.

- [HNSW owned decoder memory](../benchmarks/2026-10-19-hnsw-decode-memory.md)
  removes the complete promoted F32 intermediate tape and reserves final graph
  storage before restoring rows. The 64 MiB snapshot regression fails on baseline
  and passes after the change: additional peak RSS falls from 117.1 to 64.5 MiB
  on macOS and 130.0 to 64.0 MiB in Linux emulation. Forty native Mojo cases pass;
  Linux reproduces and fixes the same memory assertion. All 3,456 completed-worker
  response audits and 12 reopens agree; all 40 acknowledged rows from four OOM
  volumes recover with original F32 bits, payloads and exact oracles. Both high-D
  128 MiB cells remain failures: uniform reaches block 2 flush, real still block 0.
  Phase attribution places the largest open-time increase in point recovery;
  point values remain owned. No formal speed, capacity, type/lifecycle,
  concurrency or native Linux gate is closed.

- [Mapped cache decoding and rejected metadata writers](../benchmarks/2026-10-19-mapped-cache-stream.md)
  removes full encoded input copies from metadata and HNSW-overlay recovery.
  High-dimensional unconstrained open anonymous memory falls about 8 MiB.
  The retained 128 MiB trials pass uniform-1536 3/3 but real-1536 only 2/3;
  its block-8 OOM recovers all 72 acknowledged rows exactly. All 4,320 retained
  cgroup responses, 15 reopens, 10,368 native paired responses, 36 native reopens
  and 36 Arrow leases agree. Validation passes 71 native Mojo cases, 16 Linux-
  emulated cases and 388 Python/distributed cases; one optional Qdrant-adapter
  test remains skipped because its pinned wheel is absent. Native flush ratios
  are 1.001/0.989/0.996x, but query regressions remain, including real all p95
  1.155x and uniform-128 independent p95 1.056x. Two streamed metadata writers
  save large-payload memory but regress flush time; both are rejected and
  archived. Their additional OOM trials recover all 512 acknowledged rows.
  Point-value ownership remains the largest measured open-time increase, and
  metadata output still materializes its payload. No full speed, capacity,
  type/lifecycle, concurrency or native Linux gate is closed; the last formal
  Qdrant checkpoint remains `45e04d2`.

- [Immutable point-owner prototype](2026-10-20-immutable-point-owner.md) records
  the Qdrant borrowed-row source references and Akasha's immutable lifetime
  adaptation. Linux-emulated high-dimensional after-open anonymous memory falls
  about 50 MiB; three controls and 9/9 short 128 MiB trials pass, with 3,456
  matching responses and 12 reopens. Two native candidate comparisons retain
  10,368 matching responses, 36 reopens and 36 Arrow leases, but selective QPS
  still regresses. The cached-range ratios are 0.860/0.883/0.915x baseline.
  The 67 archived Mojo cases and six negative compile cases establish only
  their stated scope. Full live rebasing, type/export/GPU and destruction paths
  remain incomplete; production source stays `a6822c3`. No formal gate is closed.

- [Immutable row traversal and fresh native mixed comparison](2026-10-20-immutable-point-query.md)
  restores the exact pinned Qdrant wheel; its previously skipped adapter case now
  passes. In the 36-worker fixed-state mixed comparison, production/prior/new
  candidate quality-plus-speed passes are 16/17/18 of 36, matched quality 33/36,
  and combined write-plus-flush 9/9 for each variant. The new descriptor's selective
  QPS improves 6–9% over the prior prototype but still has production regressions,
  including one pass-to-fail. The report retains all 10,368 audited responses,
  36 reopens, 27 Arrow leases, source identities and failed/reverted diagnostics.
  No full warm, concurrent, sustained-capacity, type/lifecycle or native Linux
  acceptance is inferred from this subset.


## Live checkpoint ownership — 2026-10-20

The [isolated live-flush layer](2026-10-20-immutable-point-live-flush.md)
publishes validated mapped numeric owners to PointStore, the collection projection
and matching read runs, retaining old roots and sharing existing run indexes.
Validation covers 77 selected Mojo cases (including two corrected exact-file lease
fixtures), 23 checkpoint/WAL cases and 379 distinct Python cases after correcting
the spawned-client launcher. Original failures remain archived. The candidate
library builds; production stays `a6822c3`, with no new speed or capacity claim.
Next complete shared live authority and mapped publication for foreground,
background and partial compaction, preserving selected-range cutoffs, newer writes,
legacy cutover versions and destruction outside writer. Every strict M5/M6 gate
and the remaining consumer/type/lifecycle requirements stay open.


## Live compaction ownership — 2026-10-20

The [isolated compaction layer](2026-10-20-immutable-point-live-compaction.md)
uses shared PointTable/MemTable authority and validates mapped outputs before
foreground/background/partial publication. Selected-range version cutoffs preserve
later writes; matching read runs keep existing indexes and old readers retain
their exact-file leases. It follows pinned Qdrant's locked publication and deferred
retirement principles within Akasha's current durability protocol. Validation
covers 191 cases in 37 selected Mojo modules, 23 checkpoint/WAL cases, 379
distinct Python cases and a candidate merge with 32 descriptors. Fixture and
implementation failures are retained. Production stays `a6822c3`; full consumer,
type/lifecycle, fixed performance, sustained capacity and native Linux acceptance
remain open. No new speed result or M5/M6 completion is claimed.


## Numeric consumers and fresh failed speed gates — 2026-10-20

The [isolated consumer layer](2026-10-20-immutable-point-consumers.md) applies pinned Qdrant's borrowed-read
boundary to Arrow, Python conversion, GPU upload and legacy recovery. Shared
registry propagation preserves exact-file ownership, and no-op flush now retries
PointStore's pending cleanup. Validation covers 151 cases in 34 CPU modules,
23 checkpoint/WAL cases, 379 Python cases, the candidate C ABI and 12 actual
Metal cases (reused across the subsequent cleanup-only change). Initial
materialization, lifetime-fixture, cleanup and process-runner failures are retained.

The fresh 27-worker mixed comparison audits 7,776 responses, 27 exact reopens and
18 Arrow leases. Production/candidate results, score bits and query statistics
match; both Akasha variants meet all 36 quality cells, while matched quality is
33/36 because Qdrant's three real correlated cells remain below .95. Strict
quality-plus-speed passes are 25/36 production versus 18/36 candidate, with nine
pass-to-fail regressions; combined write-plus-flush passes 9/9 for each. No
threshold or sample exclusions change. Production stays `a6822c3`. Next measure
publication/lock stalls suggested by retained latency spikes, then continue the
fixed performance, sustained capacity and native Linux gates. M5/M6 remain open.


## Publication critical section — 2026-10-20

The [isolated publication experiment](2026-10-20-immutable-point-publication.md) follows pinned Qdrant's separation
of expensive preparation from locked finalization. Instrumented runs identify
repeated point validation and full read-run descriptor copies inside Akasha's
shared query/publication writer lock. Removing only the already completed point
validation reduces median publication holds from 1.80–1.87 ms to 1.33–1.48 ms;
8,224–8,440 read descriptors still copy under writer. This does not implement
Qdrant's full read/update lock separation.

A valid-CRC semantic-corruption regression covers v4/v5 rejection and cleanup.
The unchanged candidate passes 60 cases in ten CPU modules, 23 checkpoint/WAL
cases, 379 Python cases and the C ABI checks. Fresh uninstrumented mixed tests
run 36 serial workers, auditing 10,368 responses, 36 exact reopens and 27 Arrow
leases. Production/prior/candidate strict quality-plus-speed passes are 26/15/20
of 36. Seven production passes and one prior-candidate pass become failures;
all remain recorded. Combined write-plus-flush passes 9/9 for all three variants.
Production stays `a6822c3`, with no adoption or M5/M6 completion. Next move
immutable read-run preparation out of writer while preserving current writes,
snapshot owners and publication checks, then continue all unchanged performance,
sustained capacity and native Linux gates.


## Unlocked immutable read-run preparation — 2026-10-20

The [isolated read-preparation layer](2026-10-20-immutable-point-read-preparation.md) captures immutable run owners,
builds replacement descriptors outside writer, then validates the captured chain
and stages only the current bounded head before publication. New writes and old
snapshots survive; changed chains use the existing conflict/retry protocol.
Four new cases cover interleaving, stale chains, build failure and cancellation.
Validation passes 134 cases in 23 CPU modules, 23 checkpoint/WAL cases,
379 Python cases and the candidate C ABI. Exact source/native identities and all
initial compile failures are archived.

Diagnostic combined lock holds are .776/.901/.825 ms across the three corpora,
with .804/.893/.847 ms of read-run construction now outside writer. However,
waits over 100 microseconds increase from 9/2/6 to 16/7/13 across separate
diagnostic batches, suggesting a cost from two critical sections. Next reduce
capture to shared immutable references and prepare replacements from validated
output while preserving legacy cutover/version rules and final live checks.

The fresh 36-worker comparison audits 10,368 responses, 36 exact reopens and
27 Arrow leases. Production/prior/candidate strict quality-plus-speed passes
are 22/14/18 of 36, with four production and one prior-candidate pass-to-fail
regressions retained. Combined write-plus-flush passes 9/9 for each variant.
Production remains `a6822c3`; the candidate stays isolated. Full warm/concurrent,
sustained nonresident capacity, integration/example and native Linux gates remain
open, with no M5/M6 completion or threshold changes.


## Shared-owner capture from immutable output — 2026-10-20

The [isolated owner-capture layer](2026-10-20-immutable-point-owner-capture.md) removes point traversal and row
projection from the first writer-lock section. Typed replacements use validated
output points; legacy replacements preserve cutover/document versions and existing
sparse/payload owners. Final live-authority validation remains locked. Validation
passes 137 CPU cases in 24 modules, 23 checkpoint/WAL cases, 379 Python cases and
the candidate C ABI. The legacy fixture initially used a foreground capture that
checkpointed away its intended inputs; its original failure and corrected use of
the background capture path are retained.

Diagnostic capture medians are .001 ms and combined holds .569/.638/.632 ms.
Uniform-128 has nine published attempts and one unpublished final attempt whose
original trace does not distinguish cancellation from conflict; output cleanup,
exact reopen and lease audits pass. The analyzer now records all outcomes rather
than requiring every background attempt to publish. No diagnostic worker is
rerun and no acceptance threshold changes. Published-only combined hold for
uniform-128 is .570 ms. Wait counts over 100 microseconds change from 16/7/13 to
7/8/5 across separate diagnostic batches.

The fresh 36-worker comparison audits 10,368 responses, 36 exact reopens and
27 Arrow leases. Production/prior/candidate strict quality-plus-speed passes
are 23/13/16 of 36; seven production and two prior-candidate pass-to-fail cells
remain recorded. Combined write-plus-flush passes 9/9 for each variant. Selective
queries still show publication sensitivity, while other modes spend most native
time in search. Next compare production/candidate native search phases and
separate publication wait costs before choosing the next change. Production stays
`a6822c3`; full warm/concurrent, sustained capacity, integration/example and native
Linux gates remain open. No adoption or M5/M6 completion is claimed.


## Paired native query phases — 2026-10-20

The [paired phase diagnosis](2026-10-20-immutable-point-query-phases.md)
compiles identically instrumented production/candidate kernels and runs twelve
serial workers in balanced paired order. All 3,456 timed responses, 12 exact
reopens and 12 Arrow leases match; all 36 warmups remain recorded separately.
Candidate search-core medians exceed production across all twelve groups,
including 5.25/6.00/6.50 microsecond selective gaps, while filter costs are similar.
Publication waits remain a separate cost. Next evaluate the pinned Qdrant
batch-read/scorer boundary without changing arithmetic, eligibility or lifetimes;
lock shortening alone cannot remove the measured query-core gap. This adds no
product change or acceptance result. The prior strict 23/36 production versus
16/36 candidate result, all regressions and open M5/M6 gates remain unchanged.
