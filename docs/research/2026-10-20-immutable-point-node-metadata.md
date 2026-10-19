# Copied HNSW node metadata

This follows the [source-cost diagnosis](2026-10-20-immutable-point-source-phases.md)
and starts from the retained [query-lock candidate](2026-10-20-immutable-point-query-lock.md).
The reference remains Qdrant commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`: `GraphLayersBase::search_on_level`
collects unvisited neighbors, and `FilteredScorer::score_points` filters the
batch before capping and scoring it. Their exact source and Apache-2.0 license
are included in the evidence. Copied Akasha node records are an Akasha-specific
implementation experiment, not a claim that Qdrant uses the same representation.

The proposed value contains slot, public ID, level and current flag. Its ID is
defined only for current nodes. A mapped read validates readiness and the slot,
checks the level, reads the current flag with its existing infallible behavior,
then reads the ID only for a current node. It retains checked scalar spans: a
wider load would incorrectly reject a readable level when the flag is missing.
No borrowed address escapes, no record persists across expansions, and public
owned getters and disk formats are unchanged. The internal scorer compacts
these copied values and reuses their IDs when constructing scored results.

## First probe: metadata before visited filtering — rejected

The first candidate calls the metadata reader for every neighbor, before the
visited check. It preserves the logical rejection/scoring sequence but performs
unnecessary reads for visited neighbors. This is visible directly in the source;
the timing result alone does not establish how much of the regression comes
from those reads versus the wider temporary buffer or generated code.

Three new reader tests check copies across mutation/close, metadata consistency,
invalid slots, closed-owner precedence, and partial-record bounds. Their initial
failure was a compilation error for the absent `_search_node` API, not a failing
runtime assertion. On final source, **41 cases across five modules** pass,
including layer traversal, scalar/four-row score bits, Qdrant-derived fixtures
and owned/mapped equivalence. The four-row test includes all three F32 metrics,
14 dimensions, repeated slots, filters, caps and tails.

Twelve serial mixed workers run prior/candidate then candidate/prior for each
of the three frozen corpora. All **3,456 timed responses** match the retained
candidate's IDs, F32 score bits, stats, execution route, recall and oracle.
All **12 exact reopens and 12 Arrow leases** pass. Each worker also performs
three warmups; their returned values are not included in that comparison.
The driver validates the original workload and plan, native identity and all
288 timed responses per worker. Builds/tests never overlap timed workers.

Ratios below are the median of the two paired ratios. QPS above one is better;
p95 below one is better. Raw reports retain every mode and both orders.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.0052 | 1.0277 |
| uniform-128 | correlated | 0.9607 | 1.0994 |
| uniform-128 | independent | 0.9567 | 1.0977 |
| uniform-128 | selective | 0.9926 | 0.9351 |
| uniform-1536 | all | 0.9833 | 1.0345 |
| uniform-1536 | correlated | 0.9823 | 1.0330 |
| uniform-1536 | independent | 0.9747 | 1.0343 |
| uniform-1536 | selective | 0.9962 | 1.0357 |
| real-1536 | all | 1.0037 | 0.9939 |
| real-1536 | correlated | 0.9869 | 1.0540 |
| real-1536 | independent | 0.9923 | 1.0430 |
| real-1536 | selective | 1.0129 | 0.9850 |

Both orders regress uniform-128 and uniform-1536 filtered QPS and p95.
The candidate is **not adopted or carried forward**. Its native SHA-256 is
`4b94712443b3f0281e2835ef1c14e22895fb238e7fa071f2359f46189b57feae`.

[Verified first-probe evidence](2026-10-20-immutable-point-node-metadata.json.gz):
**246 text artifacts, 913,142 bytes**, SHA-256
`d947653cdbcec47de68ebbd77eecdbfda2aa94ecb56f2825d88fd132052f92a0`.
The archive includes complete candidate source, changed scorer fixtures,
commands/logs, all mixed reports, upstream source/license and checked parent
and frozen-workload identities.

## Follow-up: collect metadata only for unvisited targets

The follow-up keeps full metadata reads after the visited decision. A guarded
epoch lookup sends out-of-range edges to the checked node reader. Already
visited neighbors still call `level`, so this does not repeat the previously
rejected base-level validation skip. Upper descent, which has no visited
filter in the existing algorithm, keeps its original sequence.

All first-probe tests pass again. Two additional boundary cases cover invalid
entry/later edges with both fresh and larger reused epoch storage, plus an
invalid upper edge reached after leaving the initial entry: **43 cases in six
modules** pass. The same twelve-worker protocol preserves another **3,456 timed
responses, 12 exact reopens and 12 leases**. Three warmups per worker remain
outside the returned-value comparison. All workers exit successfully.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.0311 | 0.9802 |
| uniform-128 | correlated | 0.9870 | 1.0634 |
| uniform-128 | independent | 0.9991 | 0.9748 |
| uniform-128 | selective | 1.0141 | 1.0033 |
| uniform-1536 | all | 0.9934 | 1.0025 |
| uniform-1536 | correlated | 0.9814 | 1.0491 |
| uniform-1536 | independent | 0.9815 | 1.0277 |
| uniform-1536 | selective | 1.0091 | 0.9929 |
| real-1536 | all | 1.0074 | 0.9833 |
| real-1536 | correlated | 1.0077 | 1.0271 |
| real-1536 | independent | 1.0045 | 0.9881 |
| real-1536 | selective | 1.0127 | 0.9361 |

The follow-up improves uniform-128 all in both orders, but correlated QPS and
p95 regress in both orders for both uniform corpora. Uniform-1536 independent
QPS also regresses in both orders. It is **not adopted or carried forward**.
These two screens are separately paired with their contemporary prior runs;
their median columns are not a direct timed first-probe/follow-up comparison.

The follow-up native SHA-256 is
`c391a34a8db96cc7dd96fecfcecbd489f5859cd20c595e1ebd2f0eebcd075d6b`.
[Verified follow-up evidence](2026-10-20-immutable-point-unvisited-metadata.json.gz):
**243 text artifacts, 913,765 bytes**, SHA-256
`076638f8dc93860e59ce7c22f743d2cc2039d707086b42f94af9ef7528b6f9ec`.
The first-probe archive is referenced by checked hash. Complete sources,
commands, additional edge tests and raw timing/correctness reports are retained.

## Next hypothesis: defer public-ID lookup

Do not continue tuning either rejected metadata buffer. Start again from the
retained query-lock source. Its `score_points` eagerly calls `graph.id_at` for
admission, then again for scored results. However, `_SourceAdmission` on the
base reads only the slot bitmap; `_FilteredSourceAdmission` on the base reads
that bitmap and cached slot-to-ordinal projection. Neither base branch uses
its public-ID argument. `HnswSearchAdmission` also uses slots. Delta admission
and ID-based `HnswEligibility` do require public IDs.

Pinned Qdrant `FilteredScorer::score_points` and
`MetricQueryScorer::score_stored/score_stored_batch` operate on `PointOffsetType`.
This supports evaluating deferred ID resolution in Akasha's admission
interface while keeping the existing UInt32 neighbor buffer. It is a source-
supported hypothesis, not a measured speedup. Preserve deterministic public-ID
ties for scored candidates, every bounds/readiness check, error/counter order,
and the delta/ID-based eligibility paths. The follow-up archive also includes
that pinned metric-scorer source.

These are implementation screens against the retained candidate. They do not
refresh Qdrant acceptance, the full CPU/Python/crash/C suites, sustained
nonresident capacity, concurrent-client performance or native Linux gates.
No ef, oracle, timing boundary, recall threshold or strict comparison changes.
Production remains `a6822c3`; the retained query-lock result remains **25/36**
on its previously recorded strict mixed comparison. M5/M6 remain incomplete.
