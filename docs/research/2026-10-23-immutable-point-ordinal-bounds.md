# Bounded ordinal reads and the authorized ef=128 mixed rerun

**Neither ordinal-read candidate is adopted.** With the user-authorized Qdrant
calibration, the complete mixed comparison passes **production 25 / retained
26 / candidate 26 of 36** strict cells. All 36 quality cells and all nine
combined update/flush comparisons pass for each Akasha version. The candidate
gains one cell and loses another; smaller generated code did not close the
remaining performance gap. Production `src` remains unchanged from `a6822c3`.

## Acceptance decisions and original evidence

On 2026-10-23 the user approved changing only Qdrant's
`real-1536 / correlated` ef from **96 to 128**, with a complete rerun. Akasha's
parameters, all other Qdrant parameters, workloads, oracle, samples and strict
Recall@10 ≥ .95 / QPS ≥ Qdrant / p95 ≤ Qdrant gates are unchanged.
The user also deferred native Linux x86_64 acceptance because no test machine
is available. That environment is **not evaluated**, outside current local
acceptance scope; it is not a pass.

Before this decision, an unchanged-engine baseline ran all three corpora,
three trials and both engines: **18 workers / 5,184 measured responses**,
18 exact reopens and nine retained Arrow leases. It passed **23/36**, with
**33/36 quality cells** and **9/9 update-plus-flush comparisons**. All measured
IDs, F32 score bits, stats, execution routes, recalls and oracles matched the
previous controls for both engines. The earlier 21/36 and this 23/36 use the
same engine bytes: their difference is batch variation, not an optimization.

Two separately labelled real-data Qdrant diagnostics changed only correlated
ef. They completed another 576 measured responses and two exact reopens:

| Qdrant correlated ef | Mean Recall@10 | Role |
|---|---:|---|
| 96 | .9458333333 | Original failed quality gate |
| 128 | .9666666667 | Diagnostic supporting the user's decision |
| 256 | .9888888889 | Diagnostic only; not selected |

Every non-correlated response in both diagnostics matches the original plan's
IDs, bits, stats, route, recall and oracle. These timings are not substituted
into the original trials. The first baseline-driver launch failed on an import
path before starting any worker; its source, log and exit result remain in the
archive. Read-only host VM/swap/thermal observations surround all 20 workers;
they do not establish zero-swap or nonresident conditions.

## Source-grounded hypothesis

Qdrant reference revision is
`21db2f3ff95d50de3a2b88a741312c056fd1762d`. Its
[`NotDeletedChecker`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/raw_scorer.rs#L580)
checks live deletion bits by internal point offset; its
[`ScorerFilters`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/point_scorer.rs#L61)
checks deletion before metadata eligibility. Akasha already follows that order
with a live source bitmap and a cached slot-to-metadata ordinal projection.

The retained base admission still accessed `List[Int]` with an ordinary
subscript. Its measured mapped Dot/F32 admission callee reserved `0x870` bytes
and prepared List assertion formatting on the successful path. Following the
existing [bounded bitmap read](../benchmarks/2026-10-16-bitmap-bounded-read.md),
the experiment replaced this read with an explicit Optional guard, a check of
the current initialized length, and scoped `unsafe_get`. This checked-read
implementation is Akasha-specific, not a literal copy of Qdrant's bit API.

Only `akasha/index/segmented_hnsw.mojo` differs from the retained 132-file source
in either candidate. Source checks still run first, the delta choice remains
runtime, delta IDs are resolved once, and metadata bit access remains checked.
No pointer or view escapes, no live bitmap is snapshotted, and no results,
traversal order, retry policy, public API or durable format change.

The first version assigned the projection Arc to a local variable. Native
inspection found an atomic reference increment and destructor on each read.
Its 12-worker, two-order screen preserved **3,456 exact measured responses**,
12 reopens and 12 leases, but mixed performance did not support adoption.

The second version borrows through the retained Optional directly. Both
versions pass **70 cases in eight modules**, including three new tests for
live source short-circuiting, source-error precedence, missing/truncated
projections, the last initialized slot, missing ordinal sentinels, metadata
bounds and absence of base public-ID reads. This is 70 unique cases executed
against two versions, not 140 unique tests.

The second native scorer inlines the base admission: its static instruction
count is 1,123 versus 1,000 in the parent, while the parent's separate
225-instruction admission callee is absent. These are different inlining
boundaries, not directly comparable function costs. Neither the scorer nor
its base path adds projection-Arc increments or destruction. Static code
shape alone does not establish an elapsed-time improvement.

## Complete mixed results

Three corpora × three trials × production/retained/candidate/Qdrant execute
serially in rotating orders: **36 workers / 10,368 measured responses**,
36 exact reopens and 27 retained leases. Every candidate response matches both
Akasha controls in IDs, F32 bits, stats, route, recall and oracle. All new
Qdrant responses match the corresponding unchanged-plan control or ef=128
diagnostic. The **108 warmup return values are not compared**.

| Version | Quality cells | Strict cells | Update + flush |
|---|---:|---:|---:|
| Production | 36/36 | 25/36 | 9/9 |
| Retained deferred-ID | 36/36 | 26/36 | 9/9 |
| Borrowed bounded ordinal | 36/36 | 26/36 | 9/9 |

Compared with the retained version, the candidate gains `uniform-128 / all`
in trial 0, but loses `real-1536 / independent` in trial 2. The latter has
QPS/Qdrant **.993488** despite passing p95. It remains a failure without a
tolerance or sample exclusion.

The candidate's three-trial median QPS ratios against retained are only
**1.0111 / 1.0111** for uniform-1536 correlated/independent; their p95 ratios
are **1.0173 / 1.0064**, respectively. Real-1536 correlated is **.9833 QPS**
and **.9907 p95**. These results do not support adopting this optimization.

Retained's ten current failures are one uniform-128 unfiltered cell, all six
uniform-1536 filtered cells, and all three real-1536 correlated cells. In the
real correlated cells its QPS/Qdrant is **.6927–.7838**. Fixing Qdrant's quality
calibration exposes that speed gap; it does not make those cells pass.
The new 26/36 and original 23/36 are different batches and ef contracts, so
their difference must not be attributed to the rejected implementation.

## Reproducible evidence and remaining scope

Work directories are `.build/qdrant-alignment/immutable-point-goal-baseline`,
`immutable-point-ordinal-bounds` and `immutable-point-ordinal-borrow`.

Native SHA-256 identities:

- Retained: `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`
- Local-Arc candidate: `cdc2a467c652a5e2d607e126d8cf3a1f412e90381f08b40598cb43d468d5c4fb`
- Borrowed candidate: `3d633a7429de724f092fabe6e86dadb6e5985b1c1df29e5a6792aa961ec27d83`
- Qdrant: `746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`

The [evidence archive](2026-10-23-immutable-point-ordinal-bounds.json.gz)
contains **737 expanded artifacts**, **18,717,248 bytes**, SHA-256
`ac3169d074d8aa528900c0a2554e07fd1642e517531bfc8c8f70bea9d23a158d`.
It stores 732 files and five exact plan-derivation recipes to avoid duplicating
unchanged vector inputs. Expand `metadata.derived_files` from its source text;
when `qdrant_correlated_ef` is present, change that JSON field and encode with
`json.dumps(data) + "\n"`. Every expanded file has an independently checked
SHA-256. Native binaries and database files are identified, not embedded.

Archive-only extraction and `immutable-point-ordinal-borrow/audit_bundle.py`
replay verify all source/plan identities, raw latency statistics, quality and
strict gates, regressions, exact responses and targeted test results. The
combined original baseline, probes, screen and full rerun comprise **68 workers
/ 19,584 measured responses / 68 exact reopens / 48 leases**, with 204 warmup
return values not compared. No sample is discarded.

The retained engine and its previous complete CPU validation remain unchanged.
Warm, concurrent-client and sustained nonresident-capacity acceptance remain
open. Native Linux is deferred by user decision, not failed or passed. M5/M6
are not complete; the next optimization must address measured filtered-search
work beyond this ordinal-access change and preserve live admission semantics.
