# WAL Binary Formats v1, v2, and v3

Akasha stores `wal.bin` as concatenated, little-endian records. The format is
append-only, and each record carries its own version so a WAL may contain v1 and
v2/v3 records during an online upgrade.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKWL` |
| 4 | 2 | Version (`1` or `2`) |
| 6 | 1 | Operation (`1` upsert, `2` delete) |
| 7 | 1 | Flags (must be `0`) |
| 8 | 4 | Total record length, including checksum |
| 12 | 8 | Monotonic sequence number |
| 20 | 8 | Signed point ID |
| 28 | 4 | Collection dimension |
| 32 | `dimension * 4` or `0` | Upsert `Float32` values; empty for delete |

Version 1 ends with the four-byte CRC32 immediately after the vector. Its
minimum delete record is 36 bytes and an upsert is
`36 + dimension * 4` bytes.

Version 2 appends these fields before the final CRC32:

| Size | Field |
| ---: | --- |
| 4 | Encoded payload byte length |
| variable | Typed payload bytes; empty for delete |
| 4 | CRC32 of bytes `[4, final 4)` |

New vector-only upserts contain the four-byte empty payload encoding. New
document upserts contain the payload format documented by the document codec.
A v2 delete has a zero payload length and is 40 bytes. Single-mutation writes
use version 2; recovered version 1 upserts have an empty field list.

## Version 3 atomic batch envelope

Version 3 uses operation `3` and stores a complete mutation batch under one
outer CRC32. Its 32-byte header reuses the magic, version, flags, and total
record-length fields, then stores:

| Offset | Size | Field |
| ---: | ---: | --- |
| 12 | 8 | First sequence in the contiguous batch range |
| 20 | 4 | Mutation count (`1..65,536`) |
| 24 | 4 | Collection dimension |
| 28 | 4 | Reserved (`0`) |

Each mutation starts with operation (`1` upsert or `2` delete), one zero flags
byte, two reserved zero bytes, signed point ID, and a four-byte body length.
Delete bodies are empty. Upsert bodies contain exactly `dimension * 4` vector
bytes followed by payload length and typed payload bytes. The final four bytes
are CRC32 over bytes `[4, final 4)`. An envelope is limited to 256 MiB.

Batch sequences are derived as `first_sequence + mutation_ordinal`, so gaps or
duplicates are unrepresentable. Validation and encoding finish before one
append+fsync. Recovery emits mutations only after the complete envelope and
outer checksum validate. An incomplete final envelope is truncated in full;
therefore no durable prefix of a torn batch is exposed.

Integers and IEEE-754 values are little-endian.

Recovery requires strictly increasing, non-zero sequence numbers and an exact
dimension match. If EOF occurs before a complete final header or record, that
tail is ignored and the WAL is fsynced back to its last valid record boundary
before new writes are accepted. Once a complete record is present, invalid magic, version,
flags, operation, length, sequence, dimension, or CRC is corruption.
