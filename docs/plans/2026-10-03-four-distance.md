# Four independent F32 distances per query load

Latest: adopted after reevaluation on unlocked-reclamation baseline `7dd8647`.
[New results and all regressions](../benchmarks/2026-10-03-batch-after-reclaim.md):
174 targeted Mojo, 355 Python, C ABI and three examples pass. Warm 22/36 and mixed
26/36 remain FAILED, with one mixed pass→fail. The original experiment below is
preserved and must not be combined with the new trial set.

Experimental continuation of M5/M6 from `4fe68f1`; not adopted or accepted yet.
The production engine still matches `a710aa5` and the frozen `3ccdc28…` binary.

## Evidence

The real 1536D profile spends 43.7% of main-thread samples in mapped distance
and 13.1% in owned distance. Repeated query validation is measurable but its
public candidate did not establish a stable benefit. Source/binary A/A controls
show substantial short-query tail variation; GC explains only some slow samples.
Use the unchanged strict parity gate and retain every sample.

An isolated mapped kernel interleaves four independent rows with one query SIMD
load. It retains every existing mapped chunk bound check, per-row accumulator
width/reduction/tail ordering, slot/dimension checks and the mapping owner.
It adds no prefetch hints or unowned spans. All 67 queries × 8,192 slots in each
of three frozen corpora match the existing scalar-call distance bits. Seven
alternating passes show about 1.5× kernel throughput at 128D and 1.6–2.1× at
1536D. Sources and all samples are in `.build/2026-10-03-batch-distance`.
These are mapped-base diagnostics, not public ANN results or acceptance trials.

Local Qdrant uses batch scoring at graph adjacency boundaries. The proposed
Akasha slice uses that boundary while keeping each candidate's arithmetic and
result-admission order unchanged.

## Small end-to-end slice

1. Extend the existing graph-access capability with one private four-row F32
   distance operation, implemented directly for owned and mapped layouts.
   Use four independent SIMD accumulators, the existing width choice, scalar
   tails and `finish_distance`. No registry, new backend, public configuration,
   persistence, owner/cache layer or graph-format change.
2. In base-layer search, gather up to four first-visited neighbors from the same
   adjacency range. Keep neighbor order, level/bounds checks and duplicate
   suppression. Score full F32 groups in one call; score the remaining 1–3 rows
   with the existing operation. Compact backends retain their current arithmetic.
3. Admit results, update counters and enqueue frontier items in the original
   order. No frontier expansion occurs during an adjacency scan, so collecting
   a group before its distance evaluations must not change valid-query output,
   visited counts, heap ties, widening or filter eligibility.
4. Do not batch upper-layer greedy traversal or delta scan in this first slice.
   Do not combine the rejected query-validation or owned-summary prototypes.

## Correctness and performance gate

First compare four-row and existing distance bits for all F32 metrics at SIMD
boundaries/tails, repeated slots, noncontiguous slots and final rows. Check bad
slots, mismatched query dimensions and closed mappings. Validate existing raw
query finite/norm checks, corrupt edges, filtered/inactive traversal, scratch
reuse, widening, native compact paths and mapped/owned parity.

Then build from the copied binding entry and run saved-package Python tests
with `-o pythonpath=`. Use serial baseline/candidate/Qdrant warm and mixed trials
with the frozen corpora, original selected efs and all samples. Require result
IDs, score bits and stats to match because the traversal algorithm is intended
to remain identical. Measure write/flush/reopen controls as well. Only adopt on
verified end-to-end benefit; do not substitute the kernel diagnostic for the
strict per-cell Qdrant goal. Final M5/M6 remains unchecked until all gates pass.

## Measured outcome

The isolated candidate passes 147 targeted Mojo and 355 Python tests. Warm
strict parity changes 16→18/36; mixed changes 30→27/36, with all quality and
bit/stat checks passing. It remains unpromoted. Mixed phase tracing identifies
compaction retirement I/O under the writer lock as a substantial tail cost;
continue that independent hypothesis before reevaluating adoption.
[Full evidence](../benchmarks/2026-10-03-four-distance.md).

## Reevaluation after reclamation adoption

`7dd8647` independently adopts unlocked compaction reclamation with 81 targeted
Mojo, 21 related crash, 355 Python, C ABI and three examples passing. Reevaluate
the exact saved three-file scoring change on that baseline in a new isolated
tree and package. Both before and after must contain the adopted reclamation
change. Re-run the affected scoring tests plus the new reclamation ownership
and background-publication tests, full saved-package Python, then the unchanged
serial warm/mixed schedule. Keep the earlier failed trials and all new samples;
this is an independent experiment, not a replacement assessment.
