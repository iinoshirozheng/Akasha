# Base-slot metadata eligibility

Segmented filtered HNSW now reuses a base-slot-to-metadata-ordinal projection.
The query still owns its allowed-ordinal bitmap, and current-source checks run
first. Immutable-base admission reads the projected ordinal and bitmap directly;
delta admission retains the existing ID lookup. Scores, graph construction,
search breadth, source authority and durable bytes are unchanged.

## Ownership and invalidation

Qdrant's internal point offsets address its filter/deletion structures directly.
Akasha has independent graph and metadata ordinal domains, so it must translate
between them. The projection belongs to the shared base-source owner and pins
the metadata lookup owner. Repeated queries share it. Base adoption/promotion
creates a new source owner; metadata rebuilding creates a new lookup owner.
Either transition causes a new projection. Identity compares the official
[Mojo 1.0 ArcPointer `is` operation](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/memory/arc_pointer.mojo),
not addresses whose allocations have already been released.

Known ordinals cannot move during lookup append. When the lookup grows, only
previously unresolved base slots are checked again; complete lookups perform
no graph-size scan. Same-cardinality replacement/reordering of the lookup is
still detected by owner identity. New projection publication follows all checked
graph reads. Validation rejects a mismatched owner, domain or append count.

This adds eight bytes per physical base slot plus a four-byte list entry for
each missing ID, and keeps the cached lookup owner alive. The first filtered
query for a new base/lookup pair performs a slot scan; subsequent queries reuse
it. This is a resident-memory/initialization tradeoff, not a zero-cost cache or a
new persisted format. There are no raw-pointer accesses or new packages.

## Correctness

The original segmented tests pass 21/21. Three new tests exercise owned/mapped
bases, negative and zero IDs, historical slots, missing-ID append, repeated
queries, same-cardinality ordinal reorder, stale-projection rejection, base-to-
delta replacement and delta promotion. They also verify projection ownership is
reused across queries/append and replaced across lookup generations.

Quantized HNSW (14), filtered HNSW (8), overlay cache (5), base recovery (4),
incremental collection (17), rebuild publication (18) and point projection (3)
pass: 69 tests. The rebuilt Python extension passes 387 Python/distributed/service
tests with one skip. An initial new-test compile required an explicit List type
for its vector literal; the compiler error and successful rerun are retained.

The traversal and construction implementations are unchanged from `c8e0ddf`.
Earlier extracted-upstream, durable-format, crash and actual-GPU evidence remains
applicable; it is not relabeled as fresh testing of this patch.

## Controlled saved-graph comparison

Old/new/old and reversed serial runs retain all twelve result digests, recalls
and per-query counters. All six filtered ANN cells improve QPS in both orders:
1.8–14.4% in the first and 4.4–14.6% in the reverse order. All filtered p95 ratios
improve except uniform 128D correlated in the first order (1.044); its reversed
ratio is .910. Unfiltered/exact controls vary, including 128D unfiltered QPS
.916 and p95 1.124 in the first order. All control and tail samples are retained.
No tests/builds overlap timings. This diagnostic is separate from fresh Qdrant
acceptance and does not establish non-resident or large-capacity behavior.

Baseline Python binary SHA-256:
`91c98702872ff5fc41aa4faaf5979b8bbf602aa40391230b732daf80a027058e`.
Candidate:
`fedc10583ed5d522bcf474493e1dda30d2434f3757f711d9ac1a0b2d122b95ad`.

## Fresh acceptance

The unchanged three-corpus warm matrix completes three fresh serial trials per
corpus, with successful build/reopen workers. Matched recall passes **36/36**;
strict speed passes **4/36**, all planned exact selective cells. All ANN speed
cells still fail. Workload: 8,192 points, 64 queries, k=10, seed12345, Dot/F32,
and symmetric ef grid `10,16,24,32,40,48,64,96,128,256,512,1024`. Each engine's
smallest passing ef is selected without reference to timing. The earlier 5/36
source-bitmap matrix is a separate snapshot, not a paired causal baseline.

| Corpus | Filter | Median QPS A/Q | Median p95 A/Q | Passing trials |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 0.491 | 2.038 | 0/3 |
| uniform-128 | correlated | 0.507 | 2.037 | 0/3 |
| uniform-128 | independent | 0.567 | 1.622 | 0/3 |
| uniform-128 | selective | 1.106 | 0.887 | 2/3 |
| uniform-1536 | all | 0.970 | 1.028 | 0/3 |
| uniform-1536 | correlated | 0.683 | 1.339 | 0/3 |
| uniform-1536 | independent | 0.722 | 1.229 | 0/3 |
| uniform-1536 | selective | 0.933 | 1.027 | 0/3 |
| real-1536 | all | 0.954 | 1.028 | 0/3 |
| real-1536 | correlated | 0.439 | 2.001 | 0/3 |
| real-1536 | independent | 0.716 | 1.333 | 0/3 |
| real-1536 | selective | 1.018 | 0.922 | 2/3 |

The serial mixed workload completes nine paired trials: 32 blocks of nine
queries, one eight-point replacement batch and flush. Matched recall passes
**36/36** and speed **10/36**. All 5,184 membership/filter/count query audits,
18 exact-oracle reopen checks and nine retained Arrow leases pass. All filtered
ANN speed cells still fail. This is foreground interleaving with background
workers, not concurrent client load. There is no paired pre-change mixed run,
so its Qdrant ratios are an acceptance snapshot, not an isolated patch effect.

| Corpus | Filter | Median QPS A/Q | Median p95 A/Q | Passing trials |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 0.844 | 0.850 | 1/3 |
| uniform-128 | correlated | 0.736 | 1.212 | 0/3 |
| uniform-128 | independent | 0.764 | 1.066 | 0/3 |
| uniform-128 | selective | 1.367 | 0.715 | 2/3 |
| uniform-1536 | all | 1.005 | 1.057 | 0/3 |
| uniform-1536 | correlated | 0.636 | 1.611 | 0/3 |
| uniform-1536 | independent | 0.642 | 1.573 | 0/3 |
| uniform-1536 | selective | 0.950 | 0.945 | 1/3 |
| real-1536 | all | 1.330 | 0.586 | 3/3 |
| real-1536 | correlated | 0.570 | 1.569 | 0/3 |
| real-1536 | independent | 0.927 | 0.943 | 0/3 |
| real-1536 | selective | 1.424 | 0.619 | 3/3 |

Combined write+flush passes both service-rate and p95 parity in **5/9** trials:
uniform128 3/3, uniform1536 2/3, real1536 0/3. Real write+flush p95 ratios are
1.931/1.525/1.755, even though each mean service rate is higher than Qdrant.
Individual update calls have different durability boundaries: Akasha includes
WAL fsync, whereas Qdrant synchronizes through the separate flush. Only the
per-block sum is used for this comparison; maintenance work can still differ.

## First filtered query and limits

Three fresh process pairs per saved corpus measure the first correlated-filter
query after reopen, then four repeats of the same query. OS caches remain
present. Results and counters match in every pair. First-query latency ratios
(after/before) are .988/1.044/.974 for uniform128, .985/.984/1.152 for uniform1536,
and .926/1.027/1.064 for real1536. There is no consistent first-query regression
at this size, but the 15.2% slower sample remains. This small diagnostic does
not establish a cold-cache or large-capacity guarantee; full raw open, first
and subsequent-query timings are retained in `cold-filter/`.

The rebuilt C client passes. The fixed quality suite remains 3/4: Dot
.9541666667, L2 **.9458333333 < .95**, cosine .9583333333, and construction
distance-growth ratio 3.4405554 < 3.5. No ef, quality or speed gate was relaxed.
Warm, mixed and fixed-quality commands exit 1 for failed gates, not worker
execution failures. All source and native identities are retained.

Overall M5/M6 acceptance is **FAILED**. Fixed L2 search coverage, warm/mixed
query parity and write+flush tails remain open, along with native Linux,
concurrent clients, non-resident and full type/capacity evidence. This macOS
resident improvement is not completion of those requirements.


The archive retains every measured output, oracle ID and timing sample. Large
mixed-plan vector arrays remain in the local run directory; the archive records
their complete hashes and deterministic regeneration through the pinned workload
and `benchmarks.qdrant_mixed.prepare`. It does not duplicate the datasets or
database files.

[Raw comparisons, plan identities, first-query samples, validation and source](results/2026-10-16-qdrant-base-ordinals.json.gz)
(157 files, 6,035,300 bytes; SHA-256
`caf5c30e9f7c19d49be3011d2923ac8aca8f339252c2bb36fc7b7b14dbdb1be7`).
