# Mapped Numeric Ownership Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Lower durable numeric-vector residency without changing public List APIs, accepted query results, immutable-file lifetime or v1–v4 bytes.

**Architecture:** Keep immutable field ownership in PointState/VectorValue. A numeric field is either an accepted owned List or a checked row in an independently owned, leased immutable mapping. Internal scoring/encoding reads the stored row directly; an explicit public List accessor materializes one immutable owned List on first use and never replaces it.

**Tech Stack:** Project Mojo 1.0.0 (`ed45d567`), official ArcPointer/Span/BlockingSpinLock, existing MappedFile/file leases, existing Python/C/Arrow APIs. No new dependencies.

---

## Status and established requirements

This is the implementation direction, not an adopted storage change. Production engine
remains `6d01819`; current HEAD also contains diagnostic records. User authorization is
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
