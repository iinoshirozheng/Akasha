# Phase 11 Snapshots, Concurrency, and Batch Implementation Plan

**Goal:** Add stable snapshots, generation-safe reclamation, atomic batches,
bounded parallel query execution, and safe maintenance ownership.

**Architecture:** Snapshot reads use owned frozen state plus a shared generation
pin. Writers remain serialized through one WAL-first collection core. Batch WAL
v3 envelopes provide crash atomicity. Parallel work is scoped and joined before
an API call returns.

**Tech Stack:** Mojo stable, Pixi, ArcPointer, BlockingSpinLock, versioned binary
codecs, CRC32, Mojo TestSuite, subprocess crash tests.

---

### Task 1: Immutable owned read snapshots

1. Add failing tests for `get`, exact metrics, filters, payload ownership, and
   stability across live mutation and reopen boundaries.
2. Add a MemTable owned clone and a `ReadSnapshot` API.
3. Capture sequence/generation and derived metadata without sharing mutable
   collection state.
4. Export the API and run focused persistence/filter tests.

### Task 2: Generation pins and retired-file reclamation

1. Add failing tests proving compaction retains files used by a live snapshot.
2. Add an ArcPointer-backed locked pin registry and retired-generation queue.
3. Release pins on explicit close and RAII destruction.
4. Reclaim only unpinned, non-manifest files and test reopen/close windows.

### Task 3: WAL v3 atomic batch envelope

1. Add codec tests for round-trip, limits, checksum, torn tail, and v1/v2
   compatibility.
2. Encode one contiguous sequence range and bounded mutation list per envelope.
3. Recover complete batches atomically and repair only an incomplete final
   envelope.
4. Add crash-window tests.

### Task 4: Atomic batch mutation API

1. Add validation-first sequence/WAL invariants and mixed upsert/delete tests.
2. Append+fsync one envelope before applying the batch to live indexes.
3. Update metadata/HNSW/sparse invalidation once per successful batch.
4. Export Mojo and Python batch types.

### Task 5: Deterministic batch query API

1. Add sequential-oracle equivalence tests for all metrics, filters, and ties.
2. Validate a batch against one immutable snapshot.
3. Add a bounded scoped-worker path with deterministic output ordinals.
4. Benchmark 1/8/64 query batches and retain a small-batch sequential path.

### Task 6: Writer ownership and concurrency stress

1. Protect mutable collection core state with one stable-runtime lock.
2. Add stress tests for concurrent snapshot reads and serialized writers.
3. Verify monotonic sequence allocation, no torn live state, and deterministic
   snapshot results.

### Task 7: Engine-owned maintenance lifecycle

1. Add threshold wakeup, bounded pending-work, failure propagation, close/join,
   and synchronous fallback tests.
2. Implement only against a compiling public stable primitive or explicit
   native-thread shim; do not depend on private async runtime APIs.
3. Route work through the same compaction operation and pin registry.

### Task 8: Phase verification and documentation

1. Update architecture, consistency, query model, README, and Python docs.
2. Add snapshot/batch/concurrency/maintenance benchmarks.
3. Run unit, Python, crash, build, smoke, example, format, and benchmark gates.
4. Commit only after every Phase 11 invariant has direct evidence.
