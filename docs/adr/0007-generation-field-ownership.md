# ADR 0007: Immutable read generations and independently owned fields

Date: 2026-09-07. Status: **accepted design for the next implementation slices**.
Engine baseline: `234547a`. This ADR does not make the current engine share snapshots.
Current capture still clones MemTable/SparseIndex and rebuilds metadata.

## Evidence and constraints

- [Snapshot costs](../research/2026-09-07-generation-costs.md) measure zero/small delta,
  equal manifest generation with different accepted sequences, and eight live views.
- Current source: `ReadSnapshot.capture`, `PersistentCollection._snapshot_unlocked`,
  `_apply_batch_unlocked`, `_snapshot_for_gpu`, `backup_to`, and `_maintenance_entry`.
- Qdrant local `reference/qdrant/lib/shard/src/optimize.rs`, `build_new_segment`
  (line 222), `finish_optimization` (line 480), and final swap (line 573): retain
  readable inputs, build outside update locks, reconcile and publish briefly.
  `segment_manifest.rs` separates readable, building and retiring states.
- RocksDB `reference/rocksdb/db/snapshot_impl.h`, `SnapshotImpl::number_`: snapshot
  visibility belongs to an accepted sequence, not just an on-disk version.
- Existing dependencies suffice: official Mojo `ArcPointer`, `List`, `Dict`,
  origin-tracked `Span`, current worker shim, PyArrow C Data and NumPy views.
  No custom reference counter, hash table, Arrow parser or async scheduler.

## Identity and publication

A read view is identified by `(collection instance, view revision)`, with immutable
`accepted_sequence`, `manifest_generation`, `schema/config fingerprint` and layout
identity recorded in its root. The collection instance is a fresh in-memory token
on open. View revision increases whenever visible data **or ordinal/buffer layout**
changes. A sequence does not increase merely because compaction changes layout.

The cached root may be reused for repeated captures with no writes or layout change.
Two roots at the same manifest generation can have different accepted sequences.
Two physical layouts at the same sequence must not share ordinal-indexed caches.
Never use `ArcPointer.__eq__` as allocation identity; that compares contents. Use
the root token (or official `is` for a local identity assertion).

Writers keep the existing single-writer lock and WAL commit ordering. Prepare and
validate all entries of an atomic dense batch before WAL append/fsync. Publish its
complete latest-state update and accepted sequence together under the lock; capture
sees only the state before or after the envelope. Sparse writes keep their existing
individual accepted sequence. Current Arrow dense+sparse ingestion is not a combined
atomic batch. This ADR introduces no new durable atomicity claim.

## Authoritative ownership and bounded delta

Use one immutable base owner, immutable sealed delta owners, and a bounded mutable
head containing latest point-state **descriptors**, all behind the existing writer
lock. A point state consists of ID, sequence, tombstone and independently owned dense,
payload and sparse field references. Published field buffers are immutable. A sparse
update can keep the old dense/payload owners; it does not copy their bytes. A delete
masks all fields, and a later reinsert cannot inherit fields from before the delete.
Ordinals are local to one layout. IDs remain the public cross-generation identity.

On capture, reuse an unchanged root; otherwise freeze a copy of just the head's
descriptors/lookup, sharing their field owners and all base/sealed owners. Copying
an `ArcPointer` increments its count; moving accepted lists into a field owner does
not copy their buffers. The mutable head itself is never shared. Initial limits are
1,024 changed point descriptors or 4 MiB of newly owned field content, whichever is
reached first; rollover moves the head into a sealed delta and starts an empty head.
An already-valid larger single record gets its own run, rather than a new rejection
or split-record commit. These are implementation constants, not new public knobs.

After eight sealed deltas, schedule one bounded merge through the existing worker.
If a producer outruns merge, apply backpressure before accepting another rollover;
do not let an unbounded chain accumulate or drop an acknowledged mutation. Drain and
retry are outside the writer lock. A merge error surfaces through the existing
maintenance failure mechanism. Later tuning requires measured read/write curves.
The implementation sequence first delivers a callable foreground in-memory
consolidation primitive in #48, keeping the chain bounded and the system usable.
#52 schedules that same primitive through the worker; the intermediate #48 slice
does not claim to eliminate consolidation writer stalls. It is not a second data
format or a parallel legacy visibility path.

The root owns its head snapshot, base, sealed runs and exact file lease. It does not
own an O(all-points) copied lookup or full replacement mask per capture. Lookup probes
head then sealed runs newest first, then base. During scans, suppress an older row
if a newer point state exists, including tombstones, **before** filtering or Top-K.
Shadowing applies to the whole point state so dense/payload/sparse cannot come from
different logical rows. An updated field can still reference an older immutable
field buffer through the new point state. Never take base Top-K and only then remove
shadowed hits, which could lose the actual winners.

Metadata/sparse indexes belong to each immutable run and its ordinal layout. The
small captured head can evaluate fields/sparse values directly until rollover builds
its indexes. This avoids rebuilding full metadata or sparse indexes at capture.
Sparse products accumulate in ascending query-term order, retaining current Float32
behavior and ID ties. CPU exact/filtered/sparse/hybrid and GPU preparation must use
the same root visibility resolver; no independent live-table lookup inside a query.

## Field boundary and vector types

The internal field descriptor is `(field_id, kind, scalar_type, dimension/shape,
metric, schema_revision)`. Initial legacy slots are one default dense F32 field and
one sparse field; this assigns internal identities without changing persisted bytes.
IDs, row validity/tombstones and payload belong to point state, not vector coordinates.

| Kind | Owned representation and borrowing boundary |
|---|---|
| Dense F32 now | Contiguous F32 field buffer + row location/length. A delta buffer may hold one row; base/merged runs can pack many rows. Borrow a row as readonly Span. |
| Payload now | Owned typed fields/strings; sharing is separate from dense bytes. Materializing an owned public document remains a copy. |
| Sparse now | Owned I64 term IDs and F32 weights with row offsets; ascending unique terms and finite nonzero weights. |
| Native scalar later | Explicit F16/BF16/F32/I8/U8 dtype, dimension, metric and conversion/accumulation policy; HNSW storage encoding does not establish authoritative support. |
| Binary later | Packed bytes plus logical bit dimension/padding rule and Hamming/Jaccard contract. Dot/cosine must not silently reinterpret bits. |
| Multivector later | Row/subvector offsets plus component field buffer, shape checks and MaxSim aggregation; named vectors are independent fields, not implicitly MaxSim. |

Absent field, empty sparse vector, zero dense vector and deleted point are different
states. Missing named field produces no candidate for that field; partial update
changes only named fields, while delete removes the point. The legacy upsert behavior
must remain documented when mapped into the catalog. Do not add a generic Any/opaque
buffer storage framework before the next concrete type is implemented.

Named fields and a combined multi-field atomic operation require a separately
versioned catalog/WAL/segment contract, reader-first migration, old fixtures, unknown
version rejection and crash tests. Retain v1/v2/v3 compatibility requirements. The
implementation cannot emit a new format until its migration slice is accepted and
all readers of that format are implemented. This ADR alone changes no files on disk.

## Leases, close and typed borrows

Use official strong owners for memory and explicit captured-file leases for files.
Generation pins alone do not own memory or mappings. A file lease pins a specific
manifest/config/file set; a field/export/operation owner keeps its backing allocation
or mapping alive. Record all referenced files before releasing the publisher lock.

The [compiled probe](../research/2026-09-07-generation-owner-probe.mojo) verifies moving
base/delta buffers, shallow root handles, distinct sequences and an exported field
owner after all collection/snapshot owners are released. It uses readonly Span only
inside synchronous accessors and retains a local operation owner for that access.

**Mojo 1.0 limitation:** origin annotations alone do not prevent explicit early
release through an owning wrapper. A compile-only counterexample using a returned
Span followed by wrapper close or explicit move was accepted by this toolchain.
It was not executed. Do not publish a bare retained Span API or claim the compiler
enforces all handle-close cases. ArcPointer also does not synchronize pointee mutation.

Acquire a separate operation owner under the handle/collection lock before a query
leaves it. No operation mutates a sealed buffer. The operation retains that owner
through CPU work or GPU completion/readback; all Span uses end inside that scope.
A scanner batch/Arrow array has its own strong owner held by C Data release state.
Snapshot/collection close may drop their reference, but cannot invalidate the batch.
An Arrow slice retains its parent's owner through PyArrow. Gather, cast and filtering
may allocate new buffers; reference those buffers from an export owner and count them.

Collection close first rejects new operations, then cancels/drains maintenance without
holding the writer lock, drops collection/cache owners and releases the writer file
lock. Existing explicitly acquired snapshots/exports keep their own roots and remain
usable. Snapshot close is idempotent and drops that wrapper's root immediately; an
already-created export/operation owns an independent lease. Destruction performs the
same release. Last owner releases mappings/device buffers; last relevant file lease
allows unlink. Expose pin/retired/cache bytes and oldest retained sequence, with no
automatic TTL that silently invalidates a user's view.

## Build, publish and retirement

Lifecycle: `active inputs → pinned build inputs → building output → validated ready
output → published root/manifest → retired inputs → reclaimed`. Failure/cancellation
before publication discards only the new output; old inputs remain readable.

For disk compaction, capture manifest generation G, committed sequence H, config and
exact input descriptors/checksums under the writer lock. Pin them, then merge/write/
fsync outputs outside it. Allocate job-unique output names with exclusive creation;
never overwrite a captured/committed input, and clean up only that job's outputs.
Concurrent foreground/background builds and restart orphan cleanup must test this
namespace rule. The manifest already permits safe arbitrary file names, so this
requires no new on-disk schema. On publication, require the current manifest/config to
match the captured inputs and generation. A concurrent WAL-only write is allowed:
keep all current head/sealed data with sequence > H when constructing the new root.
Do not rotate or truncate those newer WAL records. If another flush/compaction changed
the manifest, discard this output and reschedule; do not overwrite its manifest.
The first version uses strict compare-and-publish, not an unverified append-only
manifest rebase. Bound retries and measure conflict rate; a build cannot hold the
writer lock to avoid conflict. Full-coverage tombstone elision retains its existing
rule. Publish durable manifest before in-memory root, and queue replaced inputs for
lease-aware retirement. Recovery uses the committed manifest if interrupted between
those steps. Orphan cleanup cannot unlink a live in-process pinned input.

Backup first checkpoints/captures the exact manifest and config/file set under the
writer lock. Copy that set outside it, holding source leases and target writer lock.
Use bounded buffers, per-file temp+fsync+rename and manifest-last publication. Do not
unlock then reload a newer manifest. The backup is independently reopenable after the
source is closed/deleted; default copy semantics do not introduce shared mutable
inodes. Optional derived files are either copied with their captured metadata or
explicitly omitted from the backup's manifest; required data must be complete.

## Derived indexes and device ownership

SQ8/PQ/HNSW build artifacts carry root/layout identity, field/config fingerprint,
metric, codec/training parameters and source coverage. `absent/building/ready/failed`
are separate states. Queries reuse ready artifacts; PQ training never runs on every
query after its lifecycle slice. A failed/stale new artifact cannot replace ready
state. Current authoritative exact behavior remains available by the documented
query policy; do not introduce hidden new fallbacks.

HNSW publication checks captured field/schema/config and reconciles newer accepted
mutations using its existing incremental update semantics in a bounded catch-up.
If catch-up cannot fit the publication budget, reschedule from a newer root; never
publish a graph missing accepted updates. Disk checkpoint metadata stays tied to
committed source data, independently of a newer in-memory graph.

GPU cache is keyed by root/layout + field/config + device and retains the root owner.
Keep current budget, one-context reuse, ragged candidates and readback lock semantics.
Scratch is mutable per operation or synchronized cache; authoritative buffers are
immutable. Dropping one snapshot must not destroy another operation's GPU state.
No new GPU ANN or cross-vendor claim follows from this CPU ownership work.

## Rejected alternatives and validation mapping

| Alternative | Reason rejected |
|---|---|
| ArcPointer around mutable live MemTable | Reference counting does not provide isolation or synchronized pointee mutation. |
| Deep COW clone of all data on every write/capture | Preserves the measured full-base cost. Share immutable fields and bound head work instead. |
| All updates as an unbounded linked delta chain | Read and root-management costs grow indefinitely; use bounded head, rollover, merge and backpressure. |
| Manifest generation as the only cache key | WAL-only writes and layout-only publications make it insufficient. |
| Returning Span while allowing unrelated close/reallocation | Compiler probe shows ownership must be held explicitly per operation/export. |
| Release writer lock without a publication predicate | Can lose a newer manifest or accepted tail. |
| Implement all vector dtypes before sharing F32 | Delays the largest current cost; field boundary is enough for staged implementation. |

| Invariant | Existing evidence to preserve | New regression assigned below |
|---|---|---|
| Full-point visibility and owned get | `test_snapshot.mojo`, `test_concurrency.mojo` batch boundaries | #47–#49: equal G/different S, tombstone/reinsert, pointer-sharing and sparse/payload-only updates |
| Bounded capture and delta lifetime | This cost harness and owner probe | #48: rollover, oversized point, merge backpressure; capture does not clone base bytes |
| Snapshot/export survives parent close | Existing snapshot/Arrow tests | #50/#58: close during acquired operation, exported arrays after all parent handles close |
| Pins and last-owner reclamation | `test_maintenance.mojo`, snapshot pin/RAII tests | #51/#52: lock-free build with concurrent writes/flush, last release, cancellation and worker failure |
| Durable publication and recovery | `tests/crash/test_checkpoint_order.mojo`, sparse checkpoint, batch atomicity | #51/#53: output fsync/manifest/root-publication/cleanup crash boundaries and stale build |
| Backup exact captured generation | `test_storage_operations.mojo` | #53: concurrent source flush/compact, bounded RSS, independent restore and corrupt source |
| Index freshness and reuse | Quantization/HNSW checkpoint/rebuild tests | #54–#56: build-once counters, full cache keys, failed build keeps old artifact, mutation catch-up |
| GPU owner/budget correctness | Current CPU GPU-policy tests and 9 prior real-device tests | #50: rerun affected real-device close/budget/freshness tests when GPU ownership is changed |
| Typed buffer bounds and ownership | #45 real Python/Mojo Arrow tests | #57/#58: output pointer/release/slice, filtered gather copied-byte accounting |

Execution dependencies and file-sized work packages are in [tasks/todo.md](../../tasks/todo.md).
Matched-recall Qdrant baseline is independent and starts before claiming speed parity.
