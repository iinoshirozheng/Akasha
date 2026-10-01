# Field-aware WAL and segment envelopes

Status: reader-first v4 formats; collection writers still use the existing
legacy paths. Both envelopes bind the immutable v2 `collection.bin` using its
schema revision and stored CRC32. The CRC is an accidental-corruption/identity
check, not cryptographic authentication. Changing a published field catalog is
not part of this format. New catalogs require a separately specified migration.

All fields are little-endian. The final u32 is CRC-32/ISO-HDLC over bytes
`[4, end-4)`, excluding magic and the checksum itself. Magic is checked separately.
Validate the entire envelope, catalog binding and all contained records before
returning anything for publication. Payload uses payload-v1; vector bodies and
complete point records use [the point contract](point-record-format.md).

## WAL v4

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `AKWL` |
| 4 | u16 | Version 4 |
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
the mutation header. Kinds are merge/create=1, delete=2, patch-existing=3.
Payload action is unchanged=0 or replace=1. Replace starts the body with
`payload_length:u32, payload:bytes`; replacement by empty is a four-byte zero
payload field count, not a zero-length payload. Unchanged contains no payload bytes.

Next are exactly field_count actions, in strictly increasing known field-ID order:
`field_id:u32, action:u8, flags:u8, reserved:u16, body_length:u32, body:bytes`.
Action set=1 stores a typed body; remove=2 has length zero. Flags/reserved are zero.
Delete-point has no field actions or payload, and its body length is zero.
Every mutation body must be consumed exactly. Existing-point preconditions are
checked while staging replay against authority, not by this stateless decoder.

### Mixed replay and torn tails

Existing v1/v2/v3 envelopes remain readable only at sequences at or below C.
New v4 envelopes follow C. All envelopes share one strictly increasing sequence
order; legacy sparse recovery still has to complete at C before new field patches
are applied. No new sparse mutation may be appended to the old sparse WAL after
switching authority. Legacy low-level numeric compatibility is preserved by using
the old decoder rather than coercing legacy records through new typed validators.

Framing retains the existing 32-byte common-prefix boundary: shorter final tails
are ignored. At least 32 bytes permits checking magic and bounded total length;
v4 length must be at least 64. Other v4 metadata waits for a complete envelope.
A body cut short at EOF emits none of that envelope. A complete bad envelope is
corruption, including an unknown version, catalog mismatch or a late invalid field.
Readers record accepted/source lengths but never repair during preflight. After
all collection sources pass, the existing truncate-and-fsync repair applies at the
last complete boundary. Reader failure is terminal for that reader instance.

## Segment v4

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 bytes | `AKSG` |
| 4 | u16 | Version 4 |
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
is corruption. Legacy segment readers remain unchanged and reject v4; a catalog
v2 identity must be durable before a collection selects a v4 writer.
