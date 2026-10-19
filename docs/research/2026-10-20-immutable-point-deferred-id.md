# Defer public-ID reads in slot-based HNSW admission

Retain this isolated candidate for subsequent work. It improves the measured
high-dimensional filtered target and passes the relevant correctness checks.
The fresh strict mixed comparison is **production 24 / prior 24 / candidate
25 of 36**, with **no production/prior pass-to-fail cells**. This is not full
acceptance: eight speed cells and three quality cells still fail, and the
remaining M5/M6 capacity, concurrency and platform gates stay open. Production
`src` remains `a6822c3`.

## Source basis and implementation

The candidate starts from [query-lock](2026-10-20-immutable-point-query-lock.md),
not either [rejected copied-metadata buffer](2026-10-20-immutable-point-node-metadata.md).
Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` uses internal
`PointOffsetType` values in `FilteredScorer::score_points` and
`MetricQueryScorer::score_stored/score_stored_batch`. Akasha already has
slot-addressed base-current bitmaps and cached slot-to-metadata ordinals, but
its traversal eagerly read a public ID before calling these admission paths.
Those base branches never consumed that argument.

Five files change. `HnswResultAdmission._allows_slot(graph, slot)` resolves an
ID only in admission implementations that require one. Slot flags, base source
membership and cached base ordinals do not fetch it. Delta source admission and
ID-based `HnswEligibility` retain checked ID resolution. Filtered delta admission
resolves once for both source and eligibility checks. `_allows_item(slot, id)`
continues to serve paths that already have an ID: the delta scan, exact fallback
and extra-entry heap. Both operations have active callers; there is no fallback
adapter, fake ID, new package or configuration switch.

Traversal keeps the UInt32 candidate buffer, level/current checks, visited
ordering, filter-before-cap ordering and score kernels. Scored candidates still
resolve their public IDs for the existing distance/ID/slot tie rule. Graph
storage, mapped-view accessors, immutable numeric owners, formats, public owned
getters, query locks and durable publication code are unchanged. No mapped
pointer escapes. The change avoids accesses to an unused field; actual graph
access remains checked through the existing accessors.

## Verification

A counting adapter delegates to real `HnswStorage` and the production scorer.
Before implementation, three runtime assertions fail on actual ID-read counts:
**9 instead of 1**, **11 instead of 4**, and **8 instead of 1**. Delta and
ID-based controls already pass. All five pass after implementation. Two further
filtered-delta cases verify that its two membership checks share one ID lookup,
including an entirely rejected batch. Scorer output IDs, F32 score bits, caps,
filtered/inactive counters and distance counts are checked with the reads.

Relevant final-source validation passes:

- **262 unique CPU cases in 43 modules**: 115 admission/search/construction/
  mapped/quantized cases, 137 broader owner/publication/recovery cases, eight
  query-lock cases and two filtered-delta cases.
- **23 crash cases in eight modules**.
- **379 Python cases**, with four processes independently checking the exact
  candidate extension identity; the existing Starlette/httpx deprecation warning
  remains in the log.
- **C ABI library build and tests** with the candidate source.
- **98 independent extracted-Qdrant search fixtures** on scalar and batched F32
  paths, matching result slots and distance-call counts.
- **24 independent extracted-Qdrant construction fixtures**, matching the exact
  order of **2,467 adjacency rows**.

The source-oracle drivers retain their extraction functions, fixtures and Rust
adapters unchanged, checked by AST comparison. Only the candidate include root,
command logging, RTK prefix and source identity reporting change. Each oracle
checks pinned upstream bytes and freshly builds/runs its extracted Rust code.
As documented in the [source oracle scope](../../benchmarks/mojo/qdrant_search_reference.md),
these distinct-score fixtures establish the tested single-entry traversal and
serial construction behavior; they do not establish equality of multi-entry
query search, native Edge kernels or whole-product behavior.

The first broad admission compile exposed a test oracle still passing a mutable
List to the retained immutable numeric-reader API. Its candidate fixture now
uses an immutable `_NumericValues` owner. The initial error and corrected test
are retained; no product compatibility path was added. Source warnings from
unchanged compaction code also remain in the full logs.

Python native SHA-256:
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
C native SHA-256:
`a43fbed30f500718708a5a366c9151c454f4faa7a6cbec1f70d92529cfee23e3`.
The prior Python native remains
`4d71aec5b11193be99034bd87ccdc163d63526d464c84351bc44c7ddf1b4f96e`.

## Fixed mixed measurements

All builds, tests, workers and archive compression run serially. Each worker
clones the frozen initial database and runs the original 32-block plan: 288
timed requests, interleaved writes and flushes, then exact reopen validation.
The timing boundary remains request construction plus public search; subsequent
stats collection is outside timing. Workloads, oracles, ef, seeds, query modes,
strict recall threshold and QPS/p95 requirements are unchanged.

The initial 12-worker screen uses prior/candidate and candidate/prior for every
corpus. Uniform-1536 correlated/independent median paired QPS ratios are
**1.0373 / 1.0357**, with p95 ratios **.9486 / .9532**. Both modes improve both
metrics in both orders. The untouched uniform-128 selective route regresses in
both orders: median QPS **.9328**, p95 **1.1104**. That control is retained, not
excluded or assigned a cause from timing alone.

The subsequent 36-worker comparison uses production, prior, candidate and
Qdrant, with the same three prescribed order rotations. The two protocols
contain **13,824 timed responses**. All **11,232 Akasha responses** match the
retained baseline's IDs, score bits, stats, execution route, recall and oracle.
Every engine's report is audited for result count, membership, filters, oracle
identity and recall. All **48 exact reopens** and **39 Akasha Arrow leases**
pass. The **144 warmup return values are not compared**.

Fresh strict results:

| Implementation | Quality | Strict mixed cells | Write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 24/36 | 9/9 |
| Query-lock prior | 33/36 | 24/36 | 9/9 |
| Deferred-ID candidate | 33/36 | 25/36 | 9/9 |

The newly passing prior/candidate cell is uniform-128 all, trial 0. The prior's
historical 25/36 result is a separate run; it is not substituted for the fresh
24/36 baseline.

Candidate/prior ratios below are medians of the three paired ratios, not pooled
acceptance scores. QPS above one and p95 below one are better. Each individual
cell still has to pass both strict speed gates after quality passes.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.0709 | 0.8782 |
| uniform-128 | correlated | 1.0564 | 0.9593 |
| uniform-128 | independent | 1.0674 | 0.9358 |
| uniform-128 | selective | 1.0037 | 0.9603 |
| uniform-1536 | all | 1.0197 | 0.9990 |
| uniform-1536 | correlated | 1.0248 | 0.9865 |
| uniform-1536 | independent | 1.0324 | 0.9590 |
| uniform-1536 | selective | 0.9948 | 1.0383 |
| real-1536 | all | 1.0095 | 1.0201 |
| real-1536 | correlated | 1.0250 | 0.9894 |
| real-1536 | independent | 1.0244 | 0.9990 |
| real-1536 | selective | 1.0033 | 1.0006 |

Numerical regressions remain visible, including uniform-1536 selective and
real-1536 all p95. No production/prior passing cell becomes a failing cell in
this fresh comparison. Raw production and Qdrant comparisons and every order
are retained in the archive.

The candidate's remaining failures are:

- Uniform-128 all, trial 2: QPS only.
- Uniform-1536 correlated and independent, all three trials: QPS and p95.
- Real-1536 independent, trial 1: QPS and p95.
- Real-1536 correlated, all three trials: Qdrant recall **.945833** is below
  **.95**, while Akasha is **.980556**. No speed comparison is accepted for these
  cells. Nothing is excluded and no ef recalibration is performed.

An initial summary attempt incorrectly assumed that quality-failed cells had
speed fields and stopped with `KeyError` before producing analysis. The corrected
analyzer retains null speed fields for those cells; the failure note is saved.

## Decision and remaining work

Carry this candidate forward and reprofile its remaining base-search and rerank
costs against the pinned Qdrant runtime. Its deterministic reduction in ID reads
and measured filtered-search improvement are useful progress, but neither these
resident interleaved measurements nor the source oracles close the full warm,
concurrent-client, sustained nonresident-capacity, integration/example and native
Linux requirements. No production adoption or M5/M6 completion is claimed.

[Verified source, test, oracle and benchmark archive](2026-10-20-immutable-point-deferred-id.json.gz):
**703 text artifacts, 2,718,032 bytes**, SHA-256
`f2b129cf133ec06161b24121751112fcc0a0437ae68c23ef9c0a28f20eeff713`.
It contains complete candidate sources and Python package, test fixtures and
logs, extracted Rust, checked upstream source/license, exact native identities,
all raw mixed reports, drivers, decisions and parent/frozen-workload identities.
