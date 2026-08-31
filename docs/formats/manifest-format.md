# Manifest Binary Formats

`manifest.bin` is the commit point for a checkpoint generation. All integer
fields are little-endian. Writers emit v1 for the legacy single-segment API, v2
for ordinary multi-segment checkpoints, and v3 only when publishing an HNSW
sidecar reference. Readers retain byte-for-byte compatibility with v1 and v2.

## Version 1: single segment

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

A v1 manifest becomes one in-memory level-1 descriptor covering sequences zero
through its last sequence. It has no HNSW reference.

## Version 2: multiple segments

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

Each segment descriptor is encoded as:

| Relative offset | Size | Field |
| ---: | ---: | --- |
| 0 | 2 | Level (`0..7`) |
| 2 | 2 | Flags (`0` dense only, `1` paired sparse segment) |
| 4 | 8 | Minimum contained sequence |
| 12 | 8 | Maximum contained sequence |
| 20 | 4 | Referenced dense segment CRC32 |
| 24 | 2 | UTF-8 dense filename byte length |
| 26 | 2 | Reserved (must be `0`) |
| 28 | variable | UTF-8 dense filename |

When descriptor flag `1` is set, the dense filename is immediately followed
by:

| Size | Field |
| ---: | --- |
| 4 | Referenced sparse segment CRC32 |
| 2 | UTF-8 sparse filename byte length |
| 2 | Reserved (must be `0`) |
| variable | UTF-8 sparse segment filename |

V2 has no HNSW reference.

## Version 3: optional HNSW sidecar

V3 retains the v2 header and segment-descriptor encoding exactly, with these
header changes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKMF` |
| 4 | 2 | Version (`3`) |
| 6 | 2 | Flags (`0` no HNSW, `1` HNSW reference present) |
| 8 | 4 | Collection dimension |
| 12 | 8 | Manifest generation, greater than zero |
| 20 | 8 | Checkpoint last sequence |
| 28 | 4 | Segment descriptor count (`1..1024`) |
| 32 | 4 | Reserved (must be `0`) |
| 36 | variable | Ordered v2-compatible segment descriptors |
| after segments | variable | Optional HNSW descriptor when flag `1` is set |
| final 4 | 4 | Manifest CRC32 of bytes `[4, final 4)` |

The optional HNSW descriptor is:

| Relative offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Referenced HNSW sidecar CRC32 |
| 4 | 2 | UTF-8 HNSW filename byte length |
| 6 | 2 | Reserved (must be `0`) |
| 8 | 8 | Collection configuration fingerprint |
| 16 | 8 | Live point count represented by the sidecar |
| 24 | variable | UTF-8 HNSW filename |

The four HNSW fields are present or absent as one unit. A v3 manifest with flag
`0` is readable, but a new multi-segment publish without an HNSW reference is
encoded as v2. The sidecar filename is exactly
`hnsw-<checkpoint last sequence>.bin`; generation-based names, control-file
names, and names for any other sequence are invalid.

## Validation and authority

Dense, sparse, and HNSW names pass the same filename validator. Strict mode
requires each name to be non-empty, neither `.` nor `..`, and free of `/` and
NUL. Dense and sparse descriptor names are unique, a paired dense and sparse
name must differ, and an HNSW name cannot alias either kind of segment
reference. Sequence intervals increase without overlap in manifest order;
every maximum is at or below the checkpoint sequence and the final maximum
equals it. Level 0 is an incremental delta and higher levels are compacted
outputs.

Historical v1/v2 low-level codec calls accepted `.` and `..`. Decode and
byte-for-byte re-encode retain that compatibility, using the same validator in
explicit legacy mode. This is a decode-only compatibility boundary:
`publish_manifest` rejects those aliases, and `load_manifest` rejects them
before joining or checking any filesystem path. V3 always uses strict mode.

Every dense or sparse segment named by the manifest is authoritative and must
exist when the manifest is loaded. The HNSW sidecar is derived, optional, and
rebuildable, so generic manifest loading returns its metadata without requiring
that file to exist. Collection recovery is responsible for deciding whether a
missing or stale HNSW sidecar should be rebuilt.

Publication writes and fsyncs `manifest.bin.tmp`, atomically renames it to
`manifest.bin`, and fsyncs the collection directory. Loading dispatches on the
version before applying version-specific size and flag rules, validates the
whole-manifest checksum and descriptor bounds, and checks every authoritative
segment before applying it. Unreferenced files are harmless orphans and are
never selected by directory scanning.

`load_manifest` bounds reads at 134,318,143 bytes. This is derived from the
largest representable v3 file: the 36-byte header, 1,024 descriptors each with
a 28-byte dense prefix, a 65,535-byte dense name, an 8-byte sparse prefix, and
a 65,535-byte sparse name, followed by the 24-byte HNSW prefix, a 65,535-byte
HNSW name, and the 4-byte manifest checksum.
