# Filtered graph scoring versus delta rejection

An isolated diagnostic on production `96e05e2c` adds two print statements at the
existing source-statistics merge in `_collect_allowed_candidates`. It does not
alter traversal, scores, counters, admission or public return values. Diagnostic
binary is `eac25847408ba3e9a39b5fc9c7ea135ab72444b936b14837b74dc87ab2e4f63a`.

Two fresh copies of the fixed real-1536 database run correlated ef32 and
independent ef40, each with the existing 67 queries. All **134 queries** match
the [uninstrumented captures](2026-10-14-filtered-ann-native-sample.md) in IDs,
F32 score bits, recall and every public statistic. Every recorded source sum
matches the corresponding public counter. The instrumented build compiles with
Mojo1.0.0; no new full regression suite or speed gate is claimed for print-only
diagnostics. Production source and binary are unchanged.

Means over the existing 64 measured-set queries, excluding the three warmup
ordinals from these summaries only (all raw records retained):

| Mode / source | Upper visits | Level-0 visits | Distances | Filtered rejections | Retained |
| --- | ---: | ---: | ---: | ---: | ---: |
| Correlated / base graph | 64.406 | 875.891 | 940.297 | 683.781 | 32 |
| Correlated / delta scan | 0 | 819 | 204.750 | 614.250 | 32 |
| Independent / base graph | 62.406 | 1,043.609 | 1,106.016 | 816.219 | 40 |
| Independent / delta scan | 0 | 819 | 204.750 | 614.250 | 40 |

All inactive-rejection counters are zero and all widening counts are zero in
these observations. For every query, base distances equal upper+level-0 visits;
delta distances+filtered+inactive rejections equal delta visits. Thus the base
scores every first-seen level-0 node before admission, whereas the delta scan
already avoids scoring rejected rows. Dividing the sums gives **78.07% and
78.21%** of base level-0 scores subsequently rejected, and **75%** of delta rows
rejected without a distance calculation.

This is not proof that those graph distances are dispensable: rejected nodes
currently maintain traversal connectivity and its retained radius. Source
eligibility also includes base/delta ownership, so the base rejection count
must not be described as metadata-only rejection. The merged public rejection
counter would overstate the potential graph-score saving by including unscored
delta rows. No latency benefit is claimed from this diagnostic.

The next investigation is predicate-aware neighborhood expansion that preserves
connectivity while scoring fewer rejected bridge nodes. The
[ACORN paper, section5.3](https://arxiv.org/html/2403.04871v1#S5.SS3), expands
one/two-hop neighborhoods before predicate filtering. Its graph-construction
assumptions differ from Akasha's existing pruned graph, so effectiveness and
recall must be demonstrated locally. Local Qdrant revision
`74f3e85b9473c62560006c043e13737ce6b48412` provides another two-hop implementation
in `graph_layers.rs:154`; this is not the pinned Edge0.8 benchmark revision, and
is not evidence about that comparator's executed algorithm.

Preserve the established `search_layer` bridge/counter contract. Any intentional
new traversal requires separate behavior tests, explicit counter semantics and
quality gates; it cannot reuse the representation experiments' identical-visit
claim or silently rewrite expected results. No such algorithm is adopted here.

[All source, build identity, workers and per-query source counts](2026-10-14-filtered-source-counts.json.gz):
161 files,332,589 bytes; SHA-256
`2ea2a5eb71bc6b6b720d722c703c2610bfb057764a2fb38a6a35003a3ac97d48`.
Archive and every embedded hash were verified.
