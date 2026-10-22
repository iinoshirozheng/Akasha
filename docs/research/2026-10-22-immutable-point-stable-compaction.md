# Qdrant stable-compaction store guard — rejected

Keep deferred-ID as the retained implementation. Porting Qdrant's guard against
writing a candidate back to its unchanged position preserves correctness but
does not consistently improve the outstanding mixed workloads. Production
`src` remains `a6822c3`, and the last strict mixed result remains **25/36**.

## Upstream basis and implementation

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d` contains the complete
pattern in `lib/common/common/src/condition_checker.rs:138–149`:
`default_check_batched`, with `Rest::Discard`, stably compacts matches and only
stores an item when its write index differs from its read index.
`FilteredScorer::score_points` calls batched filtering with that option before
applying its cap. `ScorerFilters` batches deletion checks before payload checks.

The inspected ordinary `GraphLayersBase::search_on_level` marks scored points
visited. Rejected points can be checked again through another adjacency row;
the inspected scorer/filter path does not memoize their eligibility. Akasha's
existing regression explicitly checks that behavior. This candidate adds no
rejection cache or phase reordering.

The complete **132-file** source copy comes from retained
[deferred-ID](2026-10-20-immutable-point-deferred-id.md), not either rejected
[current predicate](2026-10-22-immutable-point-current-predicate.md).
Only `index/hnsw_search.mojo` changes: the existing `points[count] = slot` is
guarded by `count != index`. All current/source/filter checks still execute in
the same order. Compaction order, cap, rejection counters, score bits, public-ID
reads, cancellation and error precedence remain unchanged. No field, format,
ownership, dependency, configuration or ef changes.

## Verification

The existing focused matrix passes **64 CPU cases / seven modules**, including
filter/cap ID-read controls, repeated rejected-neighbor checks, search ties,
invalid-input stats, cancellation, mapped views and segmented HNSW. No additional
test merely mirrors the new conditional assignment.

The exact measured native binary contains the intended guard. In the mapped
filtered F32-dot scorer, `cmp x24, x20` at `0x2c9c44` and the following `b.ne`
select the store block at `0x2c9c7c`; equal indices bypass its `str` at
`0x2c9ca0`. The inspected function has 993 instructions versus the parent's
1,000. This static observation establishes implementation, not a speedup.

Twelve serial workers run all three frozen corpora in both parent/candidate
orders. Every **3,456 timed response, 12 exact reopen and 12 retained Arrow lease**
passes. IDs, F32 score bits, stats, route, recall and oracle match the retained
baseline exactly. The **36 warmup return values are not compared**.
Native import identity and source/workload/plan hashes are checked. All QPS,
nearest-rank p95, pair ratios and medians independently reproduce from raw
latencies, including a replay using only the final archive.

## Results and decision

Median candidate/parent ratios retain both orders and every control. Higher
QPS and lower p95 are better.

| Corpus / mode | QPS | p95 |
| --- | ---: | ---: |
| uniform-128 / all | .9911 | .9807 |
| uniform-128 / correlated | .9849 | 1.0257 |
| uniform-128 / independent | .9868 | 1.0102 |
| uniform-128 / selective | .9878 | .9564 |
| uniform-1536 / all | .9654 | 1.0576 |
| uniform-1536 / correlated | .9912 | 1.0463 |
| uniform-1536 / independent | .9530 | 1.0572 |
| uniform-1536 / selective | .9395 | 1.1415 |
| real-1536 / all | .9920 | 1.0203 |
| real-1536 / correlated | .9977 | .9915 |
| real-1536 / independent | .9934 | .9960 |
| real-1536 / selective | .9936 | .9648 |

Uniform-1536 independent QPS declines in both orders (**.9091 / .9968**), as do
both uniform-128 filtered QPS values. Uniform-1536 correlated changes direction
between orders (**.9207 / 1.0616**). The untouched uniform-1536 selective route
also varies substantially: first-order QPS/p95 is **.8728 / 1.2662** and reverse
order **1.0062 / 1.0169**. These samples are retained; the changed branch is not
asserted to cause the control variation.

**Reject the candidate.** There is no consistent target improvement and no
new full Qdrant acceptance comparison. Python/crash/C, capacity, concurrency,
examples/integration and native Linux gates are not newly validated here. No
ef adjustment, tolerance or sample exclusion changes the original requirements.

The next inspection should address the complete scorer/admission call boundary
and repeated state passing, against Qdrant's per-condition batch implementation.
Reordering throwing checks or adding rejection memoization requires proof of
the existing counter, cancellation and first-error contracts. Do not repeat
this one-store guard without new evidence.

## Evidence

The [verified archive](2026-10-22-immutable-point-stable-compaction.json.gz)
contains **276 text artifacts, 1,025,038 bytes**, SHA-256
`6a17a62d7b5680d054fafd5005a365d441e1b31bb252f4b7ecbf0a66927e7277`.
It preserves full source/package text, validation logs, all timed reports,
baseline responses, disassembly, pinned reference sources/license and drivers.
Existing frozen-plan archive references and workload hashes are retained;
binaries and database copies are excluded and identified by hash.

Candidate native SHA-256:
`767816d487a028315a5c490658cb542b66428e56fa45581199c6f9c25d7ea6a1`.
Parent native SHA-256:
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.
