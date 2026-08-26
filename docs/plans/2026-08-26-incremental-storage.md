# Phase 10 Incremental Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add backward-compatible incremental segments, crash-safe compaction,
and bounded automatic maintenance to the Mojo storage engine.

**Architecture:** Manifest v2 references ordered base/delta segment descriptors.
Flush appends changed entries as a delta and compaction atomically replaces a
covered set with a merged base. WAL and MemTable remain authoritative, and old
files are reclaimed only after manifest publication.

**Tech Stack:** Mojo stable, Pixi, versioned binary codecs, CRC32, filesystem
fsync/rename, Mojo TestSuite, subprocess crash tests.

---

### Task 1: Manifest v2 segment descriptors

**Files:**
- Modify: `src/akasha/storage/manifest.mojo`
- Modify: `tests/mojo/test_manifest.mojo`
- Modify: `docs/formats/manifest-format.md`

1. Add failing tests for a multi-segment manifest round trip, malformed level
   and sequence ranges, duplicate/path-like names, checksum corruption, and v1
   decode compatibility.
2. Run `mojo run -I src tests/mojo/test_manifest.mojo` and confirm the new API
   is missing.
3. Add `SegmentDescriptor`, manifest generation and descriptor list fields, v2
   encoding/decoding limits, and a v1-to-v2 in-memory conversion.
4. Run the focused test and existing manifest tests.
5. Document the exact v2 byte layout and commit.

### Task 2: Segment v3 base and delta records

**Files:**
- Modify: `src/akasha/storage/segment.mojo`
- Modify: `tests/mojo/test_segment.mojo`
- Modify: `tests/mojo/test_segment_v1_compat.mojo`
- Modify: `docs/formats/segment-format.md`

1. Add failing tests for v3 base/delta round trips, tombstones, sequence bounds,
   stable point ordering, truncation, and v1/v2 compatibility.
2. Verify the failures are caused by the absent v3 API.
3. Implement explicit base/delta kinds and tombstone encoding while retaining
   the old decoders.
4. Run focused segment tests and format checks.
5. Document and commit.

### Task 3: Incremental MemTable checkpoint extraction

**Files:**
- Modify: `src/akasha/storage/memtable.mojo`
- Modify: `tests/mojo/test_memtable.mojo`

1. Add failing tests for extracting all point states newer than a sequence,
   including deletes and deterministic point-ID ordering.
2. Verify RED.
3. Implement owned `entries_after(sequence)` and checkpoint watermark
   validation.
4. Verify focused and existing MemTable tests, then commit.

### Task 4: Multi-segment recovery

**Files:**
- Modify: `src/akasha/api/collection.mojo`
- Modify: `tests/mojo/test_persistent_collection.mojo`
- Modify: `tests/mojo/test_persistent_documents.mojo`

1. Add failing reopen tests with a legacy base plus multiple deltas containing
   replace/delete/reinsert operations.
2. Verify RED.
3. Load and validate every manifest descriptor in sequence order, apply segment
   entries, then replay only newer WAL records.
4. Verify exact/document/metadata recovery tests and commit.

### Task 5: Incremental checkpoint publication

**Files:**
- Modify: `src/akasha/api/collection.mojo`
- Modify: `tests/mojo/test_persistent_collection.mojo`
- Modify: `tests/crash/test_checkpoint_order.mojo`

1. Add failing tests proving a later flush appends a delta, preserves the base,
   rotates WAL, and ignores unreferenced partial output.
2. Verify RED.
3. Publish delta files and Manifest v2 in the documented fsync order.
4. Extend crash-window coverage and verify it.
5. Commit.

### Task 6: Sparse incremental checkpoints

**Files:**
- Modify: `src/akasha/storage/sparse_store.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `tests/mojo/test_sparse_storage.mojo`
- Modify: `tests/mojo/test_persistent_sparse.mojo`
- Modify: `tests/crash/test_sparse_checkpoint_order.mojo`
- Modify: `docs/formats/sparse-format.md`

1. Add failing sparse delta and cross-generation validation tests.
2. Verify RED.
3. Add versioned sparse delta files, manifest descriptors, ordered recovery,
   and crash-safe publication.
4. Run focused recovery/crash tests and commit.

### Task 7: Leveled compaction and tombstone GC

**Files:**
- Replace: `src/akasha/storage/compaction.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Create: `tests/mojo/test_compaction.mojo`
- Modify: `tests/mojo/test_persistent_collection.mojo`

1. Add failing merge-policy tests and end-to-end query equivalence tests.
2. Verify RED.
3. Implement deterministic newest-sequence merge, safe tombstone retention,
   manifest replacement, and post-commit input reclamation.
4. Add threshold-driven `maintenance()` and explicit `compact()` APIs.
5. Run focused tests and commit.

### Task 8: Automatic maintenance worker

**Files:**
- Create: `src/akasha/storage/maintenance.mojo`
- Modify: `src/akasha/api/database.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Create: `tests/mojo/test_maintenance.mojo`

1. Add failing lifecycle tests for threshold wakeup, failure propagation,
   synchronous fallback, and deterministic close/join.
2. Verify RED.
3. Implement the bounded engine-owned worker using the Mojo stable threading
   API selected by a compiling spike; discard the spike before implementation.
4. Run lifecycle and lock tests and commit.

### Task 9: Phase verification and documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/consistency-model.md`
- Create: `benchmarks/mojo/compaction_bench.mojo`
- Modify: `pixi.toml`

1. Add a 10K/100K write-amplification, reopen, and compaction benchmark.
2. Run `pixi run test`, `pixi run test-crash`, `pixi run build`, `pixi run
   smoke`, persistent examples, format checks, and the benchmark.
3. Inspect compatibility and crash-ordering requirements one by one.
4. Update documentation with measured behavior and remaining Phase 11 boundary.
5. Commit only after all gates pass.
