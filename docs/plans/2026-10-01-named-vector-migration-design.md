# Named-vector authority and migration

Status: catalog metadata specification, fixtures and standalone codec are
implemented and verified; point/WAL/segment records and runtime migration remain
in progress. Production collection writers still emit v1 identity. This is the next slice of the
[complete single-node goal](2026-09-30-complete-single-node.md), not a replacement
for native scalar, binary, multivector or M5/M6 requirements.

## Current constraints established from callers

- `collection.bin` v1 is a closed, immutable, 60-byte identity. Its scalar tag
  describes HNSW encoding; authority remains F32. New authority dtype cannot be
  inferred from that tag. See `storage/collection_config.mojo` and its format.
- `PersistentCollection.open_with_config` resolves this identity before reading
  the manifest, segments, dense WAL and sparse WAL. Identity publication and WAL
  repair are deferred until all recovery preflight succeeds. Preserve that order.
- `MemTableEntry` owns independent dense, payload and optional sparse owners.
  Descriptors share these owners through snapshots. `set_sparse` does not advance
  the dense entry sequence; sparse persistence currently has its own sequence
  stream. A unified point mutation cannot reuse the dense sequence alone as its
  freshness or incremental-checkpoint criterion.
- The existing `BatchMutation` and WAL v3 envelope contain dense vector/payload
  updates or point deletes only. Calling `upsert_sparse` after a successful dense
  batch does not extend its atomic commit. New combined mutations need one envelope.
- Legacy segment v3 stores a complete latest dense/payload state for each point
  included in a delta; sparse state is paired separately by the manifest. New
  field data must participate in compaction, backup, recovery and retirement,
  rather than being placed in an unreferenced side file.
- Existing exact scans, snapshots and HNSW paths assume a default dense vector
  at each live point. Named-only points require explicit field-presence filtering
  before ranking; fabricating a default zero vector would break that requirement.
- `formats/segment-format.md` is a stale placeholder. The current detailed
  contract is `docs/formats/segment-format.md`, corroborated by the v1/v2/v3
  implementation. Use the latter while defining migration and reconcile the pointer.

## Reference evidence and alternatives

The local Qdrant reference is pinned at
`74f3e85b9473c62560006c043e13737ce6b48412`. Its
`lib/edge/src/config/vectors.rs` separates per-vector size, distance, datatype and
index options. `lib/segment/src/data_types/named_vectors.rs` uses a small named
map with concrete dense/sparse/multivector variants and owned/borrowed boundaries.
`lib/shard/src/update/vectors.rs` distinguishes partial updates of existing points
from point insertion. These are useful boundaries; its Rust containers and storage
formats are not dependencies for Akasha.

Use one point authority with independently owned fields, as ADR 0007 requires.
Separate collections per vector name would introduce independent sequences,
snapshots and commits and would not implement the required atomic point semantics.
An unversioned catalog beside an unchanged v1 `collection.bin` is also unsuitable:
the legacy reader would not know it must reject writes to the extended collection.

The selected direction is a versioned collection identity carrying the field
catalog, a single field-aware WAL envelope, and field-aware immutable point
segments. The existing default dense configuration remains distinguishable from
per-field authority dtype. Extend concrete typed representations one type at a
time; do not add an opaque universal buffer/plugin abstraction.

## Semantics to preserve in the wire contract

1. Field identities are stable across reopen, checkpoints and compaction. Names
   select catalog entries; each entry fixes kind, dimension/shape, metric and
   authority dtype. Index encoding is separate. Existing F32 and sparse states
   receive deterministic legacy identities without reinterpreting their bytes.
2. A point owns payload plus zero or more present vector fields. Absent field,
   empty sparse vector, zero dense vector and deleted point remain distinct.
   Searches exclude points missing the selected field before Top-K. A named-only
   point must not allocate or persist a fabricated default dense vector.
3. Partial field updates preserve all unmentioned fields and payload. Explicit
   field deletion removes only that field. Point deletion clears every field;
   reinsertion cannot resurrect older field owners. Existing legacy upsert and
   sparse-update validation behavior remains documented and tested.
4. A combined point mutation validates every field, payload and operation before
   writing one checksummed envelope. All its field changes share a commit/sequence
   boundary and one read-state publication. A torn envelope exposes none of its
   mutations; invalid later fields must not persist an earlier dense update.
5. Incremental segments contain complete latest point states, not unversioned
   field patches that depend on a retired base. Unchanged field memory owners can
   still be shared while building those records. A point's sequence advances on
   every accepted field/payload mutation, including sparse-only changes.
6. Ready derived indexes bind field identity, authority/schema identity and the
   existing root/config identity. A field-only write invalidates affected derived
   state without copying other field contents. Query, Arrow and GPU consumers
   keep independent strong owners using the established operation boundary.

## Migration decision and required proof

The new identity must reject legacy writers before accepting any field-aware WAL
record. Merely publishing a new manifest or silently adding a catalog file is not
sufficient. A v2 `collection.bin` provides this guard because v1 readers reject
unknown versions and lengths. New readers must first be able to interpret the new
identity together with all currently supported legacy segments and WAL records.

An upgrade must fully preflight the old collection, establish deterministic field
mapping and accepted sequence, then publish the new identity with the existing
temp-file/fsync/rename/directory-fsync protocol. A crash before identity publication
leaves old authority; a crash after it must reopen the same accepted state through
the new reader, even if no new field mutation or checkpoint has happened. Corrupt
legacy sparse data must prevent identity publication and dense-tail repair just as
it does today. Failure after rename is a potentially committed publication, so an
idempotent retry must finish durability rather than replace a different identity.

The catalog header, field IDs/tags, limits and legacy cutover metadata now have a
[wire contract](../formats/field-catalog-format.md), independent fixtures and a
verified codec. WAL envelope and segment layouts still need their specification,
fixtures and record readers. Do not enable a writer or call this migration complete
before those decisions and the reader-first tests are implemented. In particular, mixing
legacy dense/sparse replay with field-aware records must have one explicit ordering
contract; do not append new sparse writes to the legacy sparse WAL after switching
combined authority.

## Catalog reader checkpoint (2026-10-01)

The metadata slice passes 10 new catalog tests and 28 existing config/storage
migration tests. It preserves v1 bytes and rejects unknown or corrupt metadata,
including CRC-valid invalid descriptors. File loading does not select a temporary
identity, publish an upgrade or repair a WAL. Both the decoder and file-reader
tests were observed failing without their implementations. See
[validation and scope](../research/2026-10-01-field-catalog.md).

The two new source modules are not yet imported by production collection open.
This separation keeps new writers disabled until field-aware records and recovery
are complete. The type-matrix fixture validates metadata only, not full type support.

Additional caller facts for the record slice:

- `PersistentCollection._validate_vector` rejects non-finite F32 values before
  append. Preserve that public write rule; do not tighten historical low-level
  codec compatibility merely by adding a new field decoder.
- `validate_sparse` currently rejects empty vectors as well as duplicate/negative
  terms and non-finite/zero weights. Keep the legacy sparse-upsert API's behavior;
  define any new empty-field representation separately from absent/delete.
- Legacy sparse checkpoints/`SparseRecord` do not retain a latest mutation sequence
  per point. Recovery merges WALs in accepted order, with sparse ties before dense
  deletes, then drops sparse state for non-live dense points. The new record model
  must define the migration state at cutover explicitly rather than inventing a
  historical sparse sequence. Preserve legacy `DocumentRecord.sequence` semantics
  when defining the new point-wide accepted sequence and legacy read projection.

## Point record checkpoint (2026-10-01)

The [complete point record contract](../formats/point-record-format.md) now
defines the independent point and legacy document sequences, migration watermark,
empty/absent/deleted states, typed field bodies and pure mutation semantics.
The model and codecs are implemented, with six independently generated fixtures
and 19 new tests. Together with 21 existing catalog/payload/sparse cases, all
40 targeted tests pass. See [validation](../research/2026-10-01-point-records.md).

`VectorValue` owns concrete F32/BF16/F16/I8/U8 Lists through the pinned standard
Variant, with separate sparse, packed-binary and multivector arms. `PointState`
shares immutable field owners. The transition prepares a new complete state;
it does not append a WAL or publish authority. The point record has no standalone
CRC: its future versioned envelope must bind the catalog and verify CRC before
accepting it. No runtime or binding imports these modules yet.

Migration anchors point state at C, preserves each legacy document sequence D,
and does not consume a new user sequence. Future named/sparse-only updates leave
D unchanged; changing default dense or payload advances D. Without default dense,
D is zero and the legacy document projection is absent. New point APIs still
need to expose named-only/payload-only points and searches still need typed oracles.

## Next implementation boundaries

1. Define the field-aware WAL patch envelope and complete-state segment envelope,
   including catalog binding, CRC, sequence ordering and independent fixtures.
   Reuse the verified field-body/point codecs, preserving all old readers.
2. Integrate bounded envelope acquisition and mixed legacy/new replay. Test complete
   and every torn-envelope boundary before any new-format writer is selected.
3. Integrate point field owners, accepted sequences and complete-state checkpointing,
   then migration publication and combined writes. Cover snapshot isolation,
   delete/reinsert, append failure and every migration/checkpoint crash seam.
4. Expose named-F32 APIs/search/reopen, Python/Arrow bindings and per-field index
   selection. Verify independent dimensions/metrics, missing fields, filters and
   public owned-read behavior against independent exact results.
5. Extend the same verified contracts to F16/BF16/I8/U8, packed binary and ragged
   multivectors, with their own numeric/shape/oracle and durability gates. Complete
   M5/M6 and final branch integration after the full support matrix is verified.
