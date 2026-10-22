# Compile-time source admission — rejected

Keep deferred-ID as the retained implementation. Specializing base/delta source
admission removes a runtime branch but regresses the high-dimensional filtered
workloads in every fresh full-comparison trial. Production `src` remains
`a6822c3`. The latest retained strict mixed result is **21/36**; the earlier
**25/36** remains a separate historical observation, not the current result.

## Upstream basis and implementation

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` provides separate
internal-point deletion checks and optional filter context. `NotDeletedChecker`
reads vector/point deletion bits, `ScorerFilters` combines deletion and payload
checks, and `FilteredScorer::score_points` filters before applying its cap and
scoring the retained offsets. The inspected path does not justify caching
rejected-point eligibility or replacing current flags with live counts.

This experiment adapts that separation to Akasha's existing base/delta source
selector. It is an Akasha-specific compile-time specialization, not a literal
Qdrant algorithm. All four production factories already supply a fixed Boolean.
`_SourceAdmission[delta: Bool]` and `_FilteredSourceAdmission[delta: Bool]` move
that choice from a runtime field to a compile-time parameter. Their existing
checks, errors and order remain intact. Shared source state still observes
later updates; the candidate adds no snapshot or memoization.

The full **132-file** source copy starts from retained
[deferred-ID](2026-10-20-immutable-point-deferred-id.md), not the rejected current
predicates or compaction guard. Only `index/segmented_hnsw.mojo` changes. The
private constructors are replaced, with existing test call sites adapted only
to that syntax. No public API, format, ownership, dependency, configuration,
scoring, ef or durability contract changes.

## Correctness and generated code

The focused matrix passes **67 CPU cases / eight modules**, preserving the
existing deferred-ID, filtered-delta, segmented, ordinal, search-layer, filter,
cancellation and mapped-view assertions. Archive checks verify every adapted
test against the original constructor-only transformation.

Exact-binary disassembly resolves the actual admission callee from the mapped
filtered F32-dot scorer. Its instruction count falls **225 → 165**, while the
caller grows **1,000 → 1,043**. Both admission functions retain the explicit
`sub sp, sp, #0x870` reservation, in addition to saved-register space. The frame
is not eliminated. These static counts establish code shape, not elapsed cost.

The two-order screen and full comparison contain **48 serial workers and
13,824 timed responses**. Every **11,232 Akasha response** exactly preserves
IDs, F32 score bits, stats, route, recall and oracle. The remaining 2,592 Qdrant
responses receive the original membership/quality checks. All **48 exact
reopens and 39 Akasha retained leases** pass. The **144 warmup return values
are not compared**. Native import identity, source, frozen plans and workloads
are checked throughout.

## Screen and full comparison disagree

The initial 12-worker screen improves both high-dimensional filtered targets
in both orders. Median candidate/parent QPS ratios are **1.0117 / 1.0153** for
correlated/independent; corresponding p95 ratios are **.9769 / .9734**. This
justified a full comparison, not adoption.

The fresh 36-worker comparison rotates production, retained deferred-ID,
candidate and Qdrant through three trials of all three frozen corpora. Original
quality, QPS, p95 and write/flush gates remain unchanged:

| Implementation | Strict mixed cells | Quality cells | Write/flush trials |
| --- | ---: | ---: | ---: |
| Production | 20/36 | 33/36 | 9/9 |
| Retained deferred-ID | 21/36 | 33/36 | 9/9 |
| Static-source candidate | 22/36 | 33/36 | 9/9 |

There are no production/retained pass-to-fail cells. The sole new passing cell
against retained is uniform-128 independent, trial 0. Nevertheless, the
uniform-1536 correlated QPS ratios are **.9370 / .9242 / .9179**, and independent
ratios **.9321 / .9207 / .9175**. All three trials regress both outstanding
high-dimensional targets by roughly 6–8%. Counting passing cells alone would
hide that regression.

Full-comparison median candidate/retained ratios retain every mode and trial.
Higher QPS and lower p95 are better.

| Corpus / mode | QPS | p95 |
| --- | ---: | ---: |
| uniform-128 / all | .9892 | 1.0204 |
| uniform-128 / correlated | 1.0068 | .9909 |
| uniform-128 / independent | 1.0229 | .9487 |
| uniform-128 / selective | 1.0030 | .9994 |
| uniform-1536 / all | 1.0049 | 1.0102 |
| uniform-1536 / correlated | .9242 | 1.0488 |
| uniform-1536 / independent | .9207 | 1.0441 |
| uniform-1536 / selective | .9899 | 1.0177 |
| real-1536 / all | .9920 | 1.0128 |
| real-1536 / correlated | 1.0092 | 1.0042 |
| real-1536 / independent | 1.0041 | .9679 |
| real-1536 / selective | 1.0007 | 1.0059 |

Retained now has **12 speed failures and three quality failures**. The Qdrant
real-correlated recall failures remain included. No ef change, tolerance or
sample exclusion repairs the count. Both the favorable screen and unfavorable
full comparison remain in the evidence.

## Separate full-plan CPU diagnosis

Four additional serial workers replay the complete uniform-1536 mixed plan on
the unchanged retained/candidate binaries in both orders. Instrumentation adds
calling-thread CPU time, process CPU time and resource counters around each
original search interval. It changes diagnostic timing overhead and does not
replace acceptance. All **1,152 responses, four reopens and four leases** pass;
12 warmup returns are not compared.

| Mode | First-order wall / thread CPU | Reverse-order wall / thread CPU |
| --- | ---: | ---: |
| all | .9986 / .9984 | 1.0048 / 1.0042 |
| correlated | 1.0831 / 1.0832 | 1.0968 / 1.0963 |
| independent | 1.0746 / 1.0745 | 1.0851 / 1.0851 |
| selective | .9981 / .9979 | 1.0285 / 1.0285 |

The filtered regression also appears as **7–10% more calling-thread CPU time**.
All per-query `ru_majflt` deltas are zero. This does not establish physical
residency, absence of paging, cache misses or a microarchitectural cause.
Global counters outside the query intervals record nonzero paging/compression
activity in some workers. Process CPU includes all process threads and must
not be treated as calling-thread CPU.

A separate post-run host observation records about 12,195 MiB swap in use and
zero swap-ins/outs during its ten-second window. It is post hoc and cannot
explain the earlier benchmark results. Neither that observation nor the CPU
ratios support attributing the regression to swap, scheduling or instruction
counts alone.

## Decision and evidence

**Reject the candidate; keep deferred-ID.** Next profile the complete frozen
mixed workload with the exact retained and rejected binaries to locate the
additional CPU cost before changing another scorer/admission detail. Earlier
two-query profiles are not a substitute for this full-plan diagnosis.

Fresh Python/crash/C, sustained capacity, concurrency, examples/integration and
native Linux gates are not run for this rejected candidate. Every open M5/M6
requirement remains active. This report claims no completed performance parity.

The [verified archive](2026-10-22-immutable-point-static-source.json.gz) contains
**417 text artifacts, 2,679,540 bytes**, SHA-256
`5f35728b900cad7cc986060e9cf931d93c3e662773ce0b97f1efd7969ba21704`.
It includes full source/package text, constructor adaptations, validation logs,
all timed/diagnostic reports, pinned reference source/license, disassembly,
baseline responses and reproduction scripts. Binaries/databases are identified
by hash; frozen plans retain their verified archive chain. Independent replay
using only this archive exactly reproduces both audits: raw QPS/nearest-rank
p95, every strict gate, paired ratios/medians and diagnostic CPU/resource
summaries. All 417 artifact hashes verify.

Candidate native SHA-256:
`9150ec4049864cd20e1e22c65cf38f70caf686e53beb4e80c5c8b51d72ffb1d9`.
Retained native SHA-256:
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
