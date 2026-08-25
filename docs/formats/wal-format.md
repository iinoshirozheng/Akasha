# WAL Binary Format v1

Akasha stores `wal.bin` as concatenated, little-endian records. The format is
append-only in Phase 3.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKWL` |
| 4 | 2 | Version (`1`) |
| 6 | 1 | Operation (`1` upsert, `2` delete) |
| 7 | 1 | Flags (must be `0`) |
| 8 | 4 | Total record length, including checksum |
| 12 | 8 | Monotonic sequence number |
| 20 | 8 | Signed point ID |
| 28 | 4 | Collection dimension |
| 32 | `dimension * 4` or `0` | Upsert `Float32` values; empty for delete |
| final 4 | 4 | CRC32 of bytes `[4, final 4)` |

The minimum delete record is 36 bytes. An upsert record is
`36 + dimension * 4` bytes. Integers and IEEE-754 values are little-endian.

Recovery requires strictly increasing, non-zero sequence numbers and an exact
dimension match. If EOF occurs before a complete final header or record, that
tail is ignored and the WAL is fsynced back to its last valid record boundary
before new writes are accepted. Once a complete record is present, invalid magic, version,
flags, operation, length, sequence, dimension, or CRC is corruption.
