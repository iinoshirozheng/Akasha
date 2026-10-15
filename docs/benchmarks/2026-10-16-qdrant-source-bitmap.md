# Slot-addressed current-source checks

Segmented HNSW now checks immutable-base source eligibility through a bitmap
indexed by the graph's physical slot. The shared ID-to-source map still owns
replacement/deletion transitions; the same operations maintain the bitmap.
Delta admission still uses the ID map. No search breadth, score arithmetic,
planner threshold or durable format changes.

## Evidence and implementation

Pinned Qdrant `raw_scorer.rs::NotDeletedChecker` checks deleted point/vector bits
by internal point offset. Akasha instead hashed public IDs on every source
admission, including immutable-base checks. The new projection follows the
internal-slot approach while preserving Akasha's base/delta authority rules.

The bitmap is created once when adopting a validated owned or mapped base, and
replaced when promoting a new base. Existing shared admission views observe
updates through the same Arc-owned state. The bitmap's cached cardinality
replaces the separate base-source count; it adds one bit per physical base slot
and has no per-query construction. Overlay validation checks the domain, each
map-to-bit binding and total cardinality, including orphan-bit detection.

Five-second baseline samples also show mapped metadata reads, eligibility and
heap operations consuming substantial time. Sampling is not precise elapsed
cost attribution; compiler-inlined hash work is not separately identifiable in
those captures. This patch is justified by its controlled comparisons below,
not by assigning a percentage of samples to hash tables.

## Validation

- Segmented HNSW: 21/21. Added owned/mapped lifecycle coverage crosses bitmap
  word boundaries with negative public IDs, historical slots, replacement,
  deletion, reinsertion and admission views created before mutations. A
  same-cardinality wrong-bit injection verifies validation checks membership.
- Overlay cache (5), base recovery (4), incremental collection (17), point
  projection (3) and rebuild publication (18): 47/47.
- Rebuilt Python extension: 387 Python/distributed/service tests pass, one skip.
  Rebuilt C library/client also passes.
- Earlier unaffected durable-format, crash and actual-GPU evidence remains
  applicable. This report does not claim new runs of those suites.

## Saved-graph diagnostic

Using `benchmarks/qdrant_saved_graph.py`, all three original trial-0 corpora
retain their graph bytes, oracle, queries and smallest passing ef. Public Python
queries are warmed and measured seven times. Serial old/new/old and new/old/new
orders preserve all result digests, recall and per-query counters in all twelve
cells. No tests/builds overlap timing.

All six filtered ANN cells improve QPS and p95 in both orders. QPS improves
4.0–24.2% in old/new/old and 5.6–14.7% in the reverse order. Uniform 128D all
also improves in both orders (10.1%, 12.6%), as does uniform 1536D all (3.0%,
4.2%). Real 1536D all is effectively unchanged: +0.4% then -0.5%; its reverse
p95 regresses 2.1%. Exact selective controls vary despite bypassing this code.
All controls, slow samples and regressions are retained.

Baseline Python binary SHA-256:
`b331c3e38773160ed94ac4cc5df7428bd9bcf4b542fa3973d54f14264ea02c87`.
Candidate:
`91c98702872ff5fc41aa4faaf5979b8bbf602aa40391230b732daf80a027058e`.

## Fixed L2 diagnosis

A separate probe of the unchanged 8,192-point, 64D fixed L2 quality corpus
finds every base-level node reachable from the entry. All 13 missed top-10
neighbors at ef=64 were never scored. They have 19–60 incoming links, and
6–29 of their parents were scored; scoring a parent does not imply its adjacency
was expanded before beam termination. This localizes the misses to graph search
coverage, rather than final result truncation. It does not establish a new
construction or search algorithm that fixes the gate.

Diagnostic ef=64/96/128 recalls are .9458333333/.9791666667/.9875, with mean
distance counts 2126.3/2815.9/3401.4. The production/fixed gate stays at ef=64
and .95; the larger diagnostic ef values are not accepted fixes. The native
Qdrant reproduction of the same .9458333333 failure also remains diagnostic.

## Fresh acceptance

Three fresh serial trials per corpus complete all build/reopen workers. Matched
recall passes **36/36**, while strict speed passes **5/36**, so overall acceptance
remains **FAILED**. All filtered ANN cells still fail. The unchanged workload is
8,192 points, 64 queries, k=10, seed12345, Dot/F32, with the symmetric ef grid
`10,16,24,32,40,48,64,96,128,256,512,1024`. Each engine selects the smallest
passing ef independently of timing; no thresholds were changed.

| Corpus | Filter | Median QPS A/Q | Median p95 A/Q | Passing trials |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 0.498 | 1.908 | 0/3 |
| uniform-128 | correlated | 0.483 | 1.878 | 0/3 |
| uniform-128 | independent | 0.564 | 1.587 | 0/3 |
| uniform-128 | selective | 0.990 | 0.900 | 1/3 |
| uniform-1536 | all | 0.934 | 1.045 | 0/3 |
| uniform-1536 | correlated | 0.620 | 1.641 | 0/3 |
| uniform-1536 | independent | 0.626 | 1.519 | 0/3 |
| uniform-1536 | selective | 0.941 | 1.141 | 1/3 |
| real-1536 | all | 0.984 | 0.986 | 1/3 |
| real-1536 | correlated | 0.427 | 2.036 | 0/3 |
| real-1536 | independent | 0.683 | 1.368 | 0/3 |
| real-1536 | selective | 1.108 | 0.893 | 2/3 |

The previous four-row-scoring matrix passed 6/36 speed cells; it is a separate
snapshot, not a paired causal baseline. This run has one passing real-data all-mode ANN
cell. Its other four passes are planned exact selective queries, which do not
use the source bitmap. The paired saved-graph improvements and the failed fresh speed
gates are distinct evidence; neither offsets the other.

These are resident macOS ARM64 runs. Native Linux, concurrent maintenance,
non-resident and full type/capacity evidence remain outstanding. The fixed L2
quality gate also remains failed. Source parity and targeted tests do not
complete M5/M6. Raw run directory:
`.build/qdrant-alignment/source-bitmap/`.


[Raw profiles, comparisons, validation logs and source patch](results/2026-10-16-qdrant-source-bitmap.json.gz)
(92 files, 5,405,571 bytes; SHA-256
`e4bd6668695297dc4aef81c273cfbd374eafc6f7bbcda338f3627fcf351d33f2`).
