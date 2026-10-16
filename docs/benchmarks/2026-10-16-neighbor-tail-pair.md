# Current native profile and rejected two-row neighbor tail

The neighbor tail-pair prototype is **rejected**. Its roughly 3–5% median gains
in some high-dimensional filtered cells do not justify low-dimensional and
individual high-dimensional regressions. Production sources, the modified test
and the installed Python binary are restored to `09faba4` (production source
from `63794d6`). No speed acceptance gate closes.

## Current-binary sampling

Five serial native `/usr/bin/sample PID 10 1 -mayDie` captures use the accepted
bitmap binary and corresponding fresh bitmap trial-0 graphs. All five workers
and samplers exit successfully. All **335 pre/post query pairs** preserve IDs,
F32 score bits, recall and complete execution statistics. Queries are converted
to Python lists before sampling; request construction and search remain inside
the sampled loop. This is location evidence, not speed acceptance or an exact
allocation of elapsed time. No Qdrant profile is claimed.

The collapsed top-leaf report only includes symbols with at least five samples.
Percentages below use the main-thread sample count as denominator. The thread
audit initially included the following aggregate stack section in its last
thread; the corrected parser stops at the end of the call tree. No non-main
thread contains an Akasha namespace frame in these captures. This observation
does not prove all possible query paths are single-threaded.

| Corpus / mode | Main samples | Mapped four | Mapped single | Owned single | Authority pair | Heap | Mapped byte read |
|---|---:|---:|---:|---:|---:|---:|---:|
| uniform-128 / all | 7592 | 7.77% | 0.78% | 1.84% | 2.90% | 16.21% | 6.22% |
| uniform-128 / correlated | 7607 | 1.64% | 0.95% | 0.28% | 3.15% | 15.26% | 5.55% |
| real-1536 / all | 7598 | 35.29% | 5.03% | 21.61% | 7.99% | 4.45% | 1.17% |
| real-1536 / correlated | 7576 | 12.16% | 15.92% | 5.37% | 19.83% | 8.09% | 1.89% |
| real-1536 / independent | 7616 | 14.92% | 13.35% | 5.80% | 17.95% | 7.04% | 2.06% |

Real correlated queries average 1,159.6 traversal/delta distance evaluations
plus 461 authoritative rerank evaluations; real independent averages 818.9
plus 256. The corresponding authority kernels account for 19.83% and 17.95%
of main-thread leaf samples. Uniform-128 all averages 4,274.5 traversal/delta
evaluations plus 256 rerank evaluations. These counters count operations, not
unique points. Exact-path counters have different semantics: their retained
candidate count must not be added as extra scoring work.

Most real-correlated mapped-single samples have a base-search wrapper ancestor
(1,183 samples), versus 21 under an upper-layer wrapper. Inlining obscures
some inner frames; this does **not** establish that all those calls are two-row
tails. It motivated a bounded prototype, which was then measured directly.

## Prototype and validation

After existing four-row F32 batches, score two remaining admitted rows together
and leave at most one scalar row. Owned and mapped paths preserve each row's
SIMD width, accumulator order, metric finish, slot validation and mapping bounds.
Filtering, cap, candidate order, ef, cancellation, counters and durable formats
remain unchanged. The pinned Qdrant PointScorer filters and caps before batched
storage scoring; this SIMD scheduling is an Akasha optimization of that pattern,
not an identical upstream Rust two-row implementation.

**64 distinct Mojo cases** pass across four-distance (3), filtered traversal
(8), search layer (17), cancellation (2), mapped view (9), mapped vectors (4)
and segmented HNSW (21). The enhanced three-metric test covers 14 dimensions
from 1 through 1,536 on owned and mapped storage, exact F32 bits versus single
scoring, repeated/nonconsecutive slots, either invalid slot, wrong dimensions
and closed mappings. Existing scorer matrices exercise 0–11 inputs, five caps,
filter compaction, buffer reuse and tail lengths. The enhanced test fails to
compile against the parent because the two-row method does not exist there.

The initial validation driver names a nonexistent `test_hnsw_search_core` after
two successful files. A corrected resume driver uses `test_hnsw_search_layer`
and completes the remaining checks without repeating those successes. Both
the failed driver and correction are retained. **98 source-search fixtures pass
on both scalar and batched F32 paths**, and the Python extension builds.
The source oracle covers single-entry primitives, not upper-seed query reuse
or native Edge acceptance. No new broad CPU/C/crash/GPU/Linux pass is claimed.

## Fixed-input paired measurements

Three serial alternating pairs per corpus use identical fresh bitmap trial-0
graphs, queries and fixed ef. Warm diagnostics run 31 passes over all 67 queries,
including the three warmups excluded from formal acceptance. Mixed diagnostics
clone the same input graphs and replay frozen bitmap mixed plans. No timing
overlaps with builds, tests, compression or another benchmark worker.

All **36 paired warm cells** preserve result digests (including scores), recall
and complete statistics. All **5,184 mixed responses**, 18 reopen checks and
18 retained Arrow lease checks pass; IDs, recall, oracle, execution and stats
match. Mixed reports do not retain score bits. Every mixed quality cell passes.

Ratios are median after/before across three pairs; QPS above 1 and p95 below 1
are improvements. Individual regressions remain in the raw reports.

| Corpus | Filter | Saved QPS / p95 | Mixed QPS / p95 |
|---|---|---:|---:|
| uniform-128 | all | 0.9767 / 1.0342 | 0.9835 / 1.0121 |
| uniform-128 | correlated | 0.9868 / 1.0532 | 1.0082 / 1.0102 |
| uniform-128 | independent | 1.0051 / 0.9892 | 1.0132 / 0.9490 |
| uniform-128 | selective | 0.9909 / 0.9855 | 0.9869 / 0.8211 |
| uniform-1536 | all | 1.0088 / 1.0076 | 1.0090 / 0.9545 |
| uniform-1536 | correlated | 1.0263 / 0.9735 | 1.0196 / 1.0059 |
| uniform-1536 | independent | 1.0337 / 0.9607 | 1.0195 / 0.9746 |
| uniform-1536 | selective | 1.0055 / 0.9876 | 0.9916 / 0.9769 |
| real-1536 | all | 0.9972 / 1.0048 | 1.0155 / 0.9916 |
| real-1536 | correlated | 1.0342 / 0.9797 | 1.0475 / 0.9200 |
| real-1536 | independent | 1.0274 / 0.9806 | 1.0461 / 0.9645 |
| real-1536 | selective | 1.0050 / 0.9906 | 0.9892 / 1.0018 |

Uniform-128 warm correlated p95 ratios are .9774, 1.0532 and 1.0752.
Real independent warm QPS ratios are .9547, 1.0333 and 1.0274, with p95
1.1132, .9773 and .9806. Real correlated/independent mixed medians improve,
but their third pairs regress in both QPS and p95. No dimension threshold
is added to hide those measurements, and no baseline tolerance is introduced.

## Restoration and remaining work

All four changed source/test files were verified byte-for-byte against the
parent before restoration. The installed Python binary is restored to SHA-256
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.
The rejected binary SHA-256 is
`9eec87274a876645cb8b28a7534aec6d0309dac262059d1e23d2071ded3cc24e`.
This prototype never rebuilt the C artifact; its previous accepted-source
build and successful check remain applicable. No production change or new test
is retained, and parent validation remains applicable.

Latest accepted strict gates remain warm speed **6/36**, mixed speed **15/36**,
write+flush **3/9**, one-client HTTP **6/36** and four-client HTTP **12/36**.
Platform, type/capacity and sustained nonresident requirements remain open.
The next diagnostic measures actual pinned Qdrant scoring operations on cloned
input graphs, to distinguish excess work from per-operation cost. Diagnostic
instrumentation will not replace the official wheel in speed acceptance.

The artifact includes both drivers, complete profile samples and query audits,
candidate patch/source/test snapshots, validation failures and successes, and
all raw paired measurements. Binaries and large databases are identified by
hashes, not embedded. Inputs use the bitmap acceptance archive
`39c9f2acda7249bd88e51990e83cb08a5c9ea863af340cd6a75881646a46d95f`
and complete database inventory in the current concurrency archive
`431aaa05372c567f4b6d2b96e72e501c672b2324a239690f071942b085ac1b34`.


[Complete artifact](results/2026-10-16-neighbor-tail-pair.json.gz), 187 files, 2,295,685 bytes; SHA-256 `bddb3c39402b85237196e122cc60646ce6d38b927c9ec189a0c0bfcb4c264d61`.
