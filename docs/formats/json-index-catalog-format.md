# JSON index catalog sections v1 and v2

This bounded section is embedded in manifest v6. It is not an
independent file or publication authority. All integers are little-endian. The
enclosing manifest CRC covers the section; no second checksum is embedded.

Header: u16 section version (1 or 2), u16 definition count (0..256), u64 catalog
revision. Each definition: u32 UTF-8 name length, u32 column length, u32 path
length, u8 kind (1 bitmap; v2 also accepts 2 B-tree), u8 learned target (1 Boolean, 2 Int64, 3 Float64,
4 Utf8, 5 LargeBinary), u16 reserved (=0), then name, column and path bytes.
The manifest stores the section byte length. Maximum section size is 16 MiB.
Names/columns obey existing payload field-name constraints; JSONPath uses the
existing parser and its 65,536-byte limit. Definition names are unique. Empty
catalog revision zero denotes legacy/no catalog; nonempty catalog requires a
positive revision. Unknown versions, kinds, types, reserved bits, duplicate names,
trailing bytes and malformed UTF-8/paths reject recovery before publication.

Legacy manifest bytes are unchanged. Readers of v1-v5 synthesize an empty
catalog. Catalog changes publish a new manifest generation; subsequent flush,
compaction and HNSW publication retain the catalog, including an empty catalog
with a nonzero revision after drop.

## Manifest v6 envelope

v6 retains the v5 header, segment descriptors and optional HNSW descriptor.
After those descriptors and before the final manifest CRC, append u32 section
length followed by exactly that many catalog bytes. Even an empty catalog has
a 12-byte section. The existing manifest CRC covers this extension. v6 HNSW
references retain v5's base-sequence/overlay rules. Encoding a catalog with a
nonzero revision or definitions through v2-v5 is rejected rather than discarded.
Catalog publication checkpoints accepted point writes before replacing the
manifest. An uncertain publication I/O failure requires reopening the writer.
Only `manifest.bin` is authoritative; incomplete or complete `manifest.bin.tmp`
never supersedes it, including when the committed manifest is corrupt.

## Kind migration and canonical encoding

The entry layout is unchanged. A catalog containing any B-tree definition is
written as section v2, atomically through the existing manifest v6 publication.
Bitmap-only and empty catalogs retain section v1 encoding, including their
revision. This preserves the frozen v6/v1 bitmap fixture byte-for-byte and does
not rewrite legacy files merely by opening them. Dropping the last B-tree
returns the catalog to the v1-representable subset on the next publication.

Readers accept v1 kind 1 and v2 kinds 1/2; all other combinations reject recovery.
Older readers reject a v2 catalog rather than silently opening a B-tree database
without its definitions. The outer manifest format, point WAL and segment
formats are unchanged. Backup/restore carries the catalog section verbatim.
`tests/fixtures/json-catalog-v2.bin` independently encodes revision 7 with a
bitmap and B-tree definition, using the little-endian layout above.
