# Filtered search after publication lock separation

The retained [query-lock candidate](2026-10-20-immutable-point-query-lock.md)
still fails six uniform-1536 correlated/independent speed cells. Both engines
use frozen ef=512. Akasha executes ANN in every such cell. A new phase build
and uninstrumented native samples locate the remaining work in base-graph
access and scoring. This is diagnosis, with no new product change or acceptance
result. The last strict mixed result remains production 25/36, prior 22/36,
query-lock candidate 25/36; production source stays `a6822c3`.

## Pinned implementation comparison

All references are extracted from Qdrant commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d` and hash-verified:

- [`GraphLayersBase::search_on_level`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/graph_layers.rs#L108)
  collects unvisited links, filters before scoring, applies the per-expansion
  limit, and marks scored nodes visited. Akasha follows these boundaries;
  repeated rejected-neighbor checks are not unique visited points.
- [`FilteredScorer::score_points`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/point_scorer.rs)
  compacts eligible IDs in a reusable buffer, then scores the retained batch.
  [`MetricQueryScorer::score_stored_batch`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/vector_storage/query_scorer/metric_query_scorer.rs)
  keeps query/storage context and iterates borrowed dense rows.
- [`GraphLinksView`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/graph_links/view.rs)
  validates serialized sections when creating its borrowed view. Akasha's
  mapped node ID, level and current accessors instead repeatedly locate/check
  the node and mapping during traversal, filtering and score-result creation.
- Qdrant's unquantized search omits an additional authoritative rescore.
  Akasha's established tests permit stale graph rows while current authoritative
  values change; removing reranking would violate that contract. This work
  retains it and measures it separately.

The Edge runtime hash and its executed graph-search stacks are checked. The
pinned package-version source is not a wheel build attestation.

## Source phases

The complete 132-file candidate is copied unchanged. Only the diagnostic
`collection.mojo` and `segmented_hnsw.mojo` add clocks/counters. Collection
clocks measure query-lock wait, validation, filter evaluation, preparation,
search core and result cleanup. Source clocks split collector setup, base
search, base merge, delta search, delta statistics, delta merge and tail;
authoritative rerank has a separate timer. No per-vector clocks are added.
All printing happens after the query lock is released.

Base search includes admission construction, source search and source-statistics
collection; it is not an isolated arithmetic timer. Delta search likewise
includes its admission construction. Source distance/visit/rejection sums and
retained candidate counts are checked against every public ANN statistic.
Every phase sums back to its enclosing interval; every recorded route remains
ANN or the preexisting planned-exact selective route.

The diagnostic compiles with Mojo `1.0.0 (ed45d567)`. Six serial workers run
two fresh copies of each corpus's fixed 32-block mixed workload. All **1,728
timed responses** match the retained native candidate in IDs, F32 score bits,
statistics, execution, recall and oracle. All **six exact reopens and six Arrow
leases** pass. All **18 warmup clock traces** are retained separately; their
return values are not compared. No samples are omitted and no builds, tests,
sampling or compression overlap these workers.

Uniform-1536 trial medians, microseconds:

| Mode | Trial | Core | Base search | Delta search | Rerank |
| --- | ---: | ---: | ---: | ---: | ---: |
| correlated | 0 | 1230.0 | 911.0 | 31.0 | 255.0 |
| correlated | 1 | 1249.0 | 919.0 | 30.0 | 254.0 |
| independent | 0 | 1241.5 | 925.0 | 25.0 | 260.0 |
| independent | 1 | 1243.5 | 921.5 | 24.0 | 258.5 |

Summing the intervals across both trials, base search accounts for **73.05%**
of correlated and **73.02%** of independent core time. Rerank is about one fifth.
The delta is much smaller, although occasional graph-path delta queries make
its total fraction greater than a ratio of medians would imply. Do not add
phase medians or infer total fractions from their ratios.

Trial 0 means show about 1,700 base distance evaluations, 512 base candidates,
205 delta candidates and 19,200 base rejection checks per filtered query.
The rejection count includes repeated checks, not that many distinct nodes or
discarded distance computations. All three corpora and all modes remain in the
raw traces and summaries. Clock resolution is 1 µs.

Diagnostic native SHA-256:
`f62ee3abc6cde2f7de4a9c3cde0a1dae94b131dddac09d7df0588d2abb31981c`.

## Native Akasha and Qdrant samples

Four serial five-second `sample` captures use the uninstrumented retained
Akasha binary and Qdrant Edge 0.8.0. Each worker opens its own fresh copy and
repeats the two initial-block queries for one filtered mode (ordinals 3 and 4).
Request construction and search are inside the sampled loop. These are
representative initial-state captures, not the full mixed update sequence.

All four workers and samplers exit zero. All **eight preflight and eight
postflight responses** match their respective frozen engine results in IDs,
F32 score bits and available statistics. Repetitions are not independent
quality observations or performance samples. Qdrant's public Edge API does
not expose per-query candidate/fallback counters.

Exclusive observations are computed by subtracting immediate child counts
from each stack node. Every thread's exclusive counts sum to its root sample
count. Akasha's active query thread is `com.apple.main-thread`; Qdrant's is
`edge-search-0`. Their denominators are separate; the waiting Qdrant caller and
Akasha worker-pool waits are not mixed into the active-thread percentages.

| Akasha mode | Thread observations | Mapped four-row score | Mapped single-row score | Authority pair score | Metadata/readiness access | Source admission | Heap methods |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| correlated | 3784 | 13.40% | 12.66% | 14.53% | 13.95% | 7.37% | 7.61% |
| independent | 3804 | 14.01% | 12.96% | 14.04% | 11.88% | 8.07% | 7.73% |

Metadata/readiness includes `MappedFile.byte_at`, `_node_record`, `_read_u16`,
`_read_u64` and `is_current`. It does not mean all of that work is removable.
Generic search/scorer frames and other symbols remain in the complete tables.

| Qdrant mode | Search-thread observations | Dense raw scorer | Appendable raw scorer | Filter partition | Batched filter checks | Graph-link accessor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| correlated | 3692 | 55.07% | 4.33% | 11.86% | 5.93% | 0.22% |
| independent | 3685 | 50.96% | 4.23% | 14.95% | 6.76% | 0.24% |

Functions have different inlining and responsibilities across engines. These
percentages locate sampled work; they are not comparable operation counts,
elapsed-time attribution, or projected speedups. Qdrant's stack confirms its
dense graph scorer and appendable scan in this executed runtime.

The initial analyzer's heap category also matched type names in generic
function arguments. It was corrected to match the actual heap function prefix.
The initial script/output and correction are retained. Raw captures, thread
totals, binaries and other categories were unchanged.

## Next implementation boundary

The next hypothesis is to gather one **copied node-metadata record** and reuse
its ID, level and current fields through filtering and score-result creation.
Preserve checked open/slot/range access, first-error ordering, target-level
validation, source eligibility, arithmetic, visitation, counters and public
direct-access behavior. Copying scalar metadata must not expose a raw borrowed
pointer or cache mutable state across operations. This hypothesis is not yet
implemented or claimed faster.

Historical evidence rules out repeating the same previous variants:

- [Base-level-only level-read skipping](../benchmarks/2026-10-16-hnsw-base-level-probe.md)
  already passed boundary tests but had inconsistent speed and was not adopted.
- [Adjacency-range metadata reuse](2026-10-14-mapped-neighbor-metadata.md),
  broad accessor inlining and the [header-byte removal probe](../benchmarks/2026-10-02-stream-fingerprint.md)
  also lack acceptance.
- [Raw borrowed adjacency spans](../benchmarks/2026-10-02-hnsw-neighbor-ranges.md)
  were rejected because the compiler allowed owner close/mutation before reuse.

No product source or contract changes in this diagnosis. Existing correctness
results for the identical query-lock source remain applicable; no fresh full
CPU/Python/crash/GPU result is claimed. All remaining warm/mixed/concurrent,
capacity, integration/example and native Linux requirements remain open. The
three frozen Qdrant recall failures are retained without retuning or exclusion.

The [archive](2026-10-20-immutable-point-source-phases.json.gz) contains full
source/diagnostic copies, drivers, compiler/build identities, six complete mixed
reports and traces, all four raw sample captures and pre/postflight audits,
corrected and initial analysis, pinned Qdrant sources with LICENSE, and prior
research references. Frozen plans/workloads use the verified parent evidence
chain. Native binaries, copied databases and workload NPZ files are excluded.
All embedded text hashes and unchanged parent-source identities are verified.

Archive: **391 text artifacts, 1,371,349 bytes**, SHA-256
`7784854b5091c9c1e03cb0595d72c7f83ef78d341154a43ca9e830924826e599`.
