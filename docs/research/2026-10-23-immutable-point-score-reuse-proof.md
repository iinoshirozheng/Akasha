# Score reuse and paired-score bounds: two rejected experiments

Neither experiment advances the retained
[mapped adjacency candidate](2026-10-23-immutable-point-neighbor-gather.md).
Comparing vector bytes before reusing a graph score costs more than recomputing
the score in every measured pair. Removing repeated bounds checks from the
authoritative paired kernel improves 128D synthetic cases but provides no
consistent 1536D benefit. Production and retained sources remain unchanged;
no strict acceptance matrix is rerun or passed here.

## Reference and correctness boundary

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`
[constructs its graph scorer from vector storage](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/hnsw/read_view/search.rs).
Its [postprocessing](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/vector_index_search_common.rs)
rescoring branch requires quantization. Akasha permits graph snapshots whose
values differ from current authority. Reusing their scores unconditionally
would violate the existing rerank contract. Cosine preprocessing and compact
scalar representations introduce additional differences.

The first diagnostic tests a narrower possibility: for F32 Dot/L2, synchronously
compare the mapped graph row with the borrowed authoritative row using bounded
`memcmp`, then reuse an already computed graph score. No pointer escapes and
no owner, certificate or cache survives the operation. Byte equality itself
does not validate finiteness; this experiment constructs finite rows and checks
both existing score implementations. It is not an integrated reuse protocol.

Four diagnostic tests pass. They cover one/four graph kernels against exact
paired scores across 16 dimensions, including SIMD tails, signed zero and
subnormals; differing signed-zero/NaN bits; unaligned ranges; invalid offsets;
and closed mappings. The initial Dot test accidentally retained the default L2
dispatcher. Explicitly selecting Dot fixes that fixture; its failed source and
log are preserved. This was not an engine defect.

## Stateless proof cost

The unchanged 132-file adjacency source builds with Mojo 1.0.0 (`ed45d567`).
The standalone harness uses 8,192 owned authoritative rows and a separate
unaligned mapped tape, 64 deterministic queries and 512 permuted candidates
per query. Dimensions are 128/1536 and metrics Dot/L2. Query preparation and
graph scoring occur outside the timers. Each sample performs eight passes;
12 trials alternate recompute/reuse order. All 96 observations are retained.

This deliberately favorable screen omits candidate plumbing, ID lookup,
filtering, heaps, source validation and mismatch recovery. Both operations
acquire the same authoritative readers and produce checked F32-bit checksums.
All 131,072 preflight score comparisons and timed checksums pass. These are
synthetic resident kernels, not the frozen acceptance workload or a capacity run.

| Metric | Dimension | Median reuse / recompute time | Range | Reuse wins |
|---|---:|---:|---:|---:|
| Dot | 128 | 1.4863 | 1.3626–1.5313 | 0/12 |
| Dot | 1536 | 1.6805 | 1.6452–1.7272 | 0/12 |
| L2 | 128 | 1.3806 | 1.3538–1.4367 | 0/12 |
| L2 | 1536 | 1.6119 | 1.6002–1.6300 | 0/12 |

Reject this synchronous comparison scheme before adding search-path complexity.
The result does not rule out a different design that establishes value identity
at publication, but such a design must address stale rows, replacement at the
same sequence, compaction owner exchange and file reclamation.

## Scoped paired-kernel follow-up

A second isolated source changes only `_checked_pair_kernel` in `compute/simd.mojo`.
After its existing dimension checks, three local pointers serve the SIMD prefix;
the loop uses `offset <= length - width`. Owners remain immutably borrowed,
no pointer escapes, and scalar tails, finite checks and arithmetic order remain.
No other source file differs from the first experiment.

Six serial workers compare the old and new executable across three outer trials,
alternating process order. Every worker retains all 96 observations, including
the unchanged byte-comparison control. The table compares each worker's median
recompute time; ratios below one are faster. All preflight comparisons and
checksums pass. These results do not establish whole-query speed improvements.

| Metric | Dimension | Trial 0 | Trial 1 | Trial 2 | Median candidate / prior |
|---|---:|---:|---:|---:|---:|
| Dot | 128 | .9393 | .9144 | .9298 | .9298 |
| Dot | 1536 | .9913 | 1.0141 | 1.0004 | 1.0004 |
| L2 | 128 | .9742 | .9544 | .9825 | .9742 |
| L2 | 1536 | .9954 | 1.0035 | 1.0058 | 1.0035 |

The candidate passes **22 cases in four modules**, including the four proof
cases, SIMD, paired exact and authoritative HNSW rerank tests. Setup initially
selected a broad aggregator without its imported helpers, then a production
fixture using the old List accessor. The final narrow run uses the established
immutable-owner fixtures from the completed CPU validation. All failed setup
logs and the incompatible fixture are retained; no broad suite pass is claimed.

Reject this follow-up for now: its low-dimensional benefit does not reduce the
target high-dimensional cost consistently. Neither diagnostic changes query
parameters, durable formats, public behavior or the authorized Qdrant ef=128
exception. No further full matrix is justified by these screens.

## Evidence and remaining work

The [archive](2026-10-23-immutable-point-score-reuse-proof.json.gz) contains both
complete source inventories, harnesses, raw timings, correctness logs, setup
failures, pinned reference source/license, native hashes, decisions and auditors.
It has **316 artifacts / 600,168 compressed bytes**, SHA-256
`cdb6191c165b088c684da49a6e3324b8dedc40dab22d2cbf458901a22f4701f1`.
Archive-only verification checks every embedded hash and source difference,
then reproduces both audit outputs byte-for-byte. Native binaries are identified
by hash rather than embedded. Extract the files' `text` fields and run
`audit_archive.py ARCHIVE` to repeat that audit without an engine.

Continue from the retained adjacency source. Reducing duplicate scoring requires
a stronger value-identity or shared-storage design, not another per-query full
byte scan. Warm/mixed/client speed and sustained nonresident capacity remain
open. Native Linux is deferred by the user, not passed; M5/M6 remain incomplete.
