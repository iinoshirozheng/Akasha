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
Snapshots never publish. The first root-local query demand maps and validates the payload, retaining
ordered keys and posting offsets/counts. Queries decode only requested postings
(including nulls when required) and share a bounded root-local LRU. Data changes,
corruption, missing files and mismatched versions cause rebuild from authority.
Query cancellation/deadline errors are propagated rather than converted to hits.

Mapped open still checks the full envelope CRC and scans every ordinal for
ordering, bounds and exact coverage, using a temporary bitset of at most 125,000
bytes. It constructs no posting sets and makes no whole-payload copy. The
original 64 MiB logical decoded-state limit is validated by counting Roaring
container sizes; the retained key/offset directory is separately bounded by
64 MiB. No format migration is needed.

Each mapped index retains at most 128 decoded postings and 8 MiB of logical
posting/cache-entry storage, excluding allocator capacity, directory, mapped
pages, query-owned copies and temporary unions. LRU misses are serialized;
oversized postings are returned without retention. Cancellation/deadlines are
checked on hits and during decoding. Atomic replacement/unlink does not invalidate
the mapped inode retained by an older reader. These are cache bounds, not a
process-wide memory or startup-I/O limit.

Build-time sorting uses separate anonymous staging files. Bitmap shard files
use this same payload, with the following envelope identity and lifecycle.

## Derived shards and streamed merge

The filename is `<full-cache-name>.shard-<zero-based-slot>`. Generation is
`slot + 1`, sequence is zero, and source CRC covers the same definition/ID/payload
encoding applied to that shard's current source rows. Shards contain at most
4,096 ID-ordered rows with **local** ordinals starting at zero. There are at most
245 shards, including one empty shard for an empty index. Exact definition, type,
dimension, slot, source checksum, row count and payload integrity must match
before reuse. There is no reliance on a whole-collection sequence for a shard.

A globally learned type is used for every shard. The merger validates each
input, keeps one key cursor/heap head per shard, unions equal-key postings and
adds cumulative source row counts to local ordinals. A preflight pass determines
key count and payload length; a second pass streams the same v1 merged payload.
The full-cache identity remains generation zero / current accepted sequence /
whole-source checksum, so prior full-cache readers remain compatible.

Build staging uses anonymous mapped files. The final bitmap is also mapped;
no complete owned bitmap or encoded payload is required for merge output.
The existing logical final-state and payload limits still apply. The sum of
input shard file lengths and staged merged length is limited to 512 MiB; heap
and cursor key storage is bounded by 64 MiB. Per-shard directory validation is
released before advancing to the next shard. These exclude allocator overhead,
mapped pages and current posting/encoding workspaces.

Create/rebuild publishes changed shards first, then the full cache. Each file
uses its own fsync/atomic-replace/directory-fsync sequence. Matching valid shard
files are left untouched. After successful full-cache publication, obsolete tail
shards are removed. Drop removes the full cache and all known shard slots only
when the definition is no longer shared. No directory-wide orphan scan is used.

There is deliberately no atomic multi-file manifest for these **optional**
derived files. A crash or failure between replacements may leave mixed shard
versions and an older full cache; mismatched source fingerprints or sequences
force rebuild, never a stale result. Snapshot demand may reuse files and stage
replacements anonymously, but never writes persistent cache files. Existing
snapshots retain their mapped inodes across replacement/deletion. Backup and
restore correctness continue to depend only on authoritative data/catalog.
