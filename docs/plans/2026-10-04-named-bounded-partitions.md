# Preserve named artifacts with bounded small-partition search

Baseline `1318457`; production kernel `eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`.
This is the next isolated implementation, **not an adopted bundle or a completed M5/M6 gate**.
Evidence: [native small-partition diagnostic](../research/2026-10-04-named-small-partitions.md).

The former bundle preserves ready graph bytes and avoids rebuilding on unchanged
reopen, but its extra small graphs add traversal work. The new diagnostic applies
the current bounded delta-scan policy to those actual extra graphs. All 360 eligible
partition cells reduce native mean/p95; the 36 selected complete partition-query
sums also reduce both. Original bundle IDs/distance/widening match in 14,472
queries; hybrid quality remains 141/216 and all 75 low-recall cells remain.
The three old uniform-128 independent/ef128 losses against a rebuilt single graph
also remain (.94375 versus .95). No ef change may hide them.

## Smallest complete implementation

Rebase the unadopted kind-5/version-1 bundle lifecycle onto the current engine in a
new isolated source/package tree, preserving all later correctness/performance
changes. Reuse its bounded codec and ready-graph capture, not its old complete
source tree as a replacement for current source. Keep all current callback-close,
native F64 four-candidate rerank, checked visit and delta live/history changes.
Do not revive graph reconciliation, point/batch repair, or the old named overlay.

Keep the first graph on the existing graph search. Additional current partitions
may use scan only under the current physical/live/component/ef limits, with a live
leading graph. Apply the same rule to additional read runs before publication and
to saved partitions after reopen; unchanged state must preserve candidate/result
behavior across that transition. Keep empty/hidden runs, omitted zero-member
partitions and subsequent updates explicit. Do not shrink candidate or ef budgets.

Share the existing checked prepared scan implementation at the HNSW owner level
only where both callers need it; remove the duplicated segmented body if it is
moved. The segmented caller must retain its current policy, validation order,
score bits, empty behavior and counters. Named dispatch prepares its query as
before and calls that same checked scan for eligible partitions. Preserve all
per-scored-candidate finite/bounds checks, current/member/filter admission, heap
ties, owner lifetime, maximum work and authoritative native F64 rerank. No new
user settings, optional fast path flags, broad planning abstraction or dependency.
Keep the leading graph's original behavior rather than replacing the whole collection
with an unconditional exact scan; per-partition path/work differences must be
recorded explicitly.

Retain the former bundle contracts: exact schema/config/current vector identity,
slot/ID membership coverage exactly once, authority ordinal rebinding, navigation
nodes excluded from result supply, no graph builds in the writer, single-attempt
artifact/query locks with retry, one final and one temporary file per field,
atomic AKIC CRC framing, and aggregate 512 MiB payload/decode bounds. Old optional
kind-4 cache invalidation is explicit in format/tests; no authority migration or
compatibility shim. Old snapshots, cancellation, close and operation leases remain.

## Verification and adoption evidence

First reproduce the current multi-run reopen cache miss. Adapt the existing
bundle lifecycle/native/corruption/limits/retry tests to current source, then add
small-partition cases for all supported native metric/scalar backends, owned data,
filtered/shadowed rows, ties, odd dimensions, small K, full candidate budgets,
empty partitions, work ceilings and invalid queries/identities/demand. Verify
pre-close versus reopened results/candidate budget and aggregate base/delta work;
individual base/delta labels can change with read-layer layout, not their meaning.
If moving the shared scan helper, rerun the current delta scan/history and relevant
segmented, widening, native and recovery tests; do not assume the prior 146 tests
prove a new helper refactor.

Run related crash/cache/backup/compaction validation for the new publication path,
then isolated full Python, C ABI and rebuilt examples with the existing source,
Metal PATH, saved-package import/hash and `-o pythonpath=` guards. Never overwrite
the native worker during tests. Archive compile/test failures as well as successes.

Only then run the original full named lifecycle grid: all corpora/trials, initial
build, original writes/deletes, flush/close/reopen/first query, all filters/efs and
warm samples. Compare to current production, not the obsolete bundle binary. Keep
native score/oracle and pre-close/reopen audits; retain all low recall and slower
trials. Run the original affected Qdrant gates too; a shared core change requires
the full original warm/mixed matrix. All timing must be serial and isolated from
build/test/compression. Native partition timings cannot be added to old public
cohorts or treated as their expected speedup.

The user gate remains every original cell/trial at Recall@10 >= .95, QPS >= Qdrant
and p95 <= Qdrant, with no tolerance, ef retuning, sample removal, median-only
verdict or cross-cell offset. Incremental adoption and whole-goal completion are
separate decisions; neither a cache hit nor this diagnostic completes M5/M6.
Sustained nonresident/memory-limit still needs a supported runner; none is available
and the user must not be asked again. Do not rerun the former bundle unchanged.
