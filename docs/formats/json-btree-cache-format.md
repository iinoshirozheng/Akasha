# Native JSON B-tree derived cache v1

This is an Akasha format, not a Lance file-format implementation. It uses the
existing AKIC envelope version 1 with kind 6, dimension, generation 0, collection
sequence and source checksum. Unknown kinds remain invalid. Older readers treat
kind 6 as a cache miss; authoritative catalog migration is a separate contract.

All integers are little-endian. The payload begins with u16 version (1), u8
scalar target (1 Boolean, 2 Int64, 3 Float64, 4 Utf8, 5 Binary), u8 string-getter
provenance (0 or 1), column and JSONPath (each u32 byte length plus UTF-8 bytes),
u32 row count, and u32 page count.

Each directory entry contains u32 row count, u32 null count, u32 offset relative
to the start of the leaf area, u32 encoded length, and tagged minimum/maximum
keys. A tagged key is u8 null flag (0 or 1), followed for non-null values by an
8-byte Boolean/Int64/Float64 representation or u32 byte length plus bytes for
Utf8/Binary. Boolean accepts only 0 or 1; Float64 preserves all bits. Utf8 must
be valid. Leaf rows are tagged keys followed by u64 row IDs.

Leaves are contiguous, have 1..4096 rows and globally nondecreasing keys under
Lance total ordering. Row IDs are unique across the artifact. Duplicate values
may span pages. Null sorts first; directory endpoints and null counts must
exactly match leaf contents. Empty indexes have zero rows/pages and no leaves.

The builder targets at most 8 MiB encoded bytes per leaf, allowing one larger
row up to the 64 MiB hard leaf limit. The artifact is limited to 1,000,000 rows
and 128 MiB payload. The logical resident directory and the temporary row-ID uniqueness set each
have a 64 MiB limit. These
are component bounds, not a process RSS guarantee. Sorting has its own existing
8 MiB run target and 512 MiB spill bound. Staging uses two anonymous files (leaf
body and final envelope), each bounded by the payload limit.

On open the envelope CRC, directory, all leaf rows, row-ID uniqueness, global
ordering, endpoints, counts and exact lengths are verified. Only the directory
and mapped owner remain resident; queries decode one candidate leaf at a time.
This is lazy leaf materialization, not lazy initial integrity I/O. There is no
shared mutable leaf cache. Copies retain the mapped inode independently of its
path and file descriptor, so atomic replacement/unlink cannot invalidate an
existing index.

Collection create/rebuild publishes this optional artifact under
`json-btree-<definition CRC32>.cache`, using the shared fsync/atomic-replace/fsync
directory publisher. Reuse requires exact kind, dimension, generation, sequence,
definition, learned type, row count and source fingerprint. The fingerprint uses
the same canonical ID-ordered document bytes as bitmap caching. JSON collection
row IDs must be the dense ordinal domain 0..row_count-1; arbitrary u64 row IDs
remain supported by the standalone target only.

Missing, stale, torn or corrupt caches rebuild from the captured authoritative
root. Snapshot demand never writes files. Optional publication failure leaves
correct in-memory queries and a stale/missing cache that is rejected on reopen.
Dropping the last same-kind/column/path/type definition removes its cache and
temporary file; bitmap and B-tree namespaces are independent. Old snapshots
retain their mappings and masks after drop, replacement or collection close.
