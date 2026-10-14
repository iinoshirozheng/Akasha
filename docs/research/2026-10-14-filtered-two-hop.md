# Filtered two-hop traversal experiments — rejected

Three isolated variants were tested against production `96e05e2c…`. None is
adopted. The first breaks two existing historical-source bridge cases. Two
corrected variants preserve those cases and improve real filtered recall, but
both substantially increase traversal work and latency. Production source and
Python binary remain unchanged; M5/M6 are not complete.

The preceding [source counters](2026-10-14-filtered-source-counts.md) showed
about 78% of base level-zero scores subsequently rejected by admission. This
does not mean that dropping them is safe or faster. Prepared-query reranking
was also considered, then ruled out as a repeat of the rejected experiment in
[the October 2 report](../benchmarks/2026-10-02-prepared-exact.md).

## Design and correctness

The experiment adds a separate level-zero helper; the original `search_layer`
implementation remains unchanged. It collects direct neighbors, expands
rejected neighbors by one further hop, and batches admitted scores through the
existing four-vector kernel. Separate generation stamps allow a rejected
second-hop node to expand if subsequently encountered as a direct neighbor.
Scratch grows lazily and retains the existing wrap and prepared-range checks.

The [ACORN paper, section 5.3](https://arxiv.org/html/2403.04871v1#S5.SS3)
describes expanded neighborhoods and truncation after predicate filtering. Its
construction omits standard HNSW pruning; Akasha's existing graph does not.
The local Qdrant reference provides a related two-hop implementation at commit
`74f3e85b9473c62560006c043e13737ce6b48412`. That is **not** the measured Edge
0.8.0 revision. These experiments are adaptations, not claims to reproduce
either implementation or its performance guarantees.

| Variant directory under `.build/m5-resume/` | Outcome |
| --- | --- |
| `filtered-two-hop` | 77 selected Mojo cases: 75 passed, two established segmented result cases failed; no candidate binding build |
| `filtered-two-hop-source-bridges` | Six new core cases and all 18 existing segmented cases passed; binding built; complete warm comparison rejected |
| `filtered-two-hop-bounded` | Same 24 cases plus one bounded-expansion case passed; binding built; complete warm comparison rejected |

The first version loses access through four consecutive superseded base nodes,
returning point 20 instead of 24 in both owned and mapped overlay tests. The
correction keeps inactive and superseded source nodes in the scored frontier;
only current metadata-rejected nodes use unscored two-hop expansion. Source-only
admission uses the original algorithm. Neither existing expected answer changes.

The final version additionally limits each expansion's score queue to existing
`graph_m0()`, keeping all direct links and stopping second-hop collection before
marking unprocessed slots. A regression fails against the preceding version
(eight results versus seven), then passes with the limit; it also verifies that
a later direct discovery can still reach a slot beyond the earlier limit.

The new algorithm counts each first encountered slot once and counts actual
distance evaluations separately, as the existing delta scan already does.
Filtered ANN IDs and traversal statistics can change. Common result IDs retain
identical F32 score bits; all untouched warm rows retain identical IDs, bits and
stats. Every query is checked against the frozen independent exact oracle.

## Fixed real-query diagnostics

Each built variant runs all 67 correlated and 67 independent queries, including
three warmups per mode. Means below use the same 64 measured ordinals. No timing
claim is derived from these counters. Upper traversal and rerank counts remain
unchanged; reranking uses 64 and 80 candidates respectively.

| Mode / variant | Recall@10 | Mean base visits, including delta | Mean distance evaluations, including upper/delta |
| --- | ---: | ---: | ---: |
| Correlated / production | .953125 | 1694.891 | 1145.047 |
| Correlated / source bridges | .998438 | 8192.219 | 2804.453 |
| Correlated / bounded | .995313 | 7091.297 | 2430.984 |
| Independent / production | .965625 | 1862.609 | 1310.766 |
| Independent / source bridges | .998438 | 8503.297 | 2907.688 |
| Independent / bounded | .998438 | 7850.953 | 2684.078 |

Preserving result quality does not establish an optimization: even the bounded
version performs about twice as many distances as production. Counting only
avoided scores on rejected nodes would conceal its larger overall search.

## Complete native warm comparisons

Each built variant has its own contemporaneous baseline and all **27 workers**:
three rotating before/after/Qdrant triples on each fixed corpus. Each matrix
retains 6,912 timed query audits and 324 warmups. Corpora, K, ef, filters, oracle,
query construction and timing boundaries are unchanged. Builds, tests,
benchmarks and compression run serially. No trials are excluded.

| Variant | Quality before / after | Strict speed before / after | Pass→fail / fail→pass |
| --- | ---: | ---: | ---: |
| Source bridges | 36/36 / 36/36 | 21/36 / 22/36 | 2 / 3 |
| Bounded | 36/36 / 36/36 | 21/36 / 19/36 | 4 / 2 |

Strict speed requires both QPS ≥ Qdrant and p95 ≤ Qdrant in each qualifying
cell. Increased aggregate pass counts cannot offset failures. The first set's
pass→fail cells are uniform-1536 selective trials 0 and 2. The bounded set loses
uniform-128 selective trials 1 and 2 and real selective trials 0 and 1. These
unchanged-path fluctuations are retained without attributing their cause.

The intended real filtered cells regress in every trial. Values are the median
and full range of the three paired ratios; lower p95 and higher QPS are better.

| Variant / mode | QPS after/before | p95 after/before |
| --- | ---: | ---: |
| Source bridges / correlated | .251 (.246–.275) | 3.843 (3.031–3.859) |
| Source bridges / independent | .268 (.263–.280) | 3.469 (3.224–3.671) |
| Bounded / correlated | .320 (.296–.334) | 3.073 (3.014–3.472) |
| Bounded / independent | .317 (.310–.330) | 3.111 (2.968–3.136) |

Both variants fail all six intended real filtered comparisons against Qdrant.
They are rejected on this complete warm evidence. Full Python, mixed, capacity,
Linux, C ABI, crash and GPU suites were not run for these rejected algorithms;
included unused drivers are not successful validation evidence.

## Reproducibility and remaining work

The archive retains all three complete source snapshots, source deltas, new and
executed existing tests, build commands, source/binary hashes, every raw worker,
latency, quality/counter diagnostic and failed attempt. Initial test-only API
mistakes (`Float32.bitcast`, then `rebind`) are preserved. A misspelled segmented
test filename stopped a driver after four passing files; only the remaining
files were then run. An initial warm launch lacked `PYTHONPATH` and launched no
workers; the corrected driver and initial failure are both retained.

Source-bridge Python SHA-256:
`6aa97ae7e7fa35fdc568dbd1e2b61c1b0893a46f6c9d124e7ddea5fe9a60a09b`.
Bounded Python SHA-256:
`9c61ddb34810e61e572f4bdab107141028fe024b35b6641303f9ae0ff634d16a`.
Production remains:
`96e05e2c248b2db7121ca5f0ca30bbe5ea392cc599ad1694b3e93e71466e758c`.

Stop this two-hop branch on the current graph. Further work should preserve
the original traversal and inspect remaining per-node costs before another
algorithm change. Mapped-authority adoption and the outstanding warm, mixed,
HTTP, capacity and native-Linux performance requirements remain unresolved.

Raw evidence: [immutable archive](2026-10-14-filtered-two-hop.json.gz).
It contains **1,117 files, 4,275,883 bytes**; all embedded hashes were verified.
SHA-256: `e7960f76658702e6b6b3fa35d6d4073ee97f9915c2a0de2baa97a2446187a1a3`.
