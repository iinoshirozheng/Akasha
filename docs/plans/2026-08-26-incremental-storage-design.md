# Phase 10: Incremental Storage and Compaction Design

## Scope

Replace full-snapshot-on-every-flush storage with an ordered immutable segment
set, leveled compaction, safe tombstone collection, and bounded automatic
maintenance. Dense documents, typed payloads, sparse state, metadata rebuild,
and existing adapters must retain their current behavior.

## Durable model

Manifest v2 contains the collection dimension, generation, checkpoint sequence,
and an ordered list of segment descriptors. Each descriptor records level,
minimum and maximum sequence, checksum, and a validated file name. Manifest v1
decodes as one level-1 base descriptor so existing collections upgrade on their
next checkpoint.

Segment v3 adds a kind flag. A base segment is a complete sorted live snapshot.
A delta segment stores the latest state changed since the prior checkpoint,
including tombstones. Entries are sorted by point ID, and every entry sequence
lies inside the descriptor's sequence interval. Recovery validates every
descriptor and applies base/delta entries oldest to newest before WAL replay.
The in-memory MemTable remains authoritative after recovery.

Sparse state follows the same checkpoint generation. During the first format
transition it remains a complete checksummed snapshot associated with the
manifest checkpoint sequence; the manifest verifies its descriptor explicitly.
Sparse deltas are introduced before Phase 10 is declared complete so dense and
sparse write amplification are both bounded.

## Checkpoint and crash ordering

1. Freeze the checkpoint sequence and collect changed states.
2. Write and fsync temporary dense and sparse delta files.
3. Atomically rename each file and fsync the collection directory.
4. Publish and fsync the replacement manifest containing old and new files.
5. Rotate dense and sparse WALs.
6. Schedule compaction or reclaim only files absent from the committed manifest.

A crash before step 4 leaves unreferenced files that recovery ignores. A crash
after step 4 may retain pre-checkpoint WAL records; sequence filtering prevents
double application. Cleanup is restricted to names parsed from previously valid
manifests.

## Compaction

Level 0 holds bounded delta segments. When its segment-count or byte threshold
is crossed, compaction merges all selected inputs by point ID and sequence.
The newest entry wins. A full compaction that covers the only base and all older
deltas may discard tombstones; partial compaction must retain them. The output
is fsynced, a new manifest generation atomically replaces the input descriptors,
and input files are deleted only after publication and snapshot-pin checks.

The initial scheduler exposes deterministic synchronous `compact()` and
`maintenance()` operations, and `flush()` invokes the same operation after four
L0 generations. The long-lived worker is coupled to Phase 11 snapshot pinning
and concurrency ownership: it must call the same operations, surface failures
through public operations, and join during `close()` without reclaiming a
reader-pinned generation.

## Validation

- Manifest v1 compatibility and v2 corruption/bounds tests.
- Segment v1/v2 compatibility and v3 base/delta/tombstone tests.
- Multiple flushes reopen correctly without rewriting old segments.
- Replace/delete/reinsert across segments preserves the newest sequence.
- Full compaction preserves query results and safely removes tombstones.
- Crash tests cover every publication boundary and retained WAL window.
- Sparse/dense checkpoints cannot open at mismatched generations.
- Compaction never removes stray or currently referenced files.
- Existing exact, HNSW, metadata, sparse, hybrid, Python, and HTTP tests remain
  green.

## Measured development baseline

`pixi run bench-compaction` generates paired 10K/100K base-plus-1%-delta
workloads and measures the production segment codec, real
`PersistentCollection.open()`, and compacted-base rewrite. On the Phase 10
development machine, delta/base encoded bytes were 1.009% at 10K and 1.001% at
100K. Reopen cost was about 0.69 microseconds per recovered record at both
sizes after recovery switched to linear ID-ordered MemTable merging and HNSW
became a lazy derived cache. The benchmark fails if delta amplification reaches
5% or 100K per-record reopen cost exceeds eight times the 10K baseline.
