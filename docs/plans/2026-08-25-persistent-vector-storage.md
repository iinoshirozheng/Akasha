# Persistent Vector Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a durable single-writer vector collection using a pure Mojo WAL,
MemTable, immutable snapshot segment, and atomic manifest.

**Architecture:** Mutations are fsynced to a versioned checksummed WAL before
entering the MemTable. Flush publishes a complete live snapshot and then an
atomic manifest. Open restores the snapshot and replays only newer WAL records.

**Tech Stack:** Mojo 1.0.0 stable, Pixi, Mojo standard library file/path APIs,
thin POSIX `fsync`, `std.testing.TestSuite`.

---

### Task 1: Binary codec and CRC32

**Files:**
- Create: `tests/mojo/test_storage_checksum.mojo`
- Modify: `src/akasha/storage/checksum.mojo`

1. Add CRC32 known-vector tests plus little-endian integer and Float32 round trips.
2. Run the focused test and verify failure because the codec does not exist.
3. Implement owned byte encoding, bounds-checked decoding, and CRC32.
4. Re-run the focused test and require all cases to pass.
5. Commit as `feat: add storage binary codec and crc32`.

### Task 2: Latest-state MemTable

**Files:**
- Create: `tests/mojo/test_memtable.mojo`
- Modify: `src/akasha/storage/memtable.mojo`

1. Add tests for insert, replacement, tombstone, sequence ordering, and live scan.
2. Run the focused test and verify failure because `MemTable` does not exist.
3. Implement latest-state ownership and deterministic live entry access.
4. Re-run the focused test and require all cases to pass.
5. Commit as `feat: add latest-state memtable`.

### Task 3: Durable write-ahead log

**Files:**
- Create: `tests/mojo/test_wal.mojo`
- Modify: `src/akasha/storage/filesystem.mojo`
- Modify: `src/akasha/storage/wal.mojo`
- Modify: `docs/formats/wal-format.md`

1. Add tests for upsert/delete encoding, append/replay, torn tail, checksum corruption, and dimension mismatch.
2. Run the focused test and verify failure because WAL APIs do not exist.
3. Implement versioned records, strict parsing, append+fsync, and replay.
4. Re-run the focused test and require all cases to pass.
5. Commit as `feat: add durable binary wal`.

### Task 4: Immutable snapshot segment

**Files:**
- Create: `tests/mojo/test_segment.mojo`
- Modify: `src/akasha/storage/segment.mojo`
- Modify: `docs/formats/segment-format.md`

1. Add snapshot round-trip, ordering, checksum, truncation, and dimension tests.
2. Run the focused test and verify failure because segment APIs do not exist.
3. Implement versioned snapshot encoding/decoding and checksums.
4. Re-run the focused test and require all cases to pass.
5. Commit as `feat: add immutable snapshot segments`.

### Task 5: Atomic manifest publication

**Files:**
- Create: `tests/mojo/test_manifest.mojo`
- Modify: `src/akasha/storage/manifest.mojo`
- Modify: `src/akasha/storage/filesystem.mojo`
- Modify: `docs/formats/manifest-format.md`

1. Add manifest round-trip, checksum, version, missing segment, and atomic replacement tests.
2. Run the focused test and verify failure because manifest APIs do not exist.
3. Implement binary manifests and temp-file/fsync/rename/directory-fsync publication.
4. Re-run the focused test and require all cases to pass.
5. Commit as `feat: add atomic storage manifest`.

### Task 6: PersistentCollection integration

**Files:**
- Create: `tests/mojo/test_persistent_collection.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/storage/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`

1. Add tests for create, upsert/search, replacement, delete, flush/reopen, WAL-only recovery, snapshot-plus-WAL recovery, and dimension mismatch.
2. Run the focused test and verify failure because `PersistentCollection` does not exist.
3. Compose WAL, MemTable, Segment, Manifest, SIMD metrics, and bounded Top-K.
4. Re-run focused and storage tests and require all cases to pass.
5. Commit as `feat: add persistent vector collection`.

### Task 7: Crash harness, documentation, and full verification

**Files:**
- Create: `examples/persistent_collection.mojo`
- Create: `tests/crash/test_wal_tail.mojo`
- Modify: `pixi.toml`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/consistency-model.md`

1. Add runnable persistence example and crash-tail recovery harness.
2. Document durability guarantees, limitations, and Phase 4 boundary.
3. Format all changed Mojo files.
4. Run focused storage tests, `pixi run test`, `pixi run build`, `pixi run smoke`, the persistence example, and crash harness.
5. Inspect `git diff --check` and commit as `docs: complete persistent storage phase`.

