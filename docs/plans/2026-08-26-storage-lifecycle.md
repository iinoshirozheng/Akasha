# Phase 5: Storage Lifecycle Implementation Plan

**Goal:** Make the single-node collection safe for one writer, bound WAL growth at checkpoints, and reclaim superseded snapshot segments without weakening crash recovery.

## Invariants

- At most one live `PersistentCollection` owns a collection directory for writing.
- `close()` releases ownership deterministically; process exit releases it through RAII.
- A successful `flush()` leaves the manifest pointing at a durable complete segment.
- The WAL is replaced only after the new manifest is durable.
- Recovery tolerates the crash window where the new manifest is durable but the old WAL remains.
- Only the segment referenced by the previous valid manifest may be reclaimed.

## Task 1: Collection ownership lock

1. Add failing tests for exclusive acquisition, release, and automatic release.
2. Add a stable `collection.lock` file backed by a non-blocking advisory exclusive lock.
3. Export only the storage-internal lock type needed by `PersistentCollection`.
4. Run the focused lock test.

## Task 2: Persistent collection lifecycle

1. Add failing tests proving a second open is rejected and reopen succeeds after `close()`.
2. Acquire the lock before reading manifest/WAL state.
3. Add idempotent `close()` and reject data operations after close.
4. Update existing reopen tests and examples to close the previous owner explicitly.
5. Run all persistent collection/document/filter tests.

## Task 3: WAL checkpoint rotation

1. Add failing tests for atomic WAL replacement with an empty durable file.
2. Implement rotation through `wal.bin.tmp`, atomic rename, and directory sync.
3. Run focused WAL tests.

## Task 4: Checkpoint ordering and segment reclamation

1. Add tests proving `flush()` empties the WAL and preserves recovery.
2. Add tests proving a later flush removes only the previously referenced segment.
3. Add a crash-window test with a published snapshot and retained old WAL.
4. Implement ordered segment publish -> manifest publish -> WAL rotation -> old segment cleanup.
5. Run storage, persistent, and crash tests.

## Task 5: Documentation and delivery

1. Document the single-writer consistency model and checkpoint state machine.
2. Run the full Mojo/Python suite, crash tests, build, smoke, and persistent example.
3. Commit, fast-forward merge to `main`, remove the worktree, and push.
