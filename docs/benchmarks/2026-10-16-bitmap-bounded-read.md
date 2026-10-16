# Bounded bitmap reads and overflow-safe word counts

Bitmap membership now preserves its logical index validation and reads the
already-proven word with `List.unsafe_get`. Word-count calculation divides
before rounding up, fixing signed overflow at the integer limit. No public
error, eligibility rule, planner, score, ef, owner or durable format changes.
The optimization is retained for repeated filtered-query gains; exact-query
and tail regressions below remain open. Fresh acceptance is still **FAILED**:
warm quality 36/36, speed 6/36; mixed matched quality
36/36, speed 15/36; write+flush 3/9.

## Source and safety evidence

The [refreshed native profile](2026-10-16-hnsw-bounded-heap.md) places
`Bitmap.contains` at 593/7,696 (7.71%) of low-dimensional correlated main-thread
leaf samples. Its old 312-byte symbol reserves `0x830` bytes and prepares List
error-message descriptors on the normal path, after logical index validation.
Formatting calls themselves are on failure paths. The new binary has no
standalone membership symbol; the saved source-admission disassembly shows
inlined size checking, word loading and bit testing, with the public error path
preserved and no second word check or formatting buffer on that base path.

Pinned Qdrant revision `21db2f3ff95d50de3a2b88a741312c056fd1762d` uses
`NotDeletedChecker::check` in `lib/segment/src/vector_storage/raw_scorer.rs` and
`BitSliceExt::get_bit` in `lib/common/common/src/bitvec.rs` to check bit domains
and read flags by internal point offset. Akasha already adopted slot-addressed
source bits; this patch removes its redundant word-level validation. Akasha's
invalid-index error remains its internal contract, rather than adopting Rust's
`Option` return type. No package or upstream code copy is added.

Construction allocates `ceil(size/64)` initialized words. Resize grows words
before publishing the larger size; clone and set algebra preserve shape. No
external source mutates the word list. Thus `0 <= index < size`, checked by
`_validate_index`, also proves `index // 64` is in bounds. The read retains no
pointer or borrowed view, and assertions elsewhere remain enabled.

The old `(size + 63) // 64` overflows near `Int.MAX`; the baseline regression
returns `-144115188075855872` where `144115188075855872` is required. The new
quotient-plus-remainder calculation avoids addition overflow. Final tests use
literal expected counts across 0/1/63/64/65 and the overflow boundary, independent
of the production formula. This tests arithmetic without attempting enormous
allocations; it is not a claim of supporting an Int.MAX-sized allocation.
Another test checks 90 invalid reads across growth and clones, including padding,
negative values and Int limits, while preserving existing bits.

## Paired diagnostics

Three alternating before/after pairs per corpus replay the same original saved
graphs, queries, oracle and frozen ef, with 31 query passes per worker and the
same thread CPU clocks in both versions. All 36 paired cells preserve result
digests, recall arrays and every recorded search statistic. All 18 filtered ANN
QPS pairs improve; 17/18 p95 pairs improve. Repeated passes are timing samples,
not independent recall observations. No build, test or compression overlaps
timing. Saved-graph after/before medians:

| Corpus | Filter | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.031 | 0.987 |
| uniform-128 | correlated | 1.054 | 0.972 |
| uniform-128 | independent | 1.057 | 0.923 |
| uniform-128 | selective | 0.962 | 1.135 |
| uniform-1536 | all | 0.998 | 1.003 |
| uniform-1536 | correlated | 1.020 | 0.986 |
| uniform-1536 | independent | 1.026 | 0.972 |
| uniform-1536 | selective | 0.998 | 1.024 |
| real-1536 | all | 1.004 | 0.998 |
| real-1536 | correlated | 1.018 | 0.988 |
| real-1536 | independent | 1.018 | 0.980 |
| real-1536 | selective | 1.003 | 0.997 |


Uniform-128 selective QPS regresses in all three pairs (.994, .962, .959), with
median p95 1.135. Uniform-1536 all and selective medians also regress slightly.
Real correlated trial 1 p95 is 1.003. These samples are retained; filtered gains
do not make those cells pass or establish a universal improvement.

The separate mixed diagnostic has 18 serial workers cloning the same accepted
paired-rerank trial-0 graphs and frozen mixed plans. All 5,184 response IDs,
recall, oracle, execution decisions and statistics match; all 18 reopen oracles
and 18 retained Arrow leases pass. All 72 individual quality cells pass. Mixed
reports do not store score bits; the saved-graph digests cover scores separately.
All 18 filtered ANN QPS pairs improve; 15/18 p95 pairs improve. Mixed medians:

| Corpus | Filter | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.001 | 0.949 |
| uniform-128 | correlated | 1.043 | 0.999 |
| uniform-128 | independent | 1.037 | 0.902 |
| uniform-128 | selective | 1.000 | 1.075 |
| uniform-1536 | all | 0.998 | 0.961 |
| uniform-1536 | correlated | 1.030 | 0.963 |
| uniform-1536 | independent | 1.030 | 0.973 |
| uniform-1536 | selective | 0.961 | 1.139 |
| real-1536 | all | 1.015 | 1.018 |
| real-1536 | correlated | 1.036 | 0.957 |
| real-1536 | independent | 1.013 | 1.004 |
| real-1536 | selective | 0.989 | 1.000 |


Uniform-1536 selective QPS regresses in all three pairs (.961, .940, .990),
with median p95 1.139. Uniform-128 selective p95 varies from .347 to 3.270;
its median is 1.075. Real independent median p95 is 1.004, and real all is 1.018.
These remain unresolved, without assuming that code size, scheduling or another
unmeasured factor explains them. The bounded read is retained for consistently
faster filtered queries and the independent overflow fix; full speed acceptance
still requires every cell to pass.

## Validation

Final validation passes 149 distinct related Mojo cases across 16 files,
including the final bitmap fixture. The extracted search oracle passes 98
fixtures on both scalar and batched F32 paths; the construction oracle passes
24 fixtures with 2,467 matching adjacency rows. These source fixtures do not
claim timing parity. Rebuilt public validation passes 387 Python/distributed
tests (one skip and three existing warnings), C client, three examples, the
fixed HNSW quality suite and both quality smokes. The installed Python binary
matches the measured candidate hash.

At unchanged fixed ef=64, Dot recall is .9541666667, L2 .95 and cosine
.9583333333. The construction distance-count growth ratio is 3.4405554;
this is work-count evidence, not a build wall-time speedup.

The original word-count regression fails against the parent; the other seven
bitmap tests pass. Initial validation passes 84 related Mojo cases, including
metadata, filter evaluation, source ordinals, segmented search and persistence.
The final word-count oracle replaces a repeated ceiling formula with literal
expectations and adds the first overflowing old input; that final test file is
rerun before completion. No format migration or new crash/GPU run is required
by this in-memory membership change. Previous applicable evidence is retained,
without claiming a new full Mojo suite or native Linux result.

Parent: `75687ebcc0b51ce0bc677e8fa004ee4e1fca9298`.
Before Python SHA-256:
`0fc4b7268fd9f5ddc1df2dffed64f2c867b6b552806ba4850eb0db23ecb8ddb3`.
After Python SHA-256:
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.

## Fresh native acceptance

Three new serial trials per corpus use N=8192, Dot/F32, K=10, 64 measured
queries and the unchanged symmetric ef grid
10/16/24/32/40/48/64/96/128/256/512/1024. Each engine selects its smallest
recall-passing ef independently of timing. All build/reopen/mixed workers
complete, and Akasha reports match the measured binary hash.

Mixed acceptance interleaves nine queries with an eight-point replacement and
flush for 32 blocks. It is serial foreground interleaving, not concurrent-client
load. All 5184 query audits, 18 reopen exact oracles and 9
retained Arrow leases pass. Combined update+flush timing uses each block's own
sum; update-only timing has different durability boundaries across engines.

Akasha and Qdrant both pass recall in all 36 mixed cells. No ef is retuned for
the mixed run.

The table gives median Akasha/Qdrant ratios and strict passed cells. Each cell
requires QPS >= Qdrant and p95 <= Qdrant, without tolerance or cross-cell offsets.
Prior acceptance snapshots are separate runs, not paired causal baselines.
Ratios are rounded for display only; for example, real/all warm median QPS is
.9996249433, below one despite displaying as 1.000. Decisions use full precision.

| Corpus | Filter | Warm QPS / p95 | Pass | Mixed QPS / p95 | Pass |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.561 / 1.765 | 0/3 | 0.853 / 0.953 | 0/3 |
| uniform-128 | correlated | 0.526 / 1.766 | 0/3 | 0.941 / 0.968 | 1/3 |
| uniform-128 | independent | 0.529 / 2.153 | 0/3 | 0.976 / 0.788 | 1/3 |
| uniform-128 | selective | 1.123 / 0.829 | 3/3 | 1.384 / 0.747 | 3/3 |
| uniform-1536 | all | 1.071 / 0.911 | 2/3 | 1.106 / 0.987 | 2/3 |
| uniform-1536 | correlated | 0.787 / 1.185 | 0/3 | 0.739 / 1.414 | 0/3 |
| uniform-1536 | independent | 0.831 / 1.083 | 0/3 | 0.747 / 1.403 | 0/3 |
| uniform-1536 | selective | 0.918 / 1.119 | 0/3 | 0.962 / 1.099 | 1/3 |
| real-1536 | all | 1.000 / 0.934 | 1/3 | 1.303 / 0.768 | 3/3 |
| real-1536 | correlated | 0.489 / 1.771 | 0/3 | 0.612 / 1.411 | 0/3 |
| real-1536 | independent | 0.787 / 1.214 | 0/3 | 0.989 / 0.952 | 1/3 |
| real-1536 | selective | 0.936 / 1.014 | 0/3 | 1.428 / 0.688 | 3/3 |


Failed speed cells, native Linux, concurrent-client, sustained nonresident and
full type/capacity/lifecycle requirements remain open. The pending push decision
is not treated as approval. This resident macOS ARM64 run does not substitute
for other platforms or close full M5/M6.

## Frozen evidence

[Complete evidence](results/2026-10-16-bitmap-bounded-read.json.gz) contains
262 files (10,808,663 bytes): source/test snapshots,
regression failure, assembly, validation logs, full paired and fresh reports,
and drivers. Graphs, datasets and binaries are identified rather than embedded.
Large vector plans retain hashes and deterministic regeneration inputs. All
embedded file hashes verify. Archive SHA-256:
`39c9f2acda7249bd88e51990e83cb08a5c9ea863af340cd6a75881646a46d95f`.
