# Heap move probe and current native profile

The heap move prototype is **not adopted**. Production source and the installed
Python library were restored to `5f6d4dd` before profiling. That parent checkpoint's
fresh acceptance was warm speed 4/36, mixed speed 10/36, write+flush 5/9, and fixed
quality 3/4. These diagnostics do not replace those failed gates.

## Rejected heap prototype

Qdrant's pinned `search_context.rs` uses Rust `BinaryHeap` and its fixed-length
queue uses `peek_mut` for root replacement. Rust's
[heap source](https://doc.rust-lang.org/src/alloc/collections/binary_heap/mod.rs.html#792-829)
keeps the displaced item outside the array while moving parents/children into
its position. This probe applies that movement pattern to Akasha's existing
16-byte trivial entries, with ordinary checked List accesses and no uninitialized
storage. Comparisons, distance/ID/slot ties, root replacement, capacity reuse,
errors and public methods remain unchanged. The prior rejected official-Mojo-heap
adapter is not reintroduced.

Two added independent-model tests exercise changing result capacity across
singleton/odd/even/tree-depth boundaries and interleaved candidate pop/refill.
The 11 heap, 10 scratch, 14 layer, 15 neighbor-selection and two cancellation
tests pass: **52 total**. Extracted Qdrant traversal matches **98 fixtures on
both scalar and batched F32 paths**. The Python extension builds successfully.
An initial runner requested nonexistent `test_hnsw_search.mojo`; its error is
retained, followed by the successful actual `test_hnsw_search_layer` run.

Serial old/new/old and new/old/new processes replay the same original graphs,
workloads, ef values and seven public Python query passes. All twelve cells in
each order preserve result digests, recall and every per-query statistic. No
build, test or compression overlaps the timings.

| Corpus / mode | QPS after/before, ABA / BAB | p95 after/before, ABA / BAB |
| --- | ---: | ---: |
| Uniform 128 / all | .980 / .952 | 1.002 / 1.059 |
| Uniform 128 / correlated | 1.018 / 1.019 | .976 / .972 |
| Uniform 128 / independent | 1.020 / .977 | .965 / 1.113 |
| Uniform 1536 / correlated | 1.013 / .998 | .989 / 1.007 |
| Real 1536 / correlated | 1.014 / 1.016 | .979 / .981 |
| Real 1536 / independent | .967 / .999 | 1.039 / 1.014 |

The small correlated gains do not justify the low-dimensional regression.
Untouched exact selective controls also vary; uniform 128 reverse-order QPS
is .930 and p95 1.337. All samples remain in the archive. No fresh-build Qdrant
matrix, Python correctness suite or construction oracle is claimed for this
withdrawn variant. Its source and new tests are preserved as a patch only.

## Unchanged-parent sampling

Five serial ten-second native `sample` captures use accepted `5f6d4dd`, whose
Python library SHA-256 is
`fedc10583ed5d522bcf474493e1dda30d2434f3757f711d9ac1a0b2d122b95ad`.
Each worker clones a closed original trial-0 database and keeps the original
selected ef. Python query lists are prepared before capture; request construction
and public search are sampled. All samplers/workers exit successfully. Each
capture's 67 pre/postflight IDs, F32 score bits, recall and statistics agree:
**335 pre/post pairs**. Repeated profiling queries are not independent recall
observations or acceptance timings.

The table reports collapsed top-of-stack observations divided by main-thread
samples. Other threads contain no Akasha symbols and their waits are excluded.
Symbol categories match the function-name prefix, not parameter type names;
merged traversal symbols mentioning `HnswHeapItem` are not counted as heap work.
The collapse threshold omits functions with fewer than five observations.

| Corpus / mode / ef | Main samples | Mapped four-row | Mapped one-row | Owned one-row | Checked authority | HNSW heaps | Mapped byte read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform 128 / all / 128 | 7,672 | 8.11% | .72% | 1.64% | 5.12% | 15.85% | 8.54% |
| Uniform 128 / correlated / 256 | 7,655 | 1.46% | 1.27% | .29% | 5.70% | 13.83% | 8.09% |
| Real 1536 / all / 32 | 7,552 | 35.91% | 4.86% | 19.31% | 12.92% | 4.09% | 1.58% |
| Real 1536 / correlated / 256 | 7,647 | 10.98% | 13.25% | 4.43% | 29.07% | 6.71% | 3.01% |
| Real 1536 / independent / 128 | 7,629 | 13.20% | 12.03% | 6.07% | 26.43% | 5.79% | 2.39% |

These percentages localize execution; they are not exact elapsed-time attribution
or predicted speedups. Heap work is present, but the completed movement probe
did not improve the public workload consistently. Authority scoring is necessary
for stale graph rows and native score contracts. Earlier prepared-rerank and
immutable-candidate-summary experiments were rejected; this profile does not
justify blindly restoring them or skipping validation/reranking.

The Python public path passes native objects, without JSON serialization.
The `_float_vector` leaf appears in at most .58% of main-thread samples, but that
does not include its callees or all binding costs. This is insufficient evidence
to redesign the binding. The resulting small experiment addresses the current-flag
read in `HnswGraphView.is_current`: reuse the existing inline bounded scalar load
while retaining open-state, slot-domain, byte-domain and false-on-error behavior.
Its results and latest acceptance are recorded in the
[current-flag report](2026-10-16-qdrant-current-flag.md).

## Evidence

[Raw comparisons, rejected patch, parent sources, traces, audits and drivers](results/2026-10-16-hnsw-heap-profile.json.gz)
retain the complete diagnostics. Graph files, datasets and compiled libraries
are identified by the original workloads and binary hashes rather than embedded.
No native Linux, nonresident, concurrent-client, crash or GPU gate is closed here.

Archive: 107 files, 641,044 bytes. SHA-256:
`f4ac1723f0d1e751c42a5624b7fbeaee697559a608e84bc9a747cbc3a900acfe`.
All embedded file hashes were verified after writing the archive.
