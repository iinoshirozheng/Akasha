# Separate live-vector work from delta history inspection

Baseline production `9bf69e0`; this is the next isolated implementation, not an
adopted policy. Evidence is the [mixed-query/history investigation](../research/2026-10-04-mixed-query-work.md).

The current delta scan policy charges inactive physical slots as if their vectors
were scored. The scan already checks current/source/filter status before distance
calculation. In the original real mixed workload, crossing 1,024 physical slots
with the same live count switches back to graph traversal and materially adds
work. Keep both kinds of work bounded using the existing cached source count.

Candidate internal policy (all conditions required):

- A live immutable base and a nonempty valid delta; `0 < delta_live <= physical_slots`.
- At most 1,024 live delta rows and 1,572,864 live vector components.
- Physical slots at most `max(1024, 2 * delta_live)`, hence never more than 2,048.
- Physical slots still at most normalized initial ef times M0.

Use division/subtraction checks to avoid integer overflow. This retains physical
history as a work bound and retains the low-ef restriction. Do not change the
original graph/scan loops, admission, per-source candidate breadth, query checks,
arithmetic, public scores, formats, ownership, rebuild settings, inputs or efs.
Delta-only collections remain graph searches. Remove the old internal predicate
signature instead of adding a compatibility overload. No new user configuration.

The native history sweep covers three corpora, 256/819/1024 live rows and four
history levels, three efs, three fresh processes each. The proposed predicate
newly admits 72 cells: 60 matched-quality cells improve mean/p95, and the other
12 retain their graph recall failures. The old known 1,024-live/ef10 and
4,096-live/ef32 regressions remain excluded. This evidence supports a candidate;
it does not prove public performance, arbitrary workloads or other hardware.

Before promotion, add policy boundary/overflow tests and end-to-end cases crossing
1,024 physical slots with replacement/delete/reinsert history, owned/mapped base,
all relevant native backends, filters, bounded candidate sets, stable ties, zero
base, invalid identity/query/demand and upper history limits. Verify source counts
and actual scoring counts. Preserve old small-history coverage with the new
predicate signature. Add a failing-before behavioral case before implementing.

Run affected Mojo first, then build the copied binding entry. Run the original
full warm/mixed/Qdrant matrices serially with unchanged seeds, corpora, filters,
K, efs, boundaries and all trials. Compare public score bits for common IDs and
oracle/recall/filter validity; path/stat differences caused by scan selection must
be explicit, never hidden by disabling audits. Keep all slow and low-recall cells.
Broaden Python/C/examples and recovery/cache validation if adoption is warranted.

Recall@10 >= .95, QPS >= Qdrant and p95 <= Qdrant remain required in every cell.
No tolerances, median-only verdict or cross-cell offsets. The named multi-run
lifecycle and unavailable sustained nonresident/memory-limit gate are separate
unfinished M5/M6 work. Existing output/archive directories are immutable evidence;
use a fresh `.build/2026-10-04-delta-live-budget` tree for implementation.
