# JSON bitmap cache payload v1

This is an optional, rebuildable Akasha cache, not a Lance file or portable
Roaring format. Manifest v6 remains the only catalog authority. Publication
uses the existing AKIC v1 envelope with kind 5, collection dimension, generation
0, accepted point sequence and source CRC32. Outer CRC/length checks protect the
entire payload. Older readers reject the unknown kind as a cache miss.

The filename is `json-bitmap-{definition_crc32_decimal}.cache`. Its CRC covers
length-prefixed column/path and target. The full definition is checked inside;
filename collisions can cause misses, never justify using another definition.

All payload integers are little-endian:

| Field | Encoding |
| --- | --- |
| Payload version | u16 = 1 |
| Learned type | u8: Boolean=1, Int64=2, Float64=3, Utf8=4, binary=5 |
| String-getter-safe provenance | u8, exactly 0 or 1 |
| Column, then JSONPath | each u32 UTF-8 length followed by exact bytes |
| Nonnull key count, total row count | u32 each |
| Null posting | u32 count then sorted distinct u64 row ordinals |
| Each ordered nonnull key | Boolean/Int64: i64; Float64: raw u64 bits; Utf8/binary: u32 length and bytes |
| Each key's posting | u32 positive count then sorted distinct u64 row ordinals |

Keys follow the existing LanceScalarKey total order, preserving Float64 signed
zero and NaN bits. Boolean integers are exactly 0 or 1. Utf8 bytes must validate.
Postings must partition every ID-ordered visible-row ordinal in `[0,row_count)`
exactly once, including nulls. Duplicate keys, empty nonnull postings, duplicate
or unordered ordinals, missing coverage and trailing/truncated bytes reject the
payload. Limits are 1,000,000 rows, existing 64 MiB logical bitmap state, and
128 MiB encoded payload. This bounds state, not peak RSS.

The source fingerprint covers length-prefixed definition, type, row count and
each signed point ID plus current v3 encoded document payload in ID order.
Envelope sequence/dimension and exact definition must also match. This follows
the existing derived-cache integrity model, not cryptographic authentication.

Create and collection rebuild publish under writer/file exclusion through
temporary write, file fsync, atomic replace and directory fsync. Publication is
best-effort; cache failure cannot undo or corrupt authoritative catalog/data.
Drop removes the cache when no remaining definition shares column/path/type.
Snapshots never publish. The first root-local query demand loads and decodes
the whole validated payload; later queries share it in memory. Data changes,
corruption, missing files and mismatched versions cause rebuild from authority.
Query cancellation/deadline errors are propagated rather than converted to hits.

This layer does not provide per-posting lazy reads, persistent bitmap pages,
bounded paging cache, external sorting/spill or on-disk shard merging.
