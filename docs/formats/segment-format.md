# Snapshot Segment Binary Format v1

A Phase 3 segment is a complete immutable snapshot of the collection's live
vectors. Records are ordered by strictly increasing point ID.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKSG` |
| 4 | 2 | Version (`1`) |
| 6 | 2 | Flags (must be `0`) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Live record count |
| 20 | 8 | Last committed sequence |
| 28 | variable | Live records |
| final 4 | 4 | CRC32 of bytes `[4, final 4)` |

Each live record contains a signed 64-bit point ID, its unsigned 64-bit latest
sequence, and exactly `dimension` little-endian IEEE-754 `Float32` values. Each
record therefore occupies `16 + dimension * 4` bytes. Tombstones are not stored
because absence from the complete snapshot represents deleted state.

Decoding requires an exact file length, checksum, dimension, increasing ID
order, positive entry sequences, and entry sequences no newer than the segment
sequence. Unlike the WAL, any segment truncation is corruption.

