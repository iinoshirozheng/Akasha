# Immutable mapped rows: remove one owner-state lookup

This follow-up improves the isolated [immutable point-owner prototype](2026-10-20-immutable-point-owner.md),
but does not adopt it into production. The cached byte range now lives beside the
strong shared owner, so scoring does not dereference the lazy-cache state to find
each row. The native mixed comparison improves selective QPS by 6–9% against the
previous prototype, while regressions against production remain. Existing Akasha
source stays at `a6822c3`; the experiment starts from documentation commit `fd23e5d`.
M5/M6 remain incomplete.

## Reference and diagnosis

Qdrant's pinned `21db2f3ff95d50de3a2b88a741312c056fd1762d` separates storage
ownership from borrowed dense rows in
`lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs:81–105`
and bounded chunk reads in `chunked_vectors/read_only/read_ops.rs:88–117`.
Its `lib/segment/src/spaces/simple_neon.rs` scores a bounded prefix through raw
pointers. These references informed the two isolated changes below. The local
reference checkout is at a different HEAD, `74f3e85`; `git show` of the pinned
commit verifies all three cited files are byte-identical and records their hashes.
Future source comparisons must read the pinned object, not assume checkout HEAD.

The new diagnostic opens actual copies of the three frozen databases and uses the
first two selective queries before writes. Each selects the same 250 live points.
It separately measures reader acquisition, pair scoring through MemTable, pair
scoring through retained mapped row owners, copied owned List scoring with old
and current kernels, candidate search, and search including filter evaluation.
There is one warmup and six rotating measured trials, 128 calls per sample.
Every mapped pair score matches the old List kernel's F32 bits; complete search
IDs match the frozen oracle. Public List caches stay empty. This is six-request
cost localization, not the full workload or a speed gate.

For 1536D, scoring through MemTable is about 10–11% slower than scoring through
direct row owners; direct mapped scoring is another 7–9% above the copied owned
List control. These measurements include different traversals and placements;
they do not assign the entire difference to one instruction. Owned current-kernel
scoring is within about 1% of its old-kernel control in this diagnostic.

A raw-pointer kernel trial checks complete dimensions once and retains the exact
finite checks, accumulator order, tails and paired error precedence. Fourteen
existing SIMD/pair cases pass, but the mapped/owned difference remains about
7–8%. This trial is reverted, with source and measurements retained. The adopted
experiment base keeps the original checked view kernel; no new raw scoring path
is carried forward.

The second trial moves only the already validated immutable Span from shared
cache state into `_MappedNumericValues`. Construction retains the file before
publishing the Span, clones retain the same owner, and the synchronized public
List cache still belongs to that owner. Internal readers remain scoped borrows.
Compiler-measured sizes:

| Type | Previous bytes | Inline-range bytes |
| --- | ---: | ---: |
| Mapped row descriptor | 8 | 24 |
| Shared cache/owner state | 80 | 64 |
| Numeric storage Variant | 32 | 32 |
| NumericValues | 48 | 48 |
| VectorValue | 64 | 64 |

The larger descriptor fits the existing Variant size. These are type-layout
measurements, not RSS. Direct mapped/old-owned latency ratios narrow to
1.029–1.040 for the four 1536D requests, and 1.119/1.200 for the two 128D requests.
The previous descriptor trial moved a file Arc and offset while retaining live
source checks; this change instead carries the checked immutable byte range and
does not repeat that earlier layout unchanged.

## Restored native Qdrant and full frozen mixed comparison

The official ARM64 abi3 `qdrant-edge-py==0.8.0` wheel was downloaded from the exact
URL already recorded in `benchmarks/datasets/README.md`, verified at 10,016,514
bytes and SHA-256
`d84d0702a31b6560c84f4d28b3272f94f1df354c04b80167e73acc08cc134642`, then installed
under `.build/qdrant-alignment/qdrant-runtime/deps`. Project runtime dependencies
and the Pixi environment were not changed. Version/import checks and both
production adapter cases for exact filters, mutations and reopen pass; the
previous optional dependency skip is resolved for this targeted run.

The mixed run uses 36 serial workers: production, the previous prototype, the new
prototype and native Qdrant; three rotating orderings for each corpus. Each starts
from a fresh copy of the same engine's frozen trial-0 database and retains the
32-block, nine reads/eight-point upsert/flush plan. Plans, seeds, query vectors,
oracles, ef, metric, eligibility and timing boundaries are unchanged. No build,
test or compression runs beside a timed worker. The three repetitions are not
three newly randomized graph builds, and this is not concurrent or nonresident
acceptance.

All **7,776 Akasha responses** match production IDs, score bits, recall, statistics
and execution decisions. All **2,592 Qdrant responses** pass the same membership,
filter/count and oracle-based recall audit. All **36 exact reopens** match their
oracles; all **27 Akasha Arrow leases** survive writes and close. Qdrant result
score bits are not required to equal Akasha's reduction. Its approximate results
remain subject to the fixed quality threshold.

Median selective ratios over the three same-batch pairs (higher QPS and lower
p95 are better):

| Corpus | New/prior QPS | New/prior p95 | New/production QPS | New/production p95 |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 | 1.094 | 0.809 | 0.950 | 1.387 |
| uniform-1536 | 1.062 | 0.904 | 0.954 | 0.991 |
| real-1536 | 1.084 | 0.917 | 1.070 | 0.399 |

The large real selective tail difference is reported as measured, without an
unsupported causal explanation. All individual trials remain in the archive.
Regressions elsewhere remain, including uniform-128 all QPS 0.963x/p95 1.090x
and real-1536 all QPS 0.987x/p95 1.060x versus production.

Requiring Recall@10 >= .95, QPS >= Qdrant and p95 <= Qdrant **per cell**, with no
tolerance or offsets:

| Akasha variant | Akasha quality | Matched quality | Quality and speed |
| --- | ---: | ---: | ---: |
| Production | 36/36 | 33/36 | 16/36 |
| Prior prototype | 36/36 | 33/36 | 17/36 |
| Inline range | 36/36 | 33/36 | 18/36 |

One production pass becomes a candidate failure: uniform-128 trial 2 independent,
where candidate/Qdrant QPS is 0.986355 despite passing p95. Three failures become
passes (real-1536 trial 1 independent and trials 1/2 selective); they do not offset
that regression. The three unmatched real-correlated cells still have Qdrant
recall 0.9458333333 versus Akasha 0.9805555556. No ef change or waiver is applied.
This is fresh native Qdrant mixed evidence, not a replacement for the complete
warm/concurrent/type/capacity matrix last recorded at `45e04d2`.

The same-batch combined write-plus-flush metric passes both QPS and p95 against
Qdrant in **9/9 cells for all three Akasha variants**, including current
production. This supplies fresh evidence for the retained write path; it is not
a speedup attributable to the new descriptor. Each sample combines its own
eight-point upsert batch and following flush. Raw update calls still have
different durability semantics (Akasha fsyncs the accepted WAL batch; Qdrant's
separate flush synchronizes it), and the engines perform different maintenance
work. This result does not close sustained-maintenance acceptance.

## Validation and remaining implementation

The final source differs from the preceding prototype in exactly
`akasha/document/mapped_numeric.mojo`, verified against both source inventories.
Eighteen owner/vector/MemTable/reopen cases pass, including five scalar types,
concurrent first materialization, held-root reads, close and final-file reclaim.
Six expected negative compilation probes still reject readonly-result mutation
and invalid owner/reader lifetime. The full native Python library compiles.
The two targeted public adapter cases use production Akasha plus restored native
Qdrant; they are not full Python validation of the candidate. No new Linux,
GPU, C or crash suite is claimed for this layout.

The first diagnostic harness attempted to retain loop-interior borrows in a List;
the compiler rejected it. It now retains mapped owner clones and borrows within
each score call, without casting away the rejected origin. Two subsequent setup
failures used the default ANN config, then the old v1 config decoder on a v2
catalog. Both failures are archived; the successful harness reads the persisted
field catalog. These were harness errors, not accepted workload changes.

Do not promote this candidate on its small net pass-count increase. Carry the
inline immutable range into the next isolated ownership layer, while retaining
every observed performance regression. The current PointStore checkpoint still
publishes and rotates WAL without replacing live numeric owners. Next port the
existing typed live-publication approach to current v5 records and partial
contiguous compaction: rebase only matching accepted point versions, refresh
the collection's shared projection/read roots, and retain acquired snapshots.
Uncertain manifest publication, file lease/error reporting, owner destruction
outside the writer lock and concurrent updates must be tested before adoption.
Then complete remaining legacy/type/export/GPU consumers and rerun full fixed
performance and sustained-capacity gates. Do not rerun either rejected kernel or
alignment-only trial unchanged.

## Evidence identities

Native candidate SHA-256:
`a038bdcc139cfd4c3a27163db84094bee734e8e56e8f155ea763c135ed4861ae`.
Native Qdrant extension SHA-256:
`746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`.
Production and prior prototype identities are retained in the previous report and
the new worker manifest. [Evidence archive](2026-10-20-immutable-point-query.json.gz)
contains complete candidate source, the reverted pointer change, diagnostic
sources/failures/raw samples, all 36 workers, build/test logs, input hashes and
post-run audit. Frozen full plans/streams are in the preceding linked archive;
binaries and copied databases are excluded.
The archive contains 367 text artifacts, 1,775,138 compressed bytes, SHA-256
`e49c54d21924864307f4dd76dc32786bc2fd8095bf36028759f88112a14128a8`.
All embedded hashes and the referenced parent archive/plans were verified.
