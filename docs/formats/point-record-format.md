# Field-aware point records

Status: reader-first implementation. This defines complete point records and
typed field bodies for the new segment/WAL work. Existing collection writers
still use their published legacy formats. This document alone does not enable
runtime migration, atomic durable writes or named-vector search.

All integers and scalar bit patterns are little-endian. Field IDs, kinds,
dimensions and authority dtypes come from the immutable
[v2 catalog](field-catalog-format.md). An enclosing durable envelope must bind
that catalog's revision and CRC, carry its own format version and verify its
CRC before accepting any contained record. A point record has no independent
CRC. A well-formed scalar bit change cannot be detected by this codec alone.

## Visibility and sequence

A live point owns a payload and zero or more present vector fields. Missing
fields, a present empty sparse field, a zero-row multivector and a zero-valued
dense vector are distinct. Dense and binary dimensions must be positive. A
named-only or payload-only point has no fabricated default dense field.

Each accepted point mutation has a positive point-wide `sequence`. Combined
field/payload changes share that sequence. A separate `document_sequence`
preserves the old default-dense/payload read API: changing default dense or
replacing payload advances it, while named/sparse-only changes preserve it.
It is zero without default dense, otherwise positive and at most `sequence`.
Legacy `get` returns no document for a live point without default dense; the
new point API must expose that point's actual fields and payload.

Legacy sparse snapshots lack per-point mutation sequences. Migration anchors
each migrated complete point state at the accepted cutover watermark C and
preserves its actual legacy document sequence D. C is an explicit migration
snapshot watermark, not a reconstructed sparse update time. Migration does not
allocate a new accepted user sequence. Field-aware mutations must have sequence
greater than C; new complete records have sequence at least C. No per-field
historical mutation sequence is invented or stored.

## Complete point record

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | u32 | Total record bytes, including this 40-byte header |
| 4 | u8 | State: live=1, deleted=2 |
| 5 | u8 | Flags, zero |
| 6 | u16 | Reserved, zero |
| 8 | i64 | Point ID |
| 16 | u64 | Point-wide sequence |
| 24 | u64 | Legacy document sequence |
| 32 | u32 | Present vector-field count, at most 1,024 |
| 36 | u32 | Payload byte length |
| 40 | bytes | Existing payload-v1 encoding, followed by vector entries |

Each vector entry is `field_id:u32, body_length:u32, body:bytes`. IDs must be
known to the catalog, unique and strictly increasing. Gaps are permitted.
No bytes may trail the final field body. Record size is bounded to 256 MiB;
an enclosing WAL additionally bounds the sum of its mutations and overhead.

Live payload uses the existing payload-v1 rules, including its 16 MiB limit.
An empty payload has a four-byte zero field count. A tombstone has no fields
or payload bytes, zero document sequence, and exactly 40 bytes. A tombstone in
a base segment will be rejected by the segment layer; complete delta segments
retain it until compaction can prove older states are no longer visible.

Segments store complete states so that retiring an older base cannot discard
unmentioned fields. WAL mutations instead store patches to avoid rewriting
unmodified vector/payload contents on every partial update.

## Typed field bodies

| Kind | Body |
| --- | --- |
| Dense | Exactly `dimension` scalars of the catalog authority dtype |
| Sparse | `count:u32`, then `count` pairs of `term_id:i64, weight:f32` |
| Multivector | `rows:u32`, then `rows * dimension` scalars in row-major order |
| Binary | Exactly `ceil(bit_dimension / 8)` packed bytes |

Numeric scalars are F32 (4 bytes), BF16/F16 (2 bytes), I8/U8 (1 byte).
Signed integers use two's complement. Floating values must be finite; signed
zero and finite subnormals retain their exact bits. Native integer authority
has no implicit quantization scale. Old low-level readers retain their existing
contracts; these restrictions apply to new records and public accepted writes.

Sparse terms are nonnegative signed-i64 values in strictly increasing order,
with finite, nonzero weights. Count zero is a present empty field. This does
not change the existing `upsert_sparse` API's rejection of empty input.

Multivectors have fixed positive dimension per field and variable row count
per point, including zero. A point's rows are contiguous; ragged offsets for
collections/Arrow belong to their column representation. The codec does not
choose empty-document MaxSim scores; that search contract remains a separate
required implementation and oracle gate.

Binary bit index i is `(bytes[i // 8] >> (i % 8)) & 1`. Unused high bits in
the final byte must be zero. Bit dimension is not byte count. Hamming and
Jaccard share this authority representation but use distinct catalog metrics.

## Mutation state transition

The point model supports merge/create, delete-point and patch-existing.
Merge/create preserves unmentioned fields/payload of a live point. For a missing
or deleted point it starts with no vector fields and an empty payload.
Patch-existing requires a live point. Delete-point always creates a tombstone,
including for an unknown ID; it must not contain field or payload changes.

Field actions set a typed value or remove that field; repeated/descending or
unknown field IDs are invalid. Removing an absent field is permitted. Payload
is either unchanged or completely replaced, including replacement by empty.
An empty patch is an accepted point mutation and advances only point sequence.
Deleting then reinserting a point never inherits pre-delete owners.

Preparation validates all actions and payload before constructing a replacement.
Previous states remain unchanged; unmodified fields retain their immutable
owners. This pure preparation is not a WAL commit. The runtime integration
must stage every mutation in order (including repeated point IDs), append one
checksummed envelope, and publish only after append succeeds. Failure or a torn
envelope must expose none of the batch. The WAL envelope and migration crash
protocol still require their own readers, fixtures and integration tests.
