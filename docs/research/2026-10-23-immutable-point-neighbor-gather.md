# Scoped mapped adjacency gathering

**Carry this isolated candidate forward for investigation; production is not
changed.** In the same complete mixed batch, retained passes **21/36** strict
cells and the candidate **26/36**, with no pass-to-fail cells. Full fixed-graph
warm replay changes **11/36 → 12/36**, but includes one selective exact
pass-to-fail. Quality is 36/36 throughout. The candidate improves measured
search work, but does not satisfy M5/M6 or justify claiming overall acceptance.

## Source-grounded change

Pinned Qdrant revision is `21db2f3ff95d50de3a2b88a741312c056fd1762d`.
Its [`GraphLinksView::links`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/graph_links/view.rs#L238)
obtains a bounded adjacency iterator, and
[`search_on_level`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/graph_layers.rs#L107)
collects unvisited neighbors before admission and scoring. These pinned sources
and their Apache-2.0 license are included in the evidence. This identifies the
source pattern, not the exact build commit of the prebuilt Edge wheel.

Akasha previously located a neighbor range once, then reentered mapped scalar
and node-level accessors for each edge. The candidate adds a private synchronous
`_collect_neighbors` method to `HnswGraphAccess`. Its default implementation
contains the old checked loop. `HnswGraphView` specializes that operation:

- Keep `neighbor_range` unchanged, including source validation and complete
  edge-extent bounds before reading any neighbor.
- Hold the immutable mapping borrow for the whole gather. Copy edge IDs from
  the checked range using unaligned loads; no pointer, Span or callback escapes.
- Preserve each target's slot bound, exact level-field byte bound and level
  check, then apply the current visited epoch and append in the original order.
- Preserve partial output and the first error if a later edge is malformed.
  Mark visits only after scoring, as before.

Both beam traversal and upper descent use the operation. Only
`hnsw_storage.mojo`, `hnsw_view.mojo` and `hnsw_search.mojo` differ from the
132-file deferred-ID parent. Admission, live source/filter state, scoring,
authoritative rerank, query cancellation, ordering, ef, ownership and persisted
bytes remain unchanged. This is not the previously rejected borrowed-Span
factory, node-record copying, level-check removal or mapped-vector SIMD loop.

## Correctness

**104 cases in 14 modules pass**, including six new gather cases. They cover
owned/mapped equivalence at all graph levels, live visited changes, empty
ranges, copied results after close, invalid later neighbors, partial level
records, target-level validation before visited filtering, extreme offsets,
closed-owner precedence and identical partial output on failure. Existing
tests cover traversal, cancellation, filtering, native/packed vectors, stores,
v1 compatibility, segmented sources and ordinal admission.

The initial test compile failed on the absent method and an incorrectly typed
test List constructor. The corrected red test fails only on the absent method.
Subsequent fixture-cast and copied-helper import errors are retained and fixed;
the final 14-module run has zero failures or skips. Repeated runs are not added
to the unique case count.

The candidate also matches the existing independent pinned Rust oracles for
**98 search fixtures**, on scalar and batched-F32 paths, and **24 construction
fixtures / 2,467 ordered adjacency rows**. The Rust outputs are reused; the
candidate Mojo runs are fresh. These distinct-distance fixtures check control
flow, counts and construction, not native timing or equal-score kernel parity.

## Paired screens and full comparisons

Both two-order implementation screens retain all samples. The mixed screen
has 12 workers / 3,456 measured replies; all nine ANN corpus/mode combinations
improve QPS and p95 in both orders, with QPS gains of about 2–9%. The selected-ef
warm screen has 12 workers / 3,072 replies; it also records p95 regressions and
one ANN QPS regression. Neither screen substitutes for the full comparisons.

Full comparisons use production, retained, candidate and Qdrant in rotating
orders, three trials and all three corpora. The authorized Qdrant real-1536
correlated ef=128 applies; other parameters and Recall@10 ≥ .95, QPS ≥ Qdrant,
p95 ≤ Qdrant remain unchanged. Each warm trial uses its corresponding frozen
graph and all 12 original ef values. This is fixed-graph replay, not new index
construction, with the same disclosed timing scope as the
[local matrix](2026-10-23-immutable-point-local-matrix.md).

| Boundary | Production | Retained | Candidate | Quality per version |
|---|---:|---:|---:|---:|
| Full mixed | 18/36 | 21/36 | 26/36 | 36/36 |
| Full fixed-graph warm | 7/36 | 11/36 | 12/36 | 36/36 |
| Mixed combined write + flush | 9/9 | 9/9 | 9/9 | — |

Mixed gains over retained are uniform-128 all in trials 0 and 2, correlated
in trials 1 and 2, and independent in trial 1. No production or retained mixed
pass becomes a failure. Candidate still fails ten mixed cells: one uniform-128
all, all six uniform-1536 filtered, and all three real correlated cells.
Real correlated QPS/Qdrant remains only **.725–.761**.

Warm gains are uniform-1536 selective trial 0 and real-1536 all trial 0.
**Uniform-128 selective trial 0 regresses**: retained QPS/Qdrant 1.0712 and
p95/Qdrant .9479 become candidate .9478 and 1.1593. That exact path does not
call the changed adjacency operation, but its timing cause is not established;
it remains a failed gate. Candidate has 24 failed warm cells.

Three-trial median candidate/retained ratios describe, rather than replace,
the individual gates:

| Corpus / mode | Mixed QPS | Mixed p95 | Warm QPS | Warm p95 |
|---|---:|---:|---:|---:|
| uniform-128 / all | 1.0711 | .9287 | 1.0268 | 1.0722 |
| uniform-128 / correlated | 1.0874 | .9367 | 1.0838 | .9423 |
| uniform-128 / independent | 1.0824 | .9480 | 1.1506 | .8576 |
| uniform-1536 / correlated | 1.0591 | .9320 | 1.0496 | .9554 |
| uniform-1536 / independent | 1.0529 | .9373 | 1.0681 | .9436 |
| real-1536 / correlated | 1.0482 | .9647 | 1.0317 | .9572 |
| real-1536 / independent | 1.0336 | .9438 | 1.0314 | .9841 |

Warm uniform-128 selective median QPS is .9385 and p95 1.1856 of retained;
all selective and unfiltered observations remain archived. Earlier batches
with unchanged retained bytes passed different cell counts. Only paired
results within this batch support the comparisons above.

## Evidence and next work

Candidate native SHA-256:
`4835cc3b6929a82a36a0f42ed03488db6e13cdce2248c7e3e0b9d13922968ecf`.
Retained control remains
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`.

Across both screens and both full comparisons: **96 workers / 127,488 measured
responses / 96 exact reopens / 39 retained Arrow leases**. Every measured
response matches its expected IDs, F32 bits, stats and route. Warm runs add
12,864 stored exact preflight results and compare 5,328 warmup replies; the
144 mixed warmup return values are not compared. Independent auditors
recompute raw latency statistics, recall and all gates. Host VM/swap/thermal
observations accompany the full warm workers; they do not establish zero swap
or sustained nonresidency.

The [archive](2026-10-23-immutable-point-neighbor-gather.json.gz) includes all
132 candidate sources, the three prior files, source patch, tests, reference
oracles, pinned upstream source/license, plans, input identities, every raw
report and failure log, scripts, and the decision. Native binaries, databases
and workload NPZ are hashed rather than embedded. It contains **583 artifacts,
39,755,335 bytes**, SHA-256
`9a0580312b08b85eeef7598a9aea54fee88ddff35240c2be974c644608760d77`.
Extract its `files` as UTF-8, checking `metadata.sha256`, then run
`audit_archive.py ARCHIVE`. The replay uses no native engine or database and
reproduces all four audit output files byte-for-byte; archive-only verification
passes for all 583 artifacts.

Keep this candidate isolated while diagnosing the warm regression and reducing
the remaining search cost. Its changed traversal still needs proportionate
broader integration validation before final adoption; the parent's earlier
complete CPU/Python/crash results are not claimed as a new full candidate run.
External-client and sustained nonresident gates remain open. Native Linux is
deferred by the user, not passed. Production remains `a6822c3`; M5/M6 remain
incomplete.
