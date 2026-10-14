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
