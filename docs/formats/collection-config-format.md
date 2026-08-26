# Collection Configuration Binary Format v1

`collection.bin` is the immutable identity and ANN tuning record for one
collection. The v1 record is exactly 60 bytes. Every integer is unsigned and
little-endian unless its size is one byte.

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 4 | bytes | Magic ASCII `AKCF` |
| 4 | 2 | `u16` | Version (`1`) |
| 6 | 2 | `u16` | Flags (must be `0`) |
| 8 | 4 | `u32` | Vector dimension |
| 12 | 1 | `u8` | ANN metric tag |
| 13 | 1 | `u8` | Graph scalar tag |
| 14 | 2 | `u16` | Upper-layer neighbor limit `m` |
| 16 | 2 | `u16` | Base-layer neighbor limit `m0` |
| 18 | 2 | bytes | Alignment reserve (must be zero) |
| 20 | 4 | `u32` | Construction breadth `ef_construction` |
| 24 | 4 | `u32` | Default query breadth `default_ef_search` |
| 28 | 4 | `u32` | Maximum query breadth `max_ef_search` |
| 32 | 2 | `u16` | Maximum generated graph level |
| 34 | 1 | `u8` | Inactive-node rebuild threshold, percent |
| 35 | 1 | byte | Alignment reserve (must be zero) |
| 36 | 4 | `u32` | Maximum mutable-delta point count |
| 40 | 8 | `u64` | Deterministic graph-level seed |
| 48 | 8 | bytes | Future extension reserve (must be zero) |
| 56 | 4 | `u32` | CRC-32/ISO-HDLC of bytes `[4, 56)` |

Metric tags are `0 = dot`, `1 = squared L2`, and `2 = cosine`. Scalar tags are
`0 = F32`, `1 = BF16`, `2 = F16`, and `3 = I8`. Unknown tags are invalid.
Magic is intentionally outside the checksum range and is validated separately.
The decoder rejects every length other than 60 bytes, including trailing data,
and rejects nonzero flags or reserved bytes.

## Validation limits

Decoded values are converted through `MetricKind.from_tag` and
`ScalarKind.from_tag`, assembled into `CollectionConfig`, and then passed to
`CollectionConfig.validate()`. Encoding also validates before narrowing any
integer to its wire width. The v1 constraints are:

- dimension: `1..4,294,967,295`;
- `m`: `2..65,535`;
- `m0`: `m..65,535`;
- `ef_construction`: `m0..4,294,967,295`;
- `default_ef_search`: `1..4,294,967,295`;
- `max_ef_search`: `default_ef_search..4,294,967,295`;
- maximum graph level: `1..63`;
- inactive rebuild percentage: `1..90`;
- mutable-delta point limit: `1..4,294,967,295`;
- I8 is valid for dot and cosine graphs, but not squared-L2 graphs.

`level_seed` accepts the complete `u64` range.

## Publication and compatibility

For a first publication Akasha validates and encodes the record, writes and
fsyncs `collection.bin.tmp`, atomically renames it to `collection.bin`, and
fsyncs the collection directory. A stale temporary file is not authoritative
and is removed before publication. If `collection.bin` already exists, Akasha
loads and fully validates it. Publishing an identical configuration is an
idempotent no-op; publishing any different field fails without replacing the
existing bytes.

Version 1 is a closed fixed-width format. Readers reject unknown versions,
flags, tags, and nonzero reserve bytes rather than guessing compatibility. A
future format change that needs new semantics must use a new version.

Task 4 owns legacy migration: when a directory has an existing Akasha WAL
and/or manifest but no `collection.bin`, opening it migrates to the default
L2/F32 configuration and publishes this file without rewriting the legacy WAL,
manifest, or segment data.
