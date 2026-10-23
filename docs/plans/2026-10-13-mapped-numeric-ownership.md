# Mapped Numeric Ownership Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Lower durable numeric-vector residency without changing public List APIs, accepted query results, immutable-file lifetime or v1–v4 bytes.

**Architecture:** Keep immutable field ownership in PointState/VectorValue. A numeric field is either an accepted owned List or a checked row in an independently owned, leased immutable mapping. Internal scoring/encoding reads the stored row directly; an explicit public List accessor materializes one immutable owned List on first use and never replaces it.

**Tech Stack:** Project Mojo 1.0.0 (`ed45d567`), official ArcPointer/Span/BlockingSpinLock, existing MappedFile/file leases, existing Python/C/Arrow APIs. No new dependencies.

---

## Status and established requirements

This is the implementation direction, not an adopted storage change. Production keeps the `6d01819` storage/query engine with the
[standalone Python result ownership fix](../research/2026-10-14-production-result-ownership.md);
current HEAD also contains diagnostic records. User authorization is
continuation of M5/M6; public API/format preservation remains mandatory.

[Open-memory evidence](../benchmarks/2026-10-13-open-memory-phases.md) localizes both
128 MiB high-dimensional OOMs to the second segment. Real 6 GiB control anonymous memory
is about 134 MiB after recovery, 155 MiB after HNSW, 163 MiB after open. These include
Python/allocator/QEMU and are not an engine allocation census. The authoritative F32
Lists and exact path still lack sustained nonresident evidence.

The [compiled F32 mechanism](../research/2026-10-13-mapped-list-probe.mojo) is complete
code for the owner/materialization pattern, with four passing runtime cases and a
readonly negative compile. Its `_MappedRowState`, `_MappedRow.load`, `_MappedRow.values`
and explicit-capture parallel test are the starting point; do not copy its test delay
or absence of file lease into production. This proof does not validate the entire design.

## Execution checkpoint — 2026-10-13

The [copy composition](../research/2026-10-14-checkpoint-bulk-copy.md) passes
49 joint Mojo, 13 crash-state and 369 Python cases, reusing applicable standalone
evidence. All 54 workers complete and 18 cache payload pairs match byte-for-byte.
Nine flush QPS pairs improve 10.9–18.5%, with all flush p95 values improved.
Warm speed is 23→26/36, mixed 20→24/36, write+flush still 3/9. One mixed real
selective pass→fail and one 1.8% combined p95 regression remain. Keep isolated.
Next establish and test live-query versus durable-writer lock responsibilities
before changing the contention identified in the native diagnostic.

The [payload Span candidate](../research/2026-10-14-payload-span-encoding.md)
passes 102 Mojo, 9 crash-state and 369 Python cases. All 54 workers complete;
18 cache payload pairs are byte-identical. Nine flush QPS pairs improve 3.5–11.1%
and all flush/combined p95 values improve. Warm speed stays 21/36, mixed falls
26→24/36 and write+flush remains 3/9, retaining six query pass→fail cells. Keep
it isolated; next verify composition with the separately frozen F32 row-copy
candidate without assuming additive gains or waiving any fixed gate.

The [mixed-query boundary investigation](../research/2026-10-14-mixed-query-boundaries.md)
completes 12 workers and 3,456 exact paired query audits. Native lock events
locate reproduced tails in compaction capture/publication waits for both variants;
there is no GC overlap in timed queries. Planned exact retains the approximate
entry point's writer lock and does not construct a snapshot. Do not waive the
earlier failed cell or unlock durable publication without a validated predicate.
Next inspect the shared payload codec's scalar byte encoding, independently
localized in flush fingerprint/metadata costs. Production remains unchanged.

The [checked F32 row-copy candidate](../research/2026-10-14-hnsw-validation-row-copy.md)
passes 104 Mojo, 9 crash-state and 369 Python cases. All 54 native workers
complete with exact query audits; all 18 cache payload pairs are byte-identical.
Six high-dimensional flush QPS pairs improve 5.6–19.7%. Warm speed is 22→27/36,
mixed 20→21/36 and write+flush remains 3/9. One mixed uniform-128 selective
trial changes pass→fail. Retain the isolated candidate while investigating the
first post-flush query tail; do not integrate or waive that failure. Production
and all M5/M6 requirements remain unchanged.

The [flush diagnostic](../research/2026-10-14-legacy-flush-phases.md) completes
three workers and 96 public flushes, with all 864 exact query pairs matching
reused production controls. Derived cache groups occupy 95–96% of aggregate
flush time. High-dimensional fingerprinting is about 9 ms, metadata encoding
4.5 ms, and prepared-vector validation including row copies 3.8–5.1 ms per
snapshot. Next test checked contiguous F32 row copying via existing List/Span
while keeping the validator and serialized bytes. This is localization only;
no fresh performance, Linux, capacity, C, crash or GPU acceptance is claimed.

The [four-row pruning prototype](../research/2026-10-14-hnsw-four-pruning.md)
passes 127 Mojo / 369 Python cases and completes 54 native workers with exact
query results/stats. Immediate Span reuse preserves required center/member
score bits, pruning order and build counts. Warm speed is 25→23/36, mixed
18→19/36 and write+flush 3/9 for both; four warm pass→fail cells remain.
Real writes improve 1.8–4.5% in three pairs, which does not establish acceptance.
Do not adopt. Next inspect remaining flush costs and existing overlay-cache
contracts before another pruning variation. No fresh Linux/capacity/C/crash/GPU
gate is claimed; production and all M5/M6 requirements remain unchanged.

The [write geometry investigation](../research/2026-10-14-legacy-write-geometry.md)
completes two six-worker diagnostics, locating 75–84% of high-dimensional link
time in planning/pruning. A per-connection ordered-pair cache passes 115 Mojo /
369 Python but slows all nine write pairs. Its 54 workers retain warm 26→24/36,
mixed 22→21/36, write+flush 6→5/9 and seven query pass→fail cells. Three counter
workers show only 1.5–4.9% distance reuse. All 69 workers and the 141 ms WAL
outlier are frozen. Stop this cache branch; next inspect four-row batching of
required center/member scores during adjacency overflow. No Linux/capacity/C/
crash/GPU acceptance is claimed. Production and all M5/M6 requirements remain.

The [mapped adjacency metadata experiment](../research/2026-10-14-mapped-neighbor-metadata.md)
is complete and unadopted. One validated node/count base replaces repeated
lookups within `neighbor_range`; all mapping and edge guards remain. It passes
88 Mojo/369 Python and all 54 workers preserve IDs/bits/stats/execution. Warm
speed is 29→27/36, mixed 19→23/36, write+flush 3/9 for both, with four pass→fail
cells retained. No Linux/capacity/C/crash/GPU acceptance is claimed. October 2
already tested broad mapped accessor/scalar-reader inlining; do not repeat it
without new evidence. Next inspect write/flush phase costs and prior maintenance
experiments. Production remains unchanged and every M5/M6 gate stays active.

The [block-stamped visited-state experiment](../research/2026-10-14-hnsw-block-visits.md)
is complete and unadopted. Retained visit payload for 8,192 slots decreases
32 KiB→2 KiB with the same UInt32 epoch and normal O(1) reset. Five semantic
cases pass on both representations; the candidate passes 111 Mojo/369 Python.
All 54 native workers complete with equal IDs/bits/stats/execution. Warm speed
is 22→21/36, mixed 18→21/36, write+flush 3/9 for both; two warm pass→fail cells
remain. No capacity, Linux, C, crash or GPU acceptance is claimed. Production
stays unchanged. Next inspect mapped adjacency metadata access; scalar integer
reads already use checked copied loads. M5/M6 remain unresolved.

The [single-probe lookup experiments](../research/2026-10-14-hnsw-single-lookup.md)
are complete and unadopted. Both variants pass 40 Mojo and 369 Python cases and
each completes 54 warm/mixed workers with identical IDs, bits, stats and
execution. Get-only is warm 19→23/36, mixed 22→19/36; preserving admission call
boundaries is warm 30→27/36, mixed 20→21/36. Nine pass→fail cells remain across
both experiments. The emitted methods shrink, but this does not establish
overall improvement. Production is unchanged. Inspect dominant mapped scoring
and adjacency data access before another dictionary variation; no new capacity,
Linux, C, crash or GPU acceptance is claimed.

The [two-hop experiments](../research/2026-10-14-filtered-two-hop.md) are
complete and rejected. The first loses historical-source bridge chains in two
existing tests. Scoring historical bridges fixes both; a further m0 limit has
its own failing-before/passing-after case. Each built version retains all 27
warm workers and 36/36 quality cells, but real filtered QPS is only .246–.280
and .296–.334 of production. Six pass→fail cells remain across the two matrices.
No full Python, mixed, capacity or Linux acceptance is claimed. Stop this branch;
return to the original traversal and inspect redundant per-node lookup work.
Production source/binary remain unchanged; M5/M6 acceptance remains outstanding.

The [source-counter diagnostic](../research/2026-10-14-filtered-source-counts.md)
preserves all134 fixed real filtered queries/public stats and verifies every
base+delta counter sum. Base level-0 scores are subsequently rejected at78.07%
and78.21%; delta already filters75% before scoring. Investigate predicate-aware
neighborhood expansion separately, preserving the established search_layer
contract and distinguishing algorithm changes from representation-only audits.
These bridge scores cannot simply be dropped; no speed benefit or adoption is
claimed. Mapped authority and all M5/M6 acceptance gates remain unresolved.

The [grouped mapped chunk experiment](../research/2026-10-14-four-chunk-offset.md)
retains two revisions, each70 Mojo/369 Python passing. Explicit common offset
reduces the emitted loop61→54 instructions, but its54-worker matrix remains
warm21→21/36 and mixed19→22/36 with five pass→fail cells. Do not adopt.
Next isolate source counters: graph bridges are scored before admission while
delta scans filter before scoring, so merged rejection counts cannot quantify
wasted graph distance work. Production stays96e05e2c.

Four [real filtered ANN native captures](../research/2026-10-14-filtered-ann-native-sample.md)
complete with all67 pre/post and cross-version query audits equal. Mapped four-row
distance accounts for33–35% of main-thread top samples, with four range guards
inside the emitted SIMD loop. A separate production-based grouped-load candidate
is being validated; mapping lifetime and all bounds must remain checked. This
sampling does not close any speed or capacity gate.

The [shared result-key experiment](../research/2026-10-14-shared-result-keys.md)
passes 369 Python tests and 30 actual-binding comparison cases. Its complete
54-worker batch has warm speed22→22/36 and mixed25→24/36, retaining both
pass→fail cells. It is frozen and unadopted; production stays96e05e2c. Next sample
real-1536 filtered ANN on production and the mapped ownership-fixed candidate.
Do not repeat immutable candidate norm caching: four rejected prototypes already
exist in the [candidate-summary report](../benchmarks/2026-10-13-candidate-summary-probes.md).

The [production-only result ownership fix](../research/2026-10-14-production-result-ownership.md)
is now adopted as a correctness fix, without mapped storage. Mac/root binary is
`96e05e2c…`; ten new lifetime tests pass on Mac/Linux, the existing359 Python tests
pass, and the root artifact passes the ten tests after atomic installation.
Warm is23→25/36, mixed27→24/36; all six pass→fail cells remain failures. C is
unchanged. Use the frozen production-python-results package as the next baseline;
this adoption does not close a performance or mapped-capacity gate.

The [Python result ownership fix](../research/2026-10-14-python-result-ownership.md)
uses typed List/Span instead of leaking dynamic Python append calls. Ten new
weakref tests fail on the parent and pass on Mac/Linux; full Python359 passes.
Its complete fixed capacity batch finishes 60/60 workers, no OOM/timeouts,
quality108/108, speed65/108 and paired pressure31/108 (18 also pass speed).
Native warm is23→20/36 and mixed25→25/36, retaining all regressions. The mapped
candidate remains unadopted. Independently verify the production-only binding fix;
then investigate remaining real-cosine/filtered-delta cost without repeating
rejected reader variants or relaxing any strict M5/M6 requirement.

The [complete constrained-memory matrix](../research/2026-10-14-typed-live-capacity.md)
now retains all 60 workers: 51/54 constrained workers complete, three late OOMs;
quality 96/108, strict speed 42/108, paired sustained pressure 12/108 (six also
pass speed). All control/failed-worker preflights match. Linux lifecycle tests
pass on the same source; QEMU results do not certify native Linux performance.
Separate full-work allocation traces localize retained query allocations to the
Python/Mojo boundary. Investigate result ownership in a fresh candidate before
repeating the fixed matrix. Production remains unchanged and M5/M6 unresolved.

The [typed live-compaction candidate](../research/2026-10-14-mapped-typed-compaction.md)
now shares heap-stable PointTable authority with maintenance and publishes mapped
numeric owners to the point table and read projection together. It preserves newer
writes and handles the legacy-prefix migration boundary before the first typed
flush. Eight new regressions and current-source validation pass: 122 selected Mojo,
23 crash, 359 Python and C ABI. The disk-only lease fixture now checks last-file-owner
release; its original failure is retained. This candidate is frozen and unadopted,
with no new speed/capacity claim. Next run the fixed constrained-memory matrix with
authority/HNSW input roles separately observed, then fixed warm/mixed pairings.
Existing warm regressions and every strict M5/M6 gate remain unresolved.

The [direct dense-field publication candidate](../research/2026-10-14-mapped-compaction-fields.md)
eliminates whole-row compaction clones while retaining old numeric owners until
outside writer. The sparse-only update/lifetime control passes on parent and
candidate; current validation is 79 selected Mojo, 23 crash, 359 Python and C ABI.
Its own mixed gate is 29/36→26/36 (four pass→fail), warm 20/36→14/36 (six
pass→fail), with identical quality/results. It is frozen and unadopted. Continue
typed live authority from this isolated base before new capacity certification;
warm mapped-read regressions remain a separate unresolved gate.

The [unlocked output preparation candidate](../research/2026-10-14-mapped-compaction-prepare.md)
now passes 64 selected Mojo, 23 crash, 359 Python and C ABI. Its own mixed
gate remains 24/36→18/36 (seven pass→fail), warm 23/36→17/36 (six pass→fail),
with identical quality/results. It is not adopted. Next eliminate repeated
whole-row cloning for dense-owner exchange, retaining old/new numeric fields
until outside writer and preserving newer sparse-only writes. Such writes do
not advance legacy dense row sequence; a whole-table sequence catch-up is unsafe.

[Instrumented mixed phase localization](../research/2026-10-14-mapped-compaction-phases.md)
now identifies persisted output mapping/CRC/decode under writer exclusion as
6.087–13.539 ms of a 10.262–17.733 ms median publication interval. All 864
paired query audits match. There are only two base builds per worker, at initial
Arrow export and final reopened exact validation, so repeated snapshot-base
rebuilds do not explain this mixed workload. Next move checked output preparation
to the unlocked build phase, retaining source owners and all failure boundaries.
The instrumented binary is not a performance gate or adopted implementation.

The [flush read-run follow-up](../research/2026-10-14-mapped-flush-runs.md) removes
ordinary flush base rebuilds and preserves immutable indexes, with three new
regressions and 103 selected Mojo, 359 Python and C ABI passing. Its own mixed
gate is 25/36→12/36 (fifteen pass→fail), warm 24/36→21/36 (three pass→fail).
Quality and audited results match. It remains isolated. Next instrument the
remaining compaction decode/owner publication and post-compaction base rebuild
before changing their lock boundary; no typed/capacity result is inherited.

The [2026-10-14 legacy live ownership follow-up](../research/2026-10-14-mapped-live-compaction.md)
now rebases flush/compaction authority, preserves newer writes and releases retired
owners outside the writer lock. Current-source validation passes 151 selected Mojo,
23 crash, 359 Python and C ABI. Its own strict mixed batch falls 21/36→12/36
with eleven pass→fail cells; warm falls 23/36→17/36 with six. Quality and all
audited results remain identical. It is frozen and unadopted. Next isolate the
flush read-cache reset: preserve existing immutable indexes while replacing
changed numeric owners, including sealed-head and snapshot lifetime tests.
Typed live compaction and all new capacity gates remain unfinished.

The complete isolated owner/consumer candidate is now implemented and frozen in the
[mapped numeric owner report](../research/2026-10-13-mapped-numeric-owner.md). Final
359 Python, 23 crash, C ABI and relevant actual-device/storage/consumer tests pass.
Both 1536D 128 MiB Linux QEMU diagnostics now finish without OOM, with separately
measured authority/HNSW residency. This does not establish sustained nonresident
performance. Native warm strict speed regresses 21/36→15/36 with six pass→fail cells;
the candidate is not eligible for production adoption while those regressions remain.
Next: profile the mapped-reader exact path, preserve its checks while reducing cost,
then address legacy write rebasing and mixed/nonresident gates. The report records
the changed source-lease test expectation and every retained failure.

Follow-up [Variant and kernel-snapshot trials](../research/2026-10-13-mapped-reader-followups.md)
are frozen too. Both separate warm batches remain 20/36→15/36 with six pass→fail
cells. The snapshot preserves per-access error order and reduces selected exact code
to 23,776 bytes; uniform-1536 full-exact QPS is .954–.999 of same-batch production,
but uniform-128 remains .725–.758. It passes 61 selected Mojo, 359 Python and five
negative compile checks, without a new capacity/mixed gate. Next inspect the four
remaining out-of-line reader factory calls in the actual collection caller. No
candidate is adopted; Task 5 remains unfinished.

The subsequent [factory-inline candidate](../research/2026-10-13-mapped-kernel-inline.md)
eliminates all four reader factory calls and passes 61 selected Mojo, 359 Python and
five negative compile checks. Its own warm batch is 20/36→19/36 with two pass→fail
cells, so it remains isolated. Next remove the duplicated default-field lookup in
the exact loop using existing field accessors. No capacity/mixed gate is inherited.

The [single field-lookup candidate](../research/2026-10-13-mapped-exact-field-lookup.md)
passes 62 selected Mojo, 359 Python and five negative compiles but still regresses
22/36→19/36 in its fixed warm batch, with four pass→fail cells. It remains unadopted.
Next inspect metric/width dispatch once per query on the frozen kernel-inline parent;
the emitted parent loop still branches on these query-invariant values. This next
hypothesis must preserve exact arithmetic/error order and pass the same fixed gate.

The [query-level dispatch candidate](../research/2026-10-13-mapped-query-dispatch.md)
passes 62 selected Mojo (expanded bit-reference dimension boundaries), 359 Python
and five negative compiles, but remains 24/36→20/36 in its own warm batch with five
pass→fail cells. All six scan specializations total 56,944 bytes. Do not promote it.
Next sample native execution on production versus the frozen kernel-inline parent
to locate remaining runtime costs before another implementation change.

Two serial [native sampling captures](../research/2026-10-13-mapped-native-sample.md)
now identify hot merged PCs in SIMD scoring, beside remaining per-chunk range/flag
calculations. All 67 before/after query audits match. This diagnostic is not a speed
or capacity gate. The next isolated kernel-inline follow-up bounds the complete safe
SIMD prefix, keeps a checked first-failure chunk before finite reduction, and retains
checked scalar tails. It must preserve stale-source/closed-map/paired error order.

The [bounded SIMD-prefix candidate](../research/2026-10-13-mapped-kernel-prefix.md)
passes 65 selected Mojo, 359 Python and five negative compile checks while preserving
first-fault ordering. Its warm batch is 19/36→19/36, but one pass→fail remains and
cannot be offset. It is not adopted. Next scale the same-process alternating
reader/entry diagnostic to 8,192 rows on the frozen kernel-inline source; this is
cost localization, not another acceptance gate.

Task 1 has three complete isolated reader candidates; production adoption is pending.
[Behavior, compiler limitations and all fixed warm comparisons](../research/2026-10-13-numeric-read-view.md)
are frozen. Checked and inline variants each pass 74 Mojo cases; the bounded follow-up
passes 23 directly relevant Mojo and full 359 Python cases. The bounded candidate is
the next isolated implementation base, but has three pass→fail warm cells and a
3.1–6.2% high-dimensional full-exact QPS decrease; no storage/capacity benefit exists yet.
Do not promote it merely because its behavior tests pass.

Mojo 1.0 permits clearing an owned List while the reader is live. Keep the new live
bounds check and the independent operation-owner invariant. Explicit mapping close is
also checked. The next owner layer must establish immutable source lifetime before
moving any range/state validation out of per-chunk access. Do not discard these checks
based only on origin annotations, and do not repeat the rejected warm trials unchanged.

## Alternatives and decision

| Approach | Result |
|---|---|
| Stream only the existing owned decoder | May reduce transient overlap, but retains all decoded Lists and cannot establish nonresident exact. Insufficient as the final design. |
| Add a second canonical vector-file cache | Could supply aligned rows but creates a new derived-file identity/publication/rebuild lifecycle. Existing immutable records already contain authority; defer unless measured access requirements prove this necessary. |
| Map existing immutable authority and preserve explicit owned public access | Selected. Share file owners and retain checked byte offsets; handle unaligned little-endian records explicitly. Public signatures remain stable. |

Local reference: Qdrant `reference/qdrant/lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs`
separates storage ownership from borrowed/Cow reads. Akasha must preserve its own
contracts rather than copying Qdrant's mutability or durable layout.

## Non-negotiable boundaries

1. Public `VectorValue.dense_values`/`multivector_values`, legacy `MemTableEntry.values`,
   owned get results, and byte-decoder/`read_segment` owned-result contracts stay valid.
   Legacy `_legacy_values`/`MemTableEntry.values` remain non-raising. Validate private
   mapped ranges before publication; a non-raising copy must not suppress I/O/range errors.
   Internal query/codec readers must not accidentally call the materializing accessor.
2. Preserve F32/F16/BF16/I8/U8 bits and dense/multivector dimensions. Do not promote
   authority. Sparse/binary behavior remains unchanged until a measured requirement
   calls for mapping them. Legacy nonfinite/error behavior and typed finite checks stay
   at their established boundaries; kernel validation is not removed.
3. Preserve the existing kernel width, accumulation/reduction/tail order, first-error
   precedence, top-k ordering, IDs and visit statistics. A representation change must
   not silently select a different algorithm or retune ef.
4. Mapping constructors validate byte ranges using subtraction/division to avoid
   overflow; reads use explicit unaligned loads. No public escaping raw pointer/Span,
   allocator masquerading as List, whole-file owned tape or unsynchronized lazy cache.
5. A field retains a strong mapping owner and a lease on its exact immutable source.
   New roots and partial field updates share that owner. An operation/export acquires
   its own owner before leaving a handle lock. Close drops one reference; it must not
   unmap data still used by another operation or Arrow export.
6. Retirement remains directory-relative. Last-owner cleanup must release its mapping
   before trying to acquire exclusive reclamation rights; preserve retries and error
   handling. Do not retain an entire obsolete manifest merely to protect one row.
7. Keep all existing durable readers/fixtures and bytes. A mapped recovery path may
   be internal alongside required public owned decode APIs; there is no hidden query
   fallback or new public configuration. CRC/catalog/sequence validation precedes
   publication. Failure never repairs/truncates WAL before full preflight succeeds.

## Task 1: Concrete numeric read boundary

**Files:** `src/akasha/document/vector_value.mojo`, a private concrete numeric-view
module under `src/akasha/document/`, `src/akasha/compute/simd.mojo`,
`src/akasha/compute/field_metrics.mojo`; tests `tests/mojo/test_vector_value.mojo`,
`tests/mojo/test_paired_exact.mojo` and a new `tests/mojo/test_numeric_read_view.mojo`.

1. Add behavior tests for owned and deliberately unaligned mapped rows, scalar/SIMD
   boundaries, native bits, negative/overflow/truncated ranges and wrong dtype. Use
   complete fixture/bit assertions from the compiled probe; retain an expected
   readonly-assignment compile rejection. Run the new file and record its initial failure.
2. Add one private typed row reader with explicit length and checked scalar/SIMD loads.
   The owner outlives the synchronous reader. Reuse MappedFile range checking; do not
   add a generic storage framework or expose an ownerless view.
3. Route existing prepared F32 scoring and typed candidate reads through that boundary,
   initially backed by owned values. Keep public functions and public List accessors.
   Remove replaced internal access routes together with their callers.
4. Verify the new test, existing SIMD/paired/native metric tests and public Python
   oracles. Compare before/after result bits and first-error behavior. If machine code
   introduces repeated dynamic dispatch or extra copying, fix the reader before proceeding.
5. Commit only this independently working representation boundary after its checks.

## Task 2: Numeric owner with explicit public materialization

**Files:** `src/akasha/document/vector_value.mojo`, `src/akasha/document/point_state.mojo`,
`src/akasha/storage/memtable.mojo`, `tests/mojo/test_vector_value.mojo`,
new `tests/mojo/test_mapped_numeric_owner.mojo` and Python compile-contract tests.

1. Extend the probe tests to every existing numeric dtype and multivector shape;
   include signed zero/subnormal bits, empty multivector, independent owners and
   wrong-type requests before/after materialization. Preserve the initial failure.
2. Implement the mapped numeric arm using the existing field owner. Public List access
   prepares a local complete List, then publishes it once under the owner's lock.
   Constructor validation failures publish nothing; wrong-dtype access cannot build a
   cache. Preserve non-raising legacy getters, including zero-length mappings. Use a
   stable origin-bound Pointer for
   individual shared-state mutations; never pass the whole state across a lock wait.
3. Keep the final List allocation immutable and stable for the rest of the field
   lifetime. Repeated and concurrent public calls return the same borrowed allocation.
   Pure internal reads must leave the materialization counter at zero in tests.
4. Verify eight simultaneous first readers, borrowed-result readonly compilation,
   scalar mismatch before cache creation, constructor rejection and independently
   acquired owner lifetime. Count
   unique cases once; do not add repeated runs as new coverage.
5. Commit this owner layer only when it works with both owned and mapped test sources.

## Task 3: Exact immutable-file ownership and legacy recovery

**Files:** `src/akasha/storage/mapped_file.mojo`, `src/akasha/storage/file_leases.mojo`,
`src/akasha/storage/segment.mojo`, `src/akasha/storage/legacy_recovery.mojo`,
`src/akasha/storage/read_generation.mojo`, `src/akasha/api/collection.mojo`;
new mapped-recovery cases and existing segment/retirement/snapshot tests.

1. Write a regression that recovers the legacy fixture through the internal mapped
   path, checks zero eager vector materialization, and keeps an acquired row/root
   usable through close, replacement writer, flush and compaction. Assert actual
   file lease/reclamation behavior, not merely POSIX unlink survival.
2. Share one source mapping per immutable segment. Acquire the exact source-file
   lease under the established writer/publication exclusion. Reuse directory-relative
   lease primitives and preserve all existing error/retry handling.
3. Factor the existing segment validation/record walk so public byte and owned file
   decoders retain their independent-owned-result contract while internal recovery
   creates checked mapped rows. Avoid duplicating the format parser or allocating
   an owned vector merely to discard it while creating a mapped descriptor.
4. Preserve public owned decoders' tests that rewrite/remove original files after
   decode. Verify old versions, checksum/catalog/length/sequence rejection, torn
   inputs, last-owner cleanup, recovery preflight and absence of premature WAL repair.
5. Verify incremental updates, delete/reinsert, sparse/payload-only owner sharing and
   layout revision changes. Retest relevant crash paths before adopting this layer.

## Task 4: Current typed checkpoint and every read consumer

**Files:** `src/akasha/document/point_codec.mojo`,
`src/akasha/storage/point_segment.mojo`, `src/akasha/storage/point_recovery.mojo`,
`src/akasha/storage/point_table.mojo`, `src/akasha/storage/point_store.mojo`,
`src/akasha/api/snapshot.mojo`, relevant `src/akasha/query/`/`index/` consumers,
`src/bindings/arrow_export.mojo` and `src/bindings/point_values.mojo`.

1. Audit every internal numeric accessor by call path. Add tests that exact, rerank,
   codec/checkpoint, HNSW build, quantization, batch/GPU preparation and Arrow paths
   preserve values and ownership without populating all public List caches.
2. Integrate v4 mapped numeric records with the same owner/reader; preserve catalog
   identity and field validation. Keep required public owned codec APIs independent.
3. Keep field updates sharing unchanged owners. Encode from the read boundary rather
   than materializing every public List. Public get and explicitly requested owned
   exports may allocate; account for those copies honestly.
4. Verify named/native scalar, binary/sparse unaffected behavior, snapshots across
   updates/close/reopen, Arrow owner/release/slicing and independent fixtures. No
   public List signature or on-disk version change is authorized by this plan.
5. Adopt only after complete relevant recovery/lifetime checks; otherwise retain the
   isolated candidate and report the failing contract without a production fallback.

## Task 5: Capacity and strict performance decision

**Files:** new immutable benchmark/validation artifacts under `.build/`, reports under
`docs/benchmarks/`, ADR 0007, `task.md` and `tasks/todo.md`.

1. Copy the entire source and package for every isolated build. Preserve the production
   binary while workers run. Builds, tests, profiling, benchmarks and compression are serial.
2. Run the smallest mapped recovery/control case first, then the frozen three-corpus
   memory matrix with identical caps, fresh inodes, zero swap, oracle/ef and initial
   residency checks. Retain OOMs and timeouts. Instrumented phases are diagnostics only.
3. Re-run fixed warm/mixed pairings and compare exact IDs/bits/stats/execution. Require
   per-cell Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant; no tolerance, offsets,
   retuning or sample exclusion. Record every pass→fail independently of adoption.
4. Sustained nonresident needs BOTH engines in the same cap/trial to satisfy the
   established last-four-pass faults/mincore criterion. Mapping capability alone is
   not proof that exact query inputs were nonresident.
5. Run relevant full CPU/Python/crash/C/example validation and Linux runtime checks.
   Native Linux performance still needs native hardware; emulation cannot close that
   gate. GPU actual-device checks are required if its actual data path changes.
6. Freeze sources, plans, hashes, all trials and failures; update documented ownership
   and format contracts together. Claim M5/M6 completion only when every required
   cell and environment gate actually passes.

## Validation commands

Use the installed compiler, not current 1.1 documentation APIs:

```sh
rtk proxy pixi run mojo --version
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src tests/mojo/test_numeric_read_view.mojo
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src tests/mojo/test_mapped_numeric_owner.mojo
rtk proxy pixi run test-python
rtk proxy pixi run test-crash
rtk proxy pixi run build
```

The new test filenames are implementation targets and do not exist yet. For isolated
runs substitute the complete copied source/package and route relative AND absolute
child compiler includes; existing validation drivers demonstrate the required audit.
Preserve user changes. One semantic package per commit. Do not delegate to subagents.

## 2026-10-20: Current immutable-owner prototype

[The current-source owner experiment](../research/2026-10-20-immutable-point-owner.md)
implements the narrower immutable-source invariant required above, preserving v4/v5
point semantics, current native scoring and public owned getters. It is isolated
from production `a6822c3`; Tasks 1–4 have partial implementation, not adoption.
The evidence includes 67 distinct archived Mojo cases, six intended negative
compile cases, 10,368 native query audits, 36 reopens and 36 retained Arrow leases.

The cached-range candidate reduces high-dimensional Linux-emulated after-open
anonymous memory by about 50 MiB and passes all 9 short 128 MiB trials plus three
controls. All 3,456 responses and 12 reopens match prior controls. This does not
close sustained capacity. Its native selective QPS ratios are 0.860/0.883/0.915;
other regressions and every individual trial remain recorded. It is not adopted.
The fixed row-alignment control does not explain the whole-query slowdown.

Next compare reader acquisition, scoring and end-to-end selective queries on the
actual recovered MemTable and identical candidate IDs. Preserve the immutable
operation owner and score/error order. Do not retry the old mutable-List reader,
register-passable variant or alignment-only hypothesis unchanged. Then complete
live checkpoint/compaction rebasing, legacy recovery, remaining typed/export/GPU
consumers and destruction/error reporting before full acceptance. No durable
format change is inferred from this experiment. M5/M6 remain open.

The [recovered-row follow-up](../research/2026-10-20-immutable-point-query.md)
now separates actual MemTable traversal from retained mapped-owner and owned-row
scoring. A raw-pointer scoring trial does not remove the gap and is reverted.
Moving the checked immutable Span beside its owner preserves the existing Variant
size and improves same-batch selective QPS 6–9% over the preceding prototype.
Eighteen owner/lifecycle cases and six negative compile probes pass. This is the
next isolated implementation base, not production adoption: a production pass
still becomes a failure and live publication remains incomplete.

The pinned Qdrant wheel is restored and its exact adapter case passes. Across 36
mixed workers, candidate matched quality is 33/36 and quality-plus-speed 18/36
versus production 16/36. All three Akasha variants pass combined write-plus-flush
9/9 in this batch. Proceed to typed live flush/partial-compaction owner rebasing
and retirement/error reporting, using the existing typed-publication design and
current v5/durability contracts. Preserve the unresolved warm, concurrent,
sustained capacity and native Linux gates; do not repeat rejected microchanges.


## Live checkpoint ownership — 2026-10-20

The [isolated live-flush layer](../research/2026-10-20-immutable-point-live-flush.md)
publishes validated mapped numeric owners to PointStore, the collection projection
and matching read runs, retaining old roots and sharing existing run indexes.
Validation covers 77 selected Mojo cases (including two corrected exact-file lease
fixtures), 23 checkpoint/WAL cases and 379 distinct Python cases after correcting
the spawned-client launcher. Original failures remain archived. The candidate
library builds; production stays `a6822c3`, with no new speed or capacity claim.
Next complete shared live authority and mapped publication for foreground,
background and partial compaction, preserving selected-range cutoffs, newer writes,
legacy cutover versions and destruction outside writer. Every strict M5/M6 gate
and the remaining consumer/type/lifecycle requirements stay open.


## Live compaction ownership — 2026-10-20

The [isolated compaction layer](../research/2026-10-20-immutable-point-live-compaction.md)
uses shared PointTable/MemTable authority and validates mapped outputs before
foreground/background/partial publication. Selected-range version cutoffs preserve
later writes; matching read runs keep existing indexes and old readers retain
their exact-file leases. It follows pinned Qdrant's locked publication and deferred
retirement principles within Akasha's current durability protocol. Validation
covers 191 cases in 37 selected Mojo modules, 23 checkpoint/WAL cases, 379
distinct Python cases and a candidate merge with 32 descriptors. Fixture and
implementation failures are retained. Production stays `a6822c3`; full consumer,
type/lifecycle, fixed performance, sustained capacity and native Linux acceptance
remain open. No new speed result or M5/M6 completion is claimed.


## Numeric consumers and fresh failed speed gates — 2026-10-20

The [isolated consumer layer](../research/2026-10-20-immutable-point-consumers.md) applies pinned Qdrant's borrowed-read
boundary to Arrow, Python conversion, GPU upload and legacy recovery. Shared
registry propagation preserves exact-file ownership, and no-op flush now retries
PointStore's pending cleanup. Validation covers 151 cases in 34 CPU modules,
23 checkpoint/WAL cases, 379 Python cases, the candidate C ABI and 12 actual
Metal cases (reused across the subsequent cleanup-only change). Initial
materialization, lifetime-fixture, cleanup and process-runner failures are retained.

The fresh 27-worker mixed comparison audits 7,776 responses, 27 exact reopens and
18 Arrow leases. Production/candidate results, score bits and query statistics
match; both Akasha variants meet all 36 quality cells, while matched quality is
33/36 because Qdrant's three real correlated cells remain below .95. Strict
quality-plus-speed passes are 25/36 production versus 18/36 candidate, with nine
pass-to-fail regressions; combined write-plus-flush passes 9/9 for each. No
threshold or sample exclusions change. Production stays `a6822c3`. Next measure
publication/lock stalls suggested by retained latency spikes, then continue the
fixed performance, sustained capacity and native Linux gates. M5/M6 remain open.


## Publication critical section — 2026-10-20

The [isolated publication experiment](../research/2026-10-20-immutable-point-publication.md) follows pinned Qdrant's separation
of expensive preparation from locked finalization. Instrumented runs identify
repeated point validation and full read-run descriptor copies inside Akasha's
shared query/publication writer lock. Removing only the already completed point
validation reduces median publication holds from 1.80–1.87 ms to 1.33–1.48 ms;
8,224–8,440 read descriptors still copy under writer. This does not implement
Qdrant's full read/update lock separation.

A valid-CRC semantic-corruption regression covers v4/v5 rejection and cleanup.
The unchanged candidate passes 60 cases in ten CPU modules, 23 checkpoint/WAL
cases, 379 Python cases and the C ABI checks. Fresh uninstrumented mixed tests
run 36 serial workers, auditing 10,368 responses, 36 exact reopens and 27 Arrow
leases. Production/prior/candidate strict quality-plus-speed passes are 26/15/20
of 36. Seven production passes and one prior-candidate pass become failures;
all remain recorded. Combined write-plus-flush passes 9/9 for all three variants.
Production stays `a6822c3`, with no adoption or M5/M6 completion. Next move
immutable read-run preparation out of writer while preserving current writes,
snapshot owners and publication checks, then continue all unchanged performance,
sustained capacity and native Linux gates.


## Unlocked immutable read-run preparation — 2026-10-20

The [isolated read-preparation layer](../research/2026-10-20-immutable-point-read-preparation.md) captures immutable run owners,
builds replacement descriptors outside writer, then validates the captured chain
and stages only the current bounded head before publication. New writes and old
snapshots survive; changed chains use the existing conflict/retry protocol.
Four new cases cover interleaving, stale chains, build failure and cancellation.
Validation passes 134 cases in 23 CPU modules, 23 checkpoint/WAL cases,
379 Python cases and the candidate C ABI. Exact source/native identities and all
initial compile failures are archived.

Diagnostic combined lock holds are .776/.901/.825 ms across the three corpora,
with .804/.893/.847 ms of read-run construction now outside writer. However,
waits over 100 microseconds increase from 9/2/6 to 16/7/13 across separate
diagnostic batches, suggesting a cost from two critical sections. Next reduce
capture to shared immutable references and prepare replacements from validated
output while preserving legacy cutover/version rules and final live checks.

The fresh 36-worker comparison audits 10,368 responses, 36 exact reopens and
27 Arrow leases. Production/prior/candidate strict quality-plus-speed passes
are 22/14/18 of 36, with four production and one prior-candidate pass-to-fail
regressions retained. Combined write-plus-flush passes 9/9 for each variant.
Production remains `a6822c3`; the candidate stays isolated. Full warm/concurrent,
sustained nonresident capacity, integration/example and native Linux gates remain
open, with no M5/M6 completion or threshold changes.


## Shared-owner capture from immutable output — 2026-10-20

The [isolated owner-capture layer](../research/2026-10-20-immutable-point-owner-capture.md) removes point traversal and row
projection from the first writer-lock section. Typed replacements use validated
output points; legacy replacements preserve cutover/document versions and existing
sparse/payload owners. Final live-authority validation remains locked. Validation
passes 137 CPU cases in 24 modules, 23 checkpoint/WAL cases, 379 Python cases and
the candidate C ABI. The legacy fixture initially used a foreground capture that
checkpointed away its intended inputs; its original failure and corrected use of
the background capture path are retained.

Diagnostic capture medians are .001 ms and combined holds .569/.638/.632 ms.
Uniform-128 has nine published attempts and one unpublished final attempt whose
original trace does not distinguish cancellation from conflict; output cleanup,
exact reopen and lease audits pass. The analyzer now records all outcomes rather
than requiring every background attempt to publish. No diagnostic worker is
rerun and no acceptance threshold changes. Published-only combined hold for
uniform-128 is .570 ms. Wait counts over 100 microseconds change from 16/7/13 to
7/8/5 across separate diagnostic batches.

The fresh 36-worker comparison audits 10,368 responses, 36 exact reopens and
27 Arrow leases. Production/prior/candidate strict quality-plus-speed passes
are 23/13/16 of 36; seven production and two prior-candidate pass-to-fail cells
remain recorded. Combined write-plus-flush passes 9/9 for each variant. Selective
queries still show publication sensitivity, while other modes spend most native
time in search. Next compare production/candidate native search phases and
separate publication wait costs before choosing the next change. Production stays
`a6822c3`; full warm/concurrent, sustained capacity, integration/example and native
Linux gates remain open. No adoption or M5/M6 completion is claimed.


## Paired native query phases — 2026-10-20

The [paired phase diagnosis](../research/2026-10-20-immutable-point-query-phases.md)
compiles identically instrumented production/candidate kernels and runs twelve
serial workers in balanced paired order. All 3,456 timed responses, 12 exact
reopens and 12 Arrow leases match; all 36 warmups remain recorded separately.
Candidate search-core medians exceed production across all twelve groups,
including 5.25/6.00/6.50 microsecond selective gaps, while filter costs are similar.
Publication waits remain a separate cost. Next evaluate the pinned Qdrant
batch-read/scorer boundary without changing arithmetic, eligibility or lifetimes;
lock shortening alone cannot remove the measured query-core gap. This adds no
product change or acceptance result. The prior strict 23/36 production versus
16/36 candidate result, all regressions and open M5/M6 gates remain unchanged.


## Bounded borrowed-row scoring — 2026-10-20

The [isolated batch-scoring layer](../research/2026-10-20-immutable-point-batch-score.md)
uses the pinned Qdrant 64-row gather boundary in selective exact search. It
retains safe nested borrows, original score pairs and deferred acquisition-error
ordering. No owner copies, numeric materialization, formats, ef or stats change.
68 CPU cases, 379 Python cases and candidate C ABI validation pass. Balanced
phase diagnostics preserve 3,456 responses, 12 reopens and 12 Arrow leases;
selective core medians decrease 6.4%/11.0%/11.6%. Publication waits remain.
The separate 36-worker comparison preserves 10,368 responses, 36 reopens and
27 leases, with strict production/prior/batch results 24/20/21 of 36. Three
production and one prior pass-to-fail cells remain; no regressions are waived.
Carry the core improvement only within the isolated candidate, then address
HNSW authoritative reranking and publication interference. Production stays
`a6822c3`; full warm/concurrent, sustained capacity, integration/example, native
Linux and M5/M6 gates remain open.


## Authoritative HNSW borrowed-row batches — 2026-10-20

The [isolated HNSW batch layer](../research/2026-10-20-immutable-point-hnsw-batch.md)
extends the pinned Qdrant gather/scorer boundary to both authoritative rerank
paths, preserving exact bits, eligibility, error precedence and partial lookup
counters. 113 CPU cases, 379 Python cases and candidate C ABI validation pass.
Twelve balanced diagnostic workers preserve 3,456 responses, 12 reopens and
12 leases. Rerank medians improve 4.2–12.9% in six 1536-dimensional groups but
regress 5.2–6.9% in all three 128-dimensional groups. Reranking is only 8–24%
of prior ANN core time, and publication waits remain a separate cost.
The fresh 36-worker comparison preserves 10,368 responses, 36 reopens and
27 leases. Strict production/prior/candidate results are 24/20/22 of 36, with
two production pass-to-fail cells and no prior pass-to-fail cells in this batch.
Combined write-plus-flush passes 9/9 for all variants. All failures remain,
including Qdrant's three fixed-ef recall failures; no retuning decision is assumed.
Next test the difference between Qdrant's fixed local batch buffer and the
candidate's bounded-capacity List without weakening behavioral checks. The
candidate stays isolated and production stays `a6822c3`. Full warm/concurrent,
sustained capacity, integration/example, native Linux and M5/M6 gates remain open.


## Fixed optional-row buffer rejected — 2026-10-20

The [fixed-buffer experiment](../research/2026-10-20-immutable-point-fixed-batch.md)
replaces pair Lists with local Arrays while preserving semantic checks. It passes
113 CPU cases, 379 Python cases and candidate C ABI validation. Twelve balanced
diagnostic workers preserve all 3,456 responses, 12 reopens and 12 leases, but
all nine rerank aggregates regress 2.8–10.4%. The six high-dimensional groups
regress in both trials; the three low-dimensional groups reverse direction
between trials. The 36-worker mixed comparison preserves 10,368 responses,
36 reopens and 27 leases, with strict production/prior/candidate results 18/16/15
of 36. Five production and two prior pass-to-fail cells remain; combined write
plus flush passes 9/9 for each variant. Reject this Array-of-Optional variant and
continue from the prior HNSW List-batch source. Next inspect Qdrant's initialized-
prefix storage protocol without assuming a cause from these timings. All ef,
quality, lifetime and performance requirements remain unchanged. Production is
still `a6822c3`; no M5/M6 or remaining environment gate is closed.


## Initialized-prefix batch not adopted — 2026-10-20

The [prefix-buffer experiment](../research/2026-10-20-immutable-point-prefix-batch.md)
follows Qdrant's initialized-prefix protocol with checked access, explicit cleanup
and compiler-verified trivial descriptor copying/moving. 114 unique CPU cases,
379 Python cases and candidate C ABI validation pass. AddressSanitizer builds
with an installed compatible runtime, but that runtime spins before main in
macOS dyld/malloc initialization; the stack sample and termination are retained,
and no sanitizer pass is claimed. Twelve balanced diagnostic workers preserve
3,456 responses, 12 reopens and 12 leases; low-dimensional rerank aggregates
improve 3.1–5.6%, with two small high-dimensional regressions retained. Fresh
36-worker mixed results preserve 10,368 responses, 36 reopens and 27 leases,
but strict production/prior/candidate passes are 19/17/14 of 36. Six production
and three prior pass-to-fail cells remain; combined write-plus-flush is 9/9 for
each variant. Do not carry this candidate forward. Stop buffer-layout tuning;
next measure the remaining writer-locked live-owner staging, durable publication
and owner/root exchange, from the prior HNSW List-batch source. Production stays
`a6822c3`; all original performance, ownership and environment gates remain open.


## Head-only compaction projection — 2026-10-20

The [publication-phase and head-projection experiment](../research/2026-10-20-immutable-point-head-projection.md)
starts from the retained HNSW List source, excluding both rejected buffers.
Six initial diagnostic workers locate 18.8–20.9% of publication hold in full
projection/head preparation. The candidate filters head membership and sequence
before cloning descriptors, preserving full authority/head validation and the
unchanged manifest/owner publication order. 140 unique CPU cases, 23 crash
cases, 379 Python cases and candidate C ABI pass. Twelve balanced diagnostic
workers preserve 3,456 responses, 12 reopens and 12 leases; head preparation
falls 58.7–61.1% and writer hold 10.6–17.8% in both orderings. Fresh 36-worker
mixed results preserve 10,368 responses, 36 reopens and 27 leases, with strict
production/prior/candidate passes 22/19/20 of 36 and combined write-plus-flush
9/9 each. Both production and prior lose uniform-1536 trial 0 selective and
real-1536 trial 0 independent; those failures are retained. Keep the isolated
candidate for further work, without production adoption or a completed gate.
Next audit read-root and mutable HNSW query state for Qdrant-style separation
of update exclusion from reader access during durable publication. Production
remains `a6822c3`; ef, all strict gates and pending user decisions are unchanged.

## 2026-10-20: Separate live ANN exclusion from compaction publication

The [query-lock experiment](../research/2026-10-20-immutable-point-query-lock.md) starts from the retained head-projection
source and reuses the October 14 lock experiment after auditing current live
owner replacement. Pinned Qdrant's separate update mutex and short segment
swap motivate the boundary. Six ANN entries use query-only exclusion; 52
foreground scopes acquire writer then query. Compaction keeps writer through
preflight and disk publication, then guards the point/projection/read-root
exchange with query. Snapshot/pin behavior and durable ordering are unchanged.

The parent reproduces the intended progress failure (3 pass, 1 fail); the
candidate passes the four lock tests plus a new manifest-progress/live-owner
barrier. All **145 CPU cases in 27 modules, 23 crash cases in eight modules,
379 Python cases with four native identity processes, and C ABI checks** pass.
No new GPU, sustained-capacity or native Linux result is claimed.

Twelve balanced serial diagnostic workers validate 3,456 timed responses,
12 exact reopens and 12 leases; 36 warmup clock traces are retained separately.
Query exclusion falls **94.6–97.2%**,
from 490–572 µs to 14–31 µs trial medians. Candidate uniform-1536 writer hold
increases to 1.12–1.38 ms while waiting for active queries. Other foreground
APIs and concurrent ANN still serialize; diagnostics do not close that gate.

Fresh 36-worker mixed counts are **production 25/36, prior 22/36, candidate
25/36**; all have matched quality 33/36 and combined write-plus-flush 9/9.
There are **zero production/prior pass-to-fail cells**. All 10,368 responses,
36 exact reopens and 27 Akasha leases pass. Eight speed failures and the three
unchanged real-correlated Qdrant recall failures remain explicit, without
retuning or exclusions. Some aggregate ratios still regress.

Retain the isolated candidate for further work, not production adoption or
M5/M6 completion. Next profile the six uniform-1536 correlated/independent
failures against pinned Qdrant filtered traversal/scoring; the two uniform-128
all-mode and all quality failures remain in the complete matrix. Production
stays `a6822c3`; full warm/concurrent, sustained nonresident capacity,
integration/example and native Linux gates remain open.

The source/test/reference/native/result audit and verified archive contain
**902 text artifacts, 3,239,267 bytes**, SHA-256
`cee93573303bc99ad13b192ffd1f75658b3bdfdf28e480d3da9c67b85202b234`.
Exact frozen plans are referenced by checked hash/key in the parent archive.

## 2026-10-20: Locate remaining filtered-search source costs

The [source-phase/native-sampling diagnosis](../research/2026-10-20-immutable-point-source-phases.md) keeps the query-lock
candidate unchanged. Six instrumented mixed workers preserve all **1,728 timed
responses, six exact reopens and six leases**; 18 warmup clocks are retained
separately. Base search accounts for **73.05% / 73.02%** of uniform-1536
correlated/independent core time. Rerank remains required and costs about one
fifth; delta search is much smaller.

Four serial native captures compare the uninstrumented Akasha and Qdrant
runtimes on two fixed initial-state queries per mode. Eight preflight and eight
postflight responses match each engine's frozen results. Thread-local exclusive
counts locate **11.88–13.95%** of Akasha observations in mapped metadata/readiness
access. Qdrant executes its dense graph scorer and appendable scan; its separate
search-thread denominator is preserved. Sampling is not elapsed-time attribution
or a speed gate. The initial generic-signature heap grouping error is corrected
and retained with its original output.

Next evaluate one copied node-metadata record per gathered target, reusing
ID/level/current while preserving every bounds/close/error/counter contract.
Do not repeat the already rejected base-level-only skip, broad inlining,
header-read removal, adjacency-range reuse or raw borrowed-span variants.
No product source changes or new acceptance claims occur here; the retained
query-lock mixed result stays **25/36** and production stays `a6822c3`.
All full M5/M6, quality, capacity, concurrency and native Linux gates remain open.

Verified evidence: **391 text artifacts, 1,371,349 bytes**, SHA-256
`7784854b5091c9c1e03cb0595d72c7f83ef78d341154a43ca9e830924826e599`.

## 2026-10-20: Reject copied node-metadata buffers

The [two metadata probes](../research/2026-10-20-immutable-point-node-metadata.md)
start from the retained query-lock source. Both retain checked scalar access,
level validation, current-flag behavior, query results and counters. The first
copies metadata even for visited neighbors; the follow-up copies it only for
unvisited neighbors, while still checking every visited target's level.

The first passes **41 cases / five modules** and the follow-up **43 cases / six
modules**. Together, 24 serial mixed workers preserve **6,912 timed responses,
24 exact reopens and 24 Arrow leases**. Warmup returned values are not compared.
Builds/tests and timed workers run serially. Both execution orders are retained.
Uniform-1536 correlated/independent median QPS ratios are **.9823/.9747** for
the first and **.9814/.9815** for the follow-up, each relative to its own paired
query-lock baseline. Neither resolves the target; **both are rejected**.
Production remains `a6822c3`, and the retained query-lock candidate remains Z.

Next inspect deferred public-ID resolution, starting from Z rather than either
rejected buffer. Base source/filtered admission use slot bitmaps and cached
ordinals, so their eagerly supplied public IDs are unused. Pinned Qdrant's
filtered/metric scorers operate on point offsets. Keep the UInt32 candidate
buffer and preserve ID tie order, error/counter contracts and the delta/ID-based
admission paths. No speedup is yet established for this next hypothesis.

The verified archives contain **246 / 243 text artifacts**, SHA-256
`d947653cdbcec47de68ebbd77eecdbfda2aa94ecb56f2825d88fd132052f92a0` and
`076638f8dc93860e59ce7c22f743d2cc2039d707086b42f94af9ef7528b6f9ec`.
There is no new Qdrant acceptance matrix or full CPU/Python/crash/C/Linux run
for these rejected candidates. All remaining M5/M6, quality, capacity,
concurrency and native Linux gates remain open.

## 2026-10-20: Retain deferred public-ID admission

The [deferred-ID candidate](../research/2026-10-20-immutable-point-deferred-id.md)
starts from Z/query-lock. Slot-based graph admission now resolves a public ID
only when the admission implementation requires it. Known-ID delta scans,
fallback and extra-entry heap checks retain their existing operation. The
UInt32 neighbor buffer, graph/mapped accessors, numeric kernels, visited/level
checks, score ties, counters, query locks and durable formats remain unchanged.
Runtime regression tests demonstrate ID reads falling **9→1, 11→4 and 8→1**;
ID-based and delta membership retain the required public-ID resolution.

Final-source validation passes **262 unique CPU cases / 43 modules**, **23
crash cases**, **379 Python cases / four native-identity processes**, and the
C ABI build/tests. Fresh extracted-Qdrant oracles match **98 search fixtures**
on scalar/batched paths and **24 construction fixtures / 2,467 adjacency rows**.
The initial stale test-oracle compile error and its immutable-reader fixture
adaptation are retained in the evidence.

Twelve two-order screen workers and 36 three-order mixed workers audit **13,824
timed responses**, including **11,232 Akasha responses** matching the retained
baseline's IDs/F32 bits/stats/routes/recall/oracles, **48 exact reopens** and
**39 Arrow leases**. Warmup returned values are not compared. Every worker is
serial; all original plans, efs and strict gates remain intact.

The fresh strict comparison is **production 24 / Z 24 / deferred-ID 25 of 36**,
with **zero production/Z pass-to-fail cells**. Quality remains **33/36** and
write-plus-flush **9/9** for each implementation. The old Z 25/36 result is a
different run. Relative to contemporary Z, uniform-1536 correlated/independent
median QPS improves **2.48% / 3.24%**. Numerical control regressions, including
the initial uniform-128 selective regression, are retained.

**Carry the candidate forward; do not adopt it into production yet.** Eight
speed failures and three real-correlated Qdrant quality failures remain. Next
reprofile this retained source against Qdrant to locate the remaining base
search/rerank costs. Full M5/M6 warm, concurrency, nonresident capacity,
integration/example and native Linux gates remain open. Production stays
`a6822c3`.

Verified evidence: **703 text artifacts, 2,718,032 bytes**, SHA-256
`f2b129cf133ec06161b24121751112fcc0a0437ae68c23ef9c0a28f20eeff713`.

## 2026-10-20: Reprofile deferred-ID with resolved native symbols

The [fresh native-sampling diagnosis](../research/2026-10-20-immutable-point-deferred-profile.md)
keeps the retained deferred-ID source and native binary unchanged. Four serial
five-second captures repeat two frozen initial-state queries per mode; eight
preflight and eight postflight responses preserve IDs/F32 bits/stats. These
repetitions are diagnostic observations, not new acceptance samples.

Apple's sample output omits some constrained-generic Mojo function names.
Resolving their PCs against the exact binary's symbol table, with every printed
offset checked, corrects an initial admission undercount. Current admission
shares are **8.35%/7.98%**, not the initial **.37%/.60%**. Metadata shares are
**9.80%/9.78%** versus prior **13.95%/11.88%**. Mapped scoring and authoritative
pair scoring remain substantial frames; these shares do not establish elapsed
cost, speedup or equivalent cross-engine work.

Pinned Qdrant sources again confirm filter-before-cap/reusable-score-buffer and
slice-based dense batch scoring. Next inspect the exact candidate's generated
mapped-score loops before choosing a bounded-read optimization, retaining score
bits, authoritative rerank, error precedence and close/bounds ownership checks.
Do not repeat rejected raw-borrow, copied-buffer or broad-inlining probes.

The last strict mixed result remains **25/36**, production remains `a6822c3`,
and no M5/M6, quality, warm, concurrency, capacity or native Linux gate closes.
Verified evidence contains **83 text artifacts, 725,566 bytes**, SHA-256
`0f5e9346c8af6ddca2487eeebace29293a9e62683cbe6c53c0ddc73e00292aa7`.

## 2026-10-20: Reject scoped mapped F32 loops

The [scoped mapped-score probe](../research/2026-10-20-immutable-point-mapped-loop.md)
starts from deferred-ID and changes one existing graph file plus one private
compute module. It validates whole row extents, then consumes local unaligned
pointers synchronously and returns only copied scores. It exports no mapped
reader or raw-pointer factory. Admission, traversal, authoritative rerank,
formats and publication ownership remain unchanged.

The candidate passes **117 cases / 16 modules** and all **3,456 timed responses,
12 exact reopens and 12 leases** in a serial two-order mixed screen. Warmup
returns are not compared. Exact-binary disassembly confirms that the main
width-16 dot loops shrink from **22→13 / 61→31 instructions**, with only the
loop backedge remaining as a branch. Both kernels are inlined; this is not a
failure to eliminate the intended checks.

Nevertheless, uniform-1536 correlated/independent median paired QPS ratios are
**.9904/.9957**, and p95 ratios **1.0295/1.0086**. There is no consistent target
improvement. **Reject this candidate and keep deferred-ID as the parent.**
Do not infer equivalent elapsed savings from static instruction counts or
declare memory bandwidth the cause without measurements. Next inspect actual
memory-access and candidate working-set behavior before another arithmetic
rewrite. The rejected candidate receives no fresh strict Qdrant or broad
acceptance run. Production stays `a6822c3`; the retained mixed result stays
25/36, and all open M5/M6 requirements remain active.

Verified evidence: **522 text artifacts, 1,397,273 bytes**, SHA-256
`e376a4442a7581201025fec5411a97220d9f1d05bde67189ef8b6ba6c9b00b5c`.

## 2026-10-20: Full mixed access traces and rejected admitted prefetch

The [CPU-counter comparison](../research/2026-10-20-immutable-point-memory-profile.md)
contains eight valid five-second captures of the unchanged deferred-ID and
Qdrant binaries. Both search threads overwhelmingly use performance cores.
Akasha does not have a larger critical-L1D-idle fraction in these short,
two-query captures. Separate thread/core fractions do not establish the cause
of the full mixed performance gap.

The [full mixed access trace](../research/2026-10-20-immutable-point-access-trace.md)
then replays all three frozen corpora. All **864 responses, three exact reopens
and three retained leases** pass. Diagnostic row counts agree with the actual
search/rerank statistics; nine warmup returns are not compared. Applying the
pinned Qdrant sequential heuristic to Akasha slots admits only **23/152,656**
multi-row chunks. Virtual-address range coverage is not cache-miss, physical-page
or nonresident evidence. Keep the two-query counter and full-workload trace
conclusions separate.

A [first-address prefetch candidate](../research/2026-10-20-immutable-point-admitted-prefetch.md)
issues hints only after filter compaction and cap, unlike the old all-neighbor
probe. It passes **71 CPU cases / nine modules**, all **3,456 screen responses,
12 exact reopens and 12 leases**, and emits the intended native `prfm` instruction.
However, uniform-1536 correlated/independent QPS is lower in both execution
orders, and real-correlated p95 is higher in both. **Reject this candidate;
deferred-ID remains the parent.** No dimension exception or gate change is added.

Next inspect per-candidate metadata/admission work against Qdrant's direct
bitmap checks, preserving current-slot classification, closed mapping behavior,
error precedence, result bits and stats. Do not repeat rejected all-neighbor
prefetch, this first-address variant, neighbor tail pairs or copied node metadata.
Production remains `a6822c3`, strict mixed remains **25/36**, and all unresolved
quality, warm, concurrency, capacity, integration/example and native Linux gates
remain required for M5/M6 completion. Both linked reports include complete
verified archives and reproduction scripts.

## 2026-10-22: Reject non-raising current predicates in both code shapes

The [bounded current-predicate experiment](../research/2026-10-22-immutable-point-current-predicate.md)
compares a private non-raising mapped-byte predicate with retained deferred-ID,
then adds one explicit `@no_inline` control. Both final sources preserve early
open/slot checks, byte bounds and exact flag equality; neither substitutes live
counts or source membership for actual current flags.

Each variant passes the same **89 CPU cases / 12 modules**. Across both screens,
all **6,912 timed responses, 24 exact reopens and 24 retained leases** pass.
Seventy-two warmup returns are not compared. All raw-latency QPS/p95 summaries
and medians independently reproduce, including from the archive alone.

The automatic variant inlines `is_current` and regresses both uniform-1536
filtered targets in both execution orders. The outlined function shrinks from
95 to 23 total instructions, removes its 144-byte frame and all calls, and
preserves a call from the inspected scorer. Nevertheless, reverse-order target
p95 ratios are **1.0657 / 1.0485**, with other control regressions retained.
Removing this error path is not a stable end-to-end improvement. **Reject both
variants; deferred-ID remains the parent.**

Next inspect repeated admission checks against Qdrant query-local filtering,
preserving stats, cancellation/error precedence and current-source semantics.
Do not repeat these predicates, copied node metadata or base-level skipping
without new evidence. Production remains `a6822c3`, strict mixed remains
**25/36**, and every outstanding quality, warm, concurrency, sustained capacity,
integration/example and native Linux requirement remains open. The resumed
driver was confirmed terminal; no timed work was restarted.

Verified evidence: **542 text artifacts, 2,161,696 bytes**, SHA-256
`459372123f84619a4a571b7aacb77784ca4b850160f78081d9c4cc94796fab1f`.

## 2026-10-22: Reject Qdrant's identity-store compaction guard

The [stable-compaction experiment](../research/2026-10-22-immutable-point-stable-compaction.md)
copies the pinned Qdrant `Rest::Discard` rule: write a retained candidate only
when its position changes. One source file changes; filtering/check order,
visited semantics, rejection counters, caps and all scoring remain unchanged.
The source review also confirms that ordinary Qdrant traversal rechecks rejected
points; it does not justify adding rejection memoization to Akasha.

The candidate passes **64 CPU cases / seven modules**, all **3,456 timed
responses, 12 exact reopens and 12 retained leases**. Thirty-six warmup returns
are not compared. Disassembly confirms the conditional store, and an archive-only
replay independently reproduces every reported QPS/p95 ratio and median.

Uniform-1536 independent QPS declines in both orders (**.9091 / .9968**), as do
both uniform-128 filtered QPS values. The untouched selective controls also vary;
all observations are retained without causal attribution or exclusion.
**Reject this candidate; keep deferred-ID.** Next inspect the complete
scorer/admission call boundary and repeated state passing against Qdrant batch
checks, retaining cancellation, stats and first-error behavior.

Production remains `a6822c3`; strict mixed remains **25/36**, with all existing
M5/M6 requirements open. Verified evidence: **276 artifacts, 1,025,038 bytes**,
SHA-256 `6a17a62d7b5680d054fafd5005a365d441e1b31bb252f4b7ecbf0a66927e7277`.

## 2026-10-22: Reject compile-time source admission after full comparison

The [static-source experiment](../research/2026-10-22-immutable-point-static-source.md)
specializes the existing fixed base/delta selector while preserving raising
checks, error order and live shared-state semantics. It changes one source file
from retained deferred-ID and passes **67 CPU cases / eight modules**. The
admission callee shrinks **225 → 165 instructions**, but its explicit `0x870`
stack reservation remains; the inspected scorer grows **1,000 → 1,043**.

Both orders of the initial screen improve the high-dimensional filtered modes.
The fresh full comparison instead regresses correlated/independent QPS in
**all three trials**, by roughly **6–8%**. Production/retained/candidate strict
counts are **20/21/22 of 36**, with no pass-to-fail cells. The additional passing
cell does not justify these target regressions. **Reject the candidate and
retain deferred-ID.** Its latest count is now **21/36**, with **12 speed and
three quality failures**; the previous **25/36** is historical, not current.
Quality remains **33/36** and write/flush **9/9** for all three implementations.

All **11,232 Akasha responses** across the screen/full comparison match exactly;
the protocols contain **13,824 total timed responses, 48 reopens and 39 leases**.
The 144 warmup returns are not compared. A separate four-worker full-plan CPU
diagnosis passes **1,152 responses, four reopens and four leases**, with another
12 warmup returns not compared. It reproduces a **7–10% calling-thread CPU
increase** in the filtered targets. Zero reported per-query major faults does
not exclude cache, paging or other memory effects; global VM activity and the
post-run host observation remain separate, without causal attribution.

Next profile the complete frozen mixed workload on these exact unchanged
binaries to locate the additional CPU cost. Do not infer elapsed gains from
static instruction counts or repeat small scorer/admission changes without new
evidence. All original M5/M6 quality, warm, concurrency, sustained capacity,
integration/example and native Linux gates remain open. Production stays
`a6822c3`; no ef, tolerance, workload or sample selection changes.

Archive-only replay independently reproduces both raw-result audits. Verified
evidence: **417 artifacts, 2,679,540 bytes**, SHA-256
`5f35728b900cad7cc986060e9cf931d93c3e662773ce0b97f1efd7969ba21704`.

## 2026-10-22: Full mixed profiles do not reproduce the filtered regression

The [complete-plan profiling diagnosis](../research/2026-10-22-immutable-point-full-mixed-profile.md)
captures both unchanged binaries in both orders, eight fresh-clone plans per
capture. All **9,216 responses, 32 reopens and 32 leases** pass. An additional
four fresh unsampled single-plan controls pass **1,152 responses, four reopens
and four leases**. The combined 108 warmup returns are not compared.

Every full plan finishes within the sampling window. The analyzer resolves
**4,674 non-stub native frame records** with PC/offset checks and conserves each
thread's exclusive counts. Initial parser failures for other truncated generic
names and alternate explicit main-thread labels are recorded and corrected
without restarting workers. Visible mapped filtered-search ancestry is useful;
inlining/tail calls prevent claiming exhaustive base/delta/rerank phase costs.

The previous **7–10% filtered CPU regression does not reproduce**. Sampled
candidate/retained filtered CPU ratios are **.9760/.9775** and **.9815/.9783**;
fresh unsampled single-plan ratios are **.9648/.9634** and **.9959/.9867**. The
unsampled worker/module are byte-identical to the prior diagnostic. This neither
explains the earlier failure nor invalidates it. Keep both datasets and the
static-source rejection; no candidate is adopted from these observations.

Before more local performance edits, establish a reproducible failing execution
under controlled conditions. Continue the independent adoption audit, including
all child compiler include paths: Python native import identity does not prove
candidate-source compilation in subprocess tests. Retained strict mixed remains
**21/36**, production stays `a6822c3`, and all original M5/M6 gates remain open.

Archive-only analysis and audit reproduce exactly. Verified evidence: **108
artifacts, 2,845,584 bytes**, SHA-256
`fd4dd6bcfa1c3acb9aa6e23157a2362073e597513d9d7ac47b4a677fc26b142b`.

## 2026-10-22: Close retained Python child-compiler source ambiguity

The [child-compiler audit](../research/2026-10-22-immutable-point-child-compiler.md)
confirms that the previous retained driver checked Python native imports but
did not redirect repository-source paths in Mojo subprocess tests. An isolated
wrapper now records and routes those arguments to the unchanged 132-file
retained candidate, without changing tests or target flags.

The fresh complete suite passes **379 tests / 23 Python modules**. All **15
suite compiler invocations** are audited: **14 use candidate source**, and one
is a stdlib-only generic-target probe. Four Python processes verify the native
identity. An additional relative-include invocation passes six existing owner
cases; the same candidate-only fixture fails against production because its
private module is absent. Those replayed cases are not new unique coverage.

The initial direct-Python launch missed Pixi activation and failed to locate
`std` in 14 tests. Its full failure is retained; the complete rerun under
`pixi run python` passes. Source/package/native bytes remain unchanged, and the
archive-only audit reproduces all command routing and outcome checks.

This closes that specific candidate-source validation gap. Existing runnable
examples/integration, performance, sustained capacity and native Linux gates
still need their own evidence. Retained strict mixed remains **21/36**;
production remains `a6822c3`, and M5/M6 remain incomplete.

Verified evidence: **64 artifacts, 103,004 bytes**, SHA-256
`7af7ac40dded50da83b4384f9f1baa8657476e06af921b674c9e3b6660729f8f`.

## 2026-10-22: Existing examples, multiprocess integration and CI smoke quality

The [local integration audit](../research/2026-10-22-immutable-point-example-integration.md)
passes all **3 runnable Mojo examples**, **10 distributed tests** with **26 native
identity checks**, and **11 × 4 post-HNSW modes / 528 measured queries**, all with
final recall 1.0. Six HNSW smoke datasets also report recall 1.0; that original
program does not assert a threshold. No tests are claimed for the integration
README or placeholder Python examples.

Two isolated benchmark consumers needed explicit MemTable-owner dereferences.
The query-stage CLI also used the obsolete v1-only config reader; the repository
benchmark now uses the same field-catalog loader as the engine. Both retained
and production builds pass twelve private/public result comparisons after
reopening separately created current-format databases. Initial compilation,
runtime and wrapper-assertion failures remain archived.

This closes the existing local example/integration and smoke-quality checks,
not full adoption. Audit all remaining Mojo consumers next: **262 prior cases
were a subset**, not the complete **166-module repository suite**. Retained
engine bytes and production `src` are unchanged; strict mixed is still **21/36**.
Performance, sustained capacity, native Linux and the remaining M5/M6 gates
remain open. Archive-only replay verifies **165 artifacts, 153,329 bytes**,
SHA-256 `005fc5892ea48547182a920ab8f59f1e7bed1c4748e5ad180eb35c9fc421c2e1`.

## 2026-10-22: Complete repository Mojo CPU coverage

The [complete CPU audit](../research/2026-10-22-immutable-point-full-cpu.md)
now covers **166 modules / 1,095 tests**, with zero final failures or skips:
**138 modules / 885 tests freshly executed**, plus **28 modules / 210 tests**
reused only after verifying unchanged archived source and successful logs.
The original test function names and counts are checked for every module.

Three additional private callers needed adaptation: checkpoint retention must
outlive the writer lock, and two HNSW oracle callers must pass numeric readers.
Two differently named owner-aware fixtures also needed mapping back to their
repository module names. Their six cases had already passed and are not new
unique coverage. All initial runner, compile and immediate-deletion assertion
failures remain archived. Each fresh module executes in a separate process;
the file-lease child-reader protocol is preserved without adding runner args.

This completes the local full Mojo CPU validation requirement for the unchanged
retained engine, alongside the existing Python, crash, C ABI, examples and
multiprocess results. Production `src` is unchanged from `a6822c3`. The latest
strict mixed count remains **21/36**; no performance, sustained-capacity,
native-Linux or actual-device GPU gate is inferred from CPU correctness.
M5/M6 remain incomplete.

Archive-only replay verifies **2,693 artifacts, 3,291,203 bytes**, SHA-256
`4ba8a87f063da1ef47df66d787626be1307f80d13660aed8d98bea41ae5aa86d`.

## 2026-10-23: Explicit acceptance decisions

The user authorized exactly one calibration change: Qdrant's
`real-1536 / correlated` search uses **ef=128** for the next complete comparison,
instead of 96. Preserve all original plans and failed trials. Create separately
identified plans and rerun the complete matrix; do not substitute diagnostic
timings into earlier trials. Every other engine parameter, workload, sample and
strict per-cell Recall@10 ≥ .95, QPS ≥ Qdrant, p95 ≤ Qdrant requirement is
unchanged. This is the sole authorized exception to Task 5's frozen-ef rule.

The user also deferred native Linux x86_64 acceptance because no test machine is
available. Record that environment as **not evaluated, deferred by the user**;
it is outside the current local acceptance scope and must not be reported as
passed. Continue all local correctness, performance and sustained-capacity gates.

The [complete rerun and ordinal-read experiment](../research/2026-10-23-immutable-point-ordinal-bounds.md)
now records **production 25 / retained 26 / candidate 26 of 36** strict mixed
cells, with all 36 quality cells and nine update-plus-flush comparisons passing
for each version. The candidate gains one cell and loses another, so neither
tested ordinal-read version is adopted. Both pass 70 targeted cases; all 10,368
measured responses in the full four-version matrix retain their expected exact
IDs/bits/stats/routes. Earlier ef=96 failures and both diagnostic probes remain
separate. The new score must not be presented as an implementation improvement.

Retained's ten failures include all six uniform-1536 filtered cells and all three
real-1536 correlated cells. Continue measuring and reducing filtered-search work
under the established live-admission and deterministic ordering contracts.
Warm, concurrent and sustained nonresident gates remain open. Production `src`
is unchanged from `a6822c3`; M5/M6 remain incomplete. Archive-only replay verifies
737 expanded artifacts, 18,717,248 bytes, SHA-256
`ac3169d074d8aa528900c0a2554e07fd1642e517531bfc8c8f70bea9d23a158d`.

### 2026-10-23 complete fixed-graph warm and external-client replay

The [local matrix](../research/2026-10-23-immutable-point-local-matrix.md)
finishes all 54 serial workers: 36/36 quality cells at each boundary, but only
9/36 strict warm, 8/36 one-client and 12/36 four-client cells. The warm phase
uses the full original ef grid and each trial's frozen graph; it does not rerun
index construction. The authorized Qdrant real correlated ef=128 applies, with
every other selected parameter unchanged. Both engines use the same HTTP shim.
All 129,024 measured responses are audited; full-grid warm IDs/recalls match
the frozen reports, and concurrent replies match selected warm IDs/F32 bits.
Archive-only replay verifies 317 artifacts and reproduces the audit exactly.
These completed measurements remain failed acceptance gates. The retained
engine is unchanged; sustained nonresident capacity and M5/M6 remain open.

### 2026-10-23 native profile, bulk truncation and selective GC

The [List.shrink experiment](../research/2026-10-23-immutable-point-list-shrink.md)
profiles all 64 frozen real-correlated queries in four serial captures, then
tests Qdrant-style one-call truncation using the installed standard-library API.
One function changes. All 135 relevant cases and 124,416 measured responses
pass; same-batch mixed improves 29/36 to 32/36 without pass-to-fail. Full warm
instead drops 11/36 to 10/36, with two gains and three prior selective losses.
Do not adopt or advance this candidate; retain the weak-certificate parent.

A complete-driver GC diagnostic audits another 12,288 responses. Both binaries
collect generation 0 at selective ef10 ordinal24, producing a shared 103–112 us
pause. The p95-determining queries have no GC, and instrumented paired timings
do not reproduce a stable candidate regression. This does not explain or excuse
the original failure. No sample is excluded or GC disabled. All nine frozen
graph vector sections already start on a 64-byte boundary, so a format-alignment
rewrite is also unjustified for these inputs. Preserve all evidence; investigate
selective native/wrapper phase costs and remaining real-correlated scoring.
Current thresholds, authorized ef selection, native-Linux deferral and all open
integration/client/capacity gates remain unchanged.

### 2026-10-23 weak immutable-value score certificates

The [score-certificate candidate](../research/2026-10-23-immutable-point-score-certificate.md)
uses Mojo 1.0's existing WeakPointer to recognize the same live immutable vector
owner after an initial bounded byte/finite proof. Only proven F32 Dot/L2 base
pairs reuse scores carried through the same query. Weak certificates retain
neither vector payloads nor mapped files. Replacements, expired owners and base
source changes require a new proof; query scores are never cached across queries.

135 targeted cases pass, including same-sequence replacements, nonfinite error
precedence, owner exchange and mapped-file reclamation. The same-batch full
mixed comparison improves prior 24/36 to candidate 28/36 without pass-to-fail.
Full fixed-graph warm stays 12/36: one uniform-1536 independent gain and one
uniform-128 selective loss. Both quality matrices pass all 36 cells; mixed
write-plus-flush passes all nine. Across 84 serial workers, 124,416 measured
replies preserve IDs/F32 bits/stats/routes. The complete raw evidence and all
failures are independently reproducible from the text archive.

Keep the isolated candidate for follow-up, without production adoption or a
full-acceptance claim. Diagnose the low-dimensional selective slowdown and
remaining real correlated cost; broader integration, clients and sustained
nonresident capacity remain open. The authorized Qdrant ef=128 exception is
unchanged. Native Linux remains deferred. Earlier rejected stateless byte-proof
results below remain valid; cross-query proof reuse is a different design.

The [selective follow-up](../research/2026-10-23-immutable-point-certificate-selective.md)
uses eight serial workers and 8,192 measured responses before/after ANN priming.
It does not consistently reproduce the low-dimensional slowdown; individual
regressions remain visible. The driver differs from full warm report allocation
and serialization, so no causal explanation or revised acceptance follows.
Keep the formal failure and isolate those conditions before changing exact code.

### 2026-10-23 score reuse feasibility

The [score-reuse diagnostic](../research/2026-10-23-immutable-point-score-reuse-proof.md)
rejects per-query exact byte comparison before reusing graph scores: all 48
paired cases regress, with median time ratios 1.38–1.68. A separate scoped
authoritative pair-kernel probe improves 128D synthetic cases but not 1536D
consistently. It passes 22 relevant cases; six paired workers retain every raw
observation. Neither implementation is integrated. Complete evidence and an
archive-only audit preserve both decisions and setup failures. Continue from
the adjacency candidate below; no acceptance gate changes. Avoid repeating a
full byte-scan proof or treating pointer/sequence identity as value identity.

### 2026-10-23 scoped mapped adjacency candidate

The [synchronous adjacency gather](../research/2026-10-23-immutable-point-neighbor-gather.md)
changes three source files and follows Qdrant's bounded adjacency iteration.
It keeps target slot/level checks, first-error/partial-output order and live
visited semantics; only copied IDs leave the mapping borrow. No ownership,
format, score or ef change is introduced.

104 targeted cases pass, plus fresh candidate comparisons against 98 existing
pinned Rust search fixtures and 24 build fixtures / 2,467 adjacency rows.
Both mixed screen orders improve all nine ANN modes in QPS and p95. The full
mixed quartet improves retained 21/36 to candidate 26/36, without pass-to-fail;
all quality and combined write/flush comparisons pass. Full fixed-graph warm
improves 11/36 to 12/36 but includes uniform-128 selective trial 0 pass-to-fail.
That exact path does not call the changed gather, but the timing cause remains
unresolved and the failed gate is retained.

Across both screens and complete mixed/warm comparisons, all 96 workers and
127,488 measured replies preserve expected IDs/F32 bits/stats/routes. Keep the
candidate isolated for follow-up and proportionate broader validation; do not
claim production adoption or M5/M6 completion. Current source/binary identities,
all failures and independent replay are frozen with the report. External-client,
sustained-capacity and final performance acceptance remain open; native Linux
remains explicitly deferred by the user.
