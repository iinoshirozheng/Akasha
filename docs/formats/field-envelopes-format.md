# Field-aware WAL and segment envelopes

Status: all collection writers emit WAL v5 and Segment v5. Readers accept WAL
v4/v5; legacy v1/v2/v3 envelopes remain supported at the catalog cutover. Both envelopes bind the immutable v2 `collection.bin` using its
schema revision and stored CRC32. The CRC is an accidental-corruption/identity
check, not cryptographic authentication. Changing a published field catalog is
not part of this format. New catalogs require a separately specified migration.

All fields are little-endian. The final u32 is CRC-32/ISO-HDLC over bytes
`[4, end-4)`, excluding magic and the checksum itself. Magic is checked separately.
Validate the entire envelope, catalog binding and all contained records before
returning anything for publication. Payload uses payload-v1; vector bodies and
complete point records use [the point contract](point-record-format.md).

## WAL v5 (with frozen v4 reader)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `AKWL` |
| 4 | u16 | Version 5 (4 accepted for legacy merge semantics) |
| 6 | u8 | Operation 4, field-aware atomic batch |
| 7 | u8 | Flags zero |
| 8 | u32 | Total envelope length, including final CRC |
| 12 | u64 | First mutation sequence |
| 20 | u32 | Mutation count, 1..65,536 |
| 24 | u64 | Catalog schema revision |
| 32 | u32 | Catalog CRC32 |
| 36 | u32 | Reserved zero |
| 40 | bytes | Ordered mutations |

The envelope is at most 256 MiB. Its sequence range is contiguous and may not
overflow u64. First sequence must exceed both the previous accepted WAL sequence
and catalog legacy cutover C. Repeated point IDs are allowed and applied in order.

Each mutation has a 20-byte header: `id:i64, kind:u8, payload_action:u8,
flags:u16, field_count:u32, body_length:u32`. Flags are zero; body_length excludes
the mutation header. Kinds are replace/create=1, delete=2, patch-existing=3.
For v5 kind 1, all omitted vectors are absent in the resulting point, and an
omitted payload becomes empty. Kind 3 preserves omitted vectors/payload and
requires an existing live point. Readers apply **v4 kind 1 as merge/create**,
retaining unmentioned fields and payload; never reinterpret a v4 mutation using
v5 replacement semantics. New writes always use v5. The wire layouts otherwise
match, and the version participates in the checksum.

Payload action is absent=0 or replace=1. Replace starts the body with
`payload_length:u32, payload:bytes`; replacement by empty is a four-byte zero
payload field count, not a zero-length payload. Absent contains no payload bytes.

Next are exactly field_count actions, in strictly increasing known field-ID order:
`field_id:u32, action:u8, flags:u8, reserved:u16, body_length:u32, body:bytes`.
Action set=1 stores a typed body; remove=2 has length zero. Flags/reserved are zero.
Delete-point has no field actions or payload, and its body length is zero.
Every mutation body must be consumed exactly. Existing-point preconditions are
checked while staging replay against authority, not by this stateless decoder.

### Mixed replay and torn tails

Existing v1/v2/v3 envelopes remain readable only at sequences at or below C.
WAL v4/v5 envelopes follow C. All envelopes share one strictly increasing sequence
order; legacy sparse recovery still has to complete at C before new field patches
are applied. No new sparse mutation may be appended to the old sparse WAL after
switching authority. Legacy low-level numeric compatibility is preserved by using
the old decoder rather than coercing legacy records through new typed validators.

Framing retains the existing 32-byte common-prefix boundary: shorter final tails
are ignored. At least 32 bytes permits checking magic and bounded total length;
v4/v5 length must be at least 64. Other metadata waits for a complete envelope.
A body cut short at EOF emits none of that envelope. A complete bad envelope is
corruption, including an unknown version, catalog mismatch or a late invalid field.
Readers record accepted/source lengths but never repair during preflight. After
all collection sources pass, the existing truncate-and-fsync repair applies at the
last complete boundary. Reader failure is terminal for that reader instance.

## Segment v5 (v4 read compatibility)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `AKSG` |
| 4 | u16 | Version 5 (4 accepted) |
| 6 | u16 | Kind base=1 or delta=2 |
| 8 | u64 | Catalog schema revision |
| 16 | u32 | Catalog CRC32 |
| 20 | u32 | Reserved zero |
| 24 | u64 | Record count |
| 32 | u64 | Minimum covered sequence |
| 40 | u64 | Maximum covered sequence |
| 48 | bytes | Complete point records, then final CRC |

Point IDs strictly increase, including across negative and positive extremes.
All point sequences lie in the declared inclusive interval and satisfy the point
contract. Base minimum is zero and bases contain no tombstones; delta minimum is
positive. Maximum is at least C. A base can be empty at sequence zero for a new
collection, or at a later checkpoint after all points were deleted. Declared
maximum is a checkpoint watermark and need not equal the newest surviving point.
Empty deltas with a valid positive interval are permitted.

Each record is complete state, not a patch depending on a retired base. Record
length is bounded to 256 MiB; total segment size is bounded by addressable file
size, not by a single WAL-envelope limit. Record count is checked against actual
available bytes before allocating descriptors. Any truncation or trailing data
is corruption. Legacy segment readers remain unchanged and reject v4/v5; a catalog
v2 identity must be durable before a collection selects the point writer.

The upsert migration does not change point-record layout: complete states have no
ambiguous merge semantics. A mixed v4/v5 WAL is replayed in sequence with each
envelope's version, then checkpointed as complete Segment v5 states. Older
binaries that only accept v4 WAL must reject v5; downgrade is not supported.

Frozen `merge-upsert-v4.bin` was generated with the pre-migration writer at
`f6a938a`: sequence 8 creates default/named vectors and payload; sequence 9
merges only the named vector. It verifies preservation before a new v5 replace.

## Sparse zero-weight and default-writer migration

All public collection opens now migrate legacy authority through the existing
catalog-v2 cutover. New default and named writes share WAL v5; the legacy dense
and sparse writers are retained only as low-level format codecs and fixtures.
Dense `upsert`/batch upsert removes omitted sparse/named vectors. `upsert_sparse`
is a patch of the existing point and permits an empty value or zero weights.

Segment v5 has the same layout as v4, with version 5 at header offset 4. V5 permits
finite zero sparse weights. V4 readers retain their nonzero-weight restriction;
new checkpoints and compactions write v5, and mixed v4/v5 checkpoint recovery is
supported. WAL v4 retains the same restriction; WAL v5 accepts the new values.
Existing v4 fixture bytes remain unchanged. `test_field_envelopes.mojo` checks
migration without body changes, CRC-valid version changes, and rejection of zero
weights under v4. `test_default_point_alignment.mojo` covers default open,
legacy merge cutover, replacement writes, sparse presence and restart.
