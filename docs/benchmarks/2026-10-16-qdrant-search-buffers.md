# Qdrant traversal buffer reuse

Akasha now follows Qdrant's reuse of neighbor and score buffers during HNSW
traversal. Search results, scores and per-query counters match the prior binary
on all twelve saved-graph workload cells. This is an implementation improvement;
it does not close the failed Qdrant speed acceptance or fixed L2 recall gate.

The pinned upstream `graph_layers.rs::search_on_level` creates `points_ids`
outside the candidate loop and clears it between expansions.
`search_entry_on_level` reuses its caller's link buffer.
`point_scorer.rs::FilteredScorer::score_points` filters the ID buffer in place
and retains `scores_buffer` capacity. Akasha previously allocated a fresh
neighbor list, filtered list and scored list for every expanded node.

A five-second macOS `sample` capture of the old binary's public Python query
path collected 4,200 main-thread samples. Under `_collect_candidates`, sibling
allocation and UInt32-list reallocation branches accounted for 339 and 296
samples respectively. This identifies allocation overhead, without treating
sample counts as precise elapsed-time attribution. The raw capture is
`.build/qdrant-alignment/traversal-profile/before.sample.txt`.

The production change moves neighbor/score allocations outside the traversal
loops, compacts eligible IDs in place, applies the batch limit after filtering,
and clears buffers without releasing capacity. Rejected/truncated nodes retain
the upstream visited-state behavior. The obsolete construction-only option to
refill rejected neighbors was also removed; production already disabled it.

Validation includes 98/98 extracted upstream search fixtures with identical
IDs, scores and distance counts; nine scorer/search boundary tests including
empty-batch reuse; two mid-search cancellation tests; and fifteen neighbor
selection tests. The source-backed construction oracle continues to compare
24 cases and 2,467 adjacency rows. Logs live under
`.build/qdrant-source-reference/reused-buffers/` and
`.build/qdrant-source-reference/build-reused-buffers/`.

## Saved-graph measurement

`benchmarks/qdrant_saved_graph.py` loads either native binary without replacing
the package. Each corpus uses its existing trial-0 graph, workload, oracle and
smallest previously passing Akasha ef. Each separate process warms every query,
then runs seven repetitions. Request construction and public Python search are
timed; validation and counters are outside timing. Old/new/old processes ran
serially, with no concurrent builds or tests.

Ratios below compare the new run to the arithmetic mean of the two old runs.
These are diagnostics on retained graphs, not three fresh acceptance trials.

| Corpus | Filter | QPS new/old | p95 new/old |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.079 | 1.161 |
| uniform-128 | correlated | 1.164 | 0.921 |
| uniform-128 | independent | 1.252 | 0.800 |
| uniform-128 | selective | 1.026 | 0.900 |
| uniform-1536 | all | 1.209 | 0.719 |
| uniform-1536 | correlated | 1.187 | 0.744 |
| uniform-1536 | independent | 1.181 | 0.760 |
| uniform-1536 | selective | 1.071 | 0.876 |
| real-1536 | all | 1.060 | 0.959 |
| real-1536 | correlated | 1.119 | 0.886 |
| real-1536 | independent | 1.070 | 0.976 |
| real-1536 | selective | 1.028 | 1.151 |

All result digests and every captured query counter agree across each old/new/old
triple. QPS increases in this run, but two p95 ratios regress. Selective cells
use exact search and do not exercise the changed traversal; their variation
shows why this diagnostic is insufficient to establish a universal speedup.
At the time of this diagnostic, the [full warm acceptance](2026-10-15-qdrant-alignment-warm.md)
reported speed 3/36, FAILED. The subsequent
[four-row scorer run](2026-10-16-qdrant-score-batch.md) records a new fresh-build
comparison: speed 6/36, still FAILED.

Raw latency arrays, binary hashes and equality checks are in
`.build/qdrant-alignment/traversal-profile/*-{before-0,after,before-1}.json`
and `aba-summary.json`. Reproduce a cell group with:

```sh
PYTHONPATH=python:. pixi run python -m benchmarks.qdrant_saved_graph \
  --corpus .build/qdrant-alignment/warm-matrix/uniform-128 \
  --kernel python/akashadb/_kernel.so --output /tmp/saved-graph-new.json
```
