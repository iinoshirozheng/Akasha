# Manifest Binary Formats

`manifest.bin` is the commit point for a checkpoint generation. Writers emit v2
for incremental storage; readers retain v1 compatibility.

## Version 1

Version 1 names exactly one complete immutable snapshot segment.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKMF` |
| 4 | 2 | Version (`1`) |
| 6 | 2 | Flags (must be `0`) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Segment last sequence |
| 20 | 4 | Referenced segment CRC32 |
| 24 | 2 | UTF-8 segment filename byte length |
| 26 | 2 | Reserved (must be `0`) |
| 28 | variable | UTF-8 segment filename |
| final 4 | 4 | Manifest CRC32 of bytes `[4, final 4)` |

The filename must be non-empty and may not contain `/` or a NUL byte. A v1
manifest becomes one in-memory level-1 descriptor covering sequences zero
through its last sequence.

## Version 2

Version 2 names an ordered list of base and delta segments. Integer fields are
little-endian.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKMF` |
| 4 | 2 | Version (`2`) |
| 6 | 2 | Flags (must be `0`) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Manifest generation, greater than zero |
| 20 | 8 | Checkpoint last sequence |
| 28 | 4 | Segment descriptor count (`1..1024`) |
| 32 | 4 | Reserved (must be `0`) |
| 36 | variable | Ordered segment descriptors |
| final 4 | 4 | Manifest CRC32 of bytes `[4, final 4)` |

Each descriptor is encoded as:

| Relative offset | Size | Field |
| ---: | ---: | --- |
| 0 | 2 | Level (`0..7`) |
| 2 | 2 | Flags (must be `0`) |
| 4 | 8 | Minimum contained sequence |
| 12 | 8 | Maximum contained sequence |
| 20 | 4 | Referenced segment CRC32 |
| 24 | 2 | UTF-8 filename byte length |
| 26 | 2 | Reserved (must be `0`) |
| 28 | variable | UTF-8 segment filename |

Descriptor filenames are unique, non-empty, and contain neither `/` nor NUL.
Sequence intervals must increase without overlap in manifest order; every
maximum is at or below the checkpoint sequence and the final maximum equals the
checkpoint sequence. Level 0 is an incremental delta and higher levels are
compacted outputs.

Publication writes and fsyncs `manifest.bin.tmp`, atomically renames it to
`manifest.bin`, and fsyncs the collection directory. Loading validates the
manifest checksum, all descriptor bounds, and the existence of every referenced
segment before any segment is applied. Unreferenced segment files are harmless
orphans and are never selected by directory scanning.
