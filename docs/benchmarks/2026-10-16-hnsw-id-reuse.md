# Checked ID reuse in HNSW scoring — rejected

The candidate removes one checked `graph.id_at` call per scored point but does
not improve all public workloads. In real-1536 independent-filter trials 1 and
2, QPS falls 3.65% and 3.54%, while p95 rises 10.17% in both. Production source
and the installed Python kernel were restored to `3dafe2a`. No speed gate closes.

`score_points` already reads an admitted point's public ID before scoring.
The candidate stores that ID in the existing result buffer and fills its score
later, rather than loading the ID again after distance evaluation. It keeps
filter-before-cap order, input compaction, duplicate handling, finite checks,
scalar/four-row arithmetic, cancellation, and distance/rejection counts. It
adds no owner or cache. This follows the retained-ID principle in pinned Qdrant
`FilteredScorer::score_points`, while keeping Akasha's public-ID tie ordering.

The isolated and integrated 20-case probes cover dynamic/scalar plus three
F32 metric paths and caps 0/1/4/5/20. IDs, slots, scores, compaction and counters
match; nine scored points reduce ID reads 19 to 10. This work-count reduction
alone is not a timing benefit. Existing targeted validation passes 55 Mojo
cases, plus all 98 upstream-source fixtures on scalar and batched paths. The
Python extension builds. No full CPU, Python suite, C, crash or GPU rerun is
claimed for this rejected candidate.

## Saved-graph paired timing

Three alternating pairs per corpus, 31 passes over the original queries, same
saved graphs/workload/oracles and frozen ef values. Separate serial processes
load before/after libraries. Both versions include the same per-request thread
CPU clock instrumentation. No builds, tests or compression overlap timing.
All 36 paired cells have identical result digests, recall and distance counts.
These are resident macOS ARM64 diagnostics, not fresh-build Qdrant acceptance.

Ratios are after/before medians of three retained pairs; QPS above one is better,
p95 and thread CPU below one are better. Raw individual regressions remain.

| Corpus | Filter | QPS | p95 | Thread CPU |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 1.0409 | 0.9465 | 0.9607 |
| uniform-128 | correlated | 1.0079 | 0.9972 | 0.9923 |
| uniform-128 | independent | 1.0176 | 0.9693 | 0.9828 |
| uniform-128 | selective | 0.9959 | 1.0137 | 1.0038 |
| uniform-1536 | all | 1.0121 | 0.9775 | 0.9879 |
| uniform-1536 | correlated | 0.9999 | 1.0093 | 0.9999 |
| uniform-1536 | independent | 1.0168 | 0.9794 | 0.9834 |
| uniform-1536 | selective | 1.0085 | 0.9516 | 0.9915 |
| real-1536 | all | 1.0233 | 0.9680 | 0.9774 |
| real-1536 | correlated | 1.0371 | 0.9260 | 0.9656 |
| real-1536 | independent | 0.9646 | 1.1017 | 1.0352 |
| real-1536 | selective | 1.0035 | 0.9960 | 0.9968 |

Uniform low-dimensional unfiltered QPS improves in all three pairs, but the
real independent-filter regression prevents adoption. Selective exact cells
are unchanged-path controls; their variation is not credited to this change.
No thresholds, ef settings, data formats, planner rules or graph bytes change.

Before Python SHA-256: `358cb6212d9caa347fd6ef055aea45fc4f0052cde1f393c9bcfa92dcb3d339b1`.
Rejected Python SHA-256: `d5ed9d1c3d15ad643f8d4a1dc916033a767521a9c90e769b68c89b88e437cb95`.
The before hash is verified again after restoring the installed library.

The [frozen evidence](results/2026-10-16-hnsw-id-reuse.json.gz) contains
71 files, 970,543 bytes, including all pair reports, source
snapshots/diff, probes, validation output and the restore decision. Embedded
hashes verify. Archive SHA-256:
`a69605f265ace29cf0560009baef7df54151aee797c7fb67ac13cf35c43561b6`.
