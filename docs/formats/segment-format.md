# Segment Binary Formats v1, v2, and v3

A Phase 3 segment is a complete immutable snapshot of the collection's live
vectors. Records are ordered by strictly increasing point ID.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKSG` |
| 4 | 2 | Version (`1` or `2`) |
| 6 | 2 | Flags (must be `0`) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Live record count |
| 20 | 8 | Last committed sequence |
| 28 | variable | Live records |
| final 4 | 4 | CRC32 of bytes `[4, final 4)` |

Each live record begins with a signed 64-bit point ID, its unsigned 64-bit
latest sequence, and exactly `dimension` little-endian IEEE-754 `Float32`
values. A version 1 record ends there and occupies `16 + dimension * 4` bytes;
it recovers with an empty field list.

A version 2 record appends:

| Size | Field |
| ---: | --- |
| 4 | Encoded payload byte length |
| variable | Typed payload bytes |

New snapshots always use version 2. Reading a version 1 snapshot and flushing
it therefore performs an automatic online format upgrade. Tombstones are not
stored because absence from the complete snapshot represents deleted state.

## Version 3 base and delta segments

Version 3 keeps the `AKSG` magic but uses the header flag field as an explicit
kind: `1` is a complete base and `2` is an incremental delta.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKSG` |
| 4 | 2 | Version (`3`) |
| 6 | 2 | Kind (`1` base, `2` delta) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Record count |
| 20 | 8 | Minimum contained sequence |
| 28 | 8 | Maximum contained sequence |
| 36 | variable | Ordered records |
| final 4 | 4 | CRC32 of bytes `[4, final 4)` |

Every v3 record begins with:

| Size | Field |
| ---: | --- |
| 8 | Signed point ID |
| 8 | Entry sequence |
| 1 | State (`0` live, `1` tombstone) |
| 1 | Flags (must be `0`) |
| 2 | Reserved (must be `0`) |

A live record continues with `dimension` Float32 values, a UInt32 payload byte
length, and the encoded typed payload. A tombstone ends after the state header
and may only appear in a delta. All entry sequences lie inside the segment's
inclusive sequence interval. Point IDs strictly increase.

Legacy `encode_segment` continues to produce v2 until incremental checkpoint
publication switches collection flushes to v3. The shared decoder reports v1
and v2 as base segments with minimum sequence zero.

Decoding requires an exact file length, checksum, dimension, valid kind and
state flags, increasing ID order, positive entry sequences, and entry sequences
inside the declared interval. Unlike the WAL, any segment truncation is
corruption.
