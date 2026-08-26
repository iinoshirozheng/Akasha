# Sparse WAL and Segment Formats

Sparse vectors are caller-provided ordered `(term_id: i64, weight: f32)` pairs.
Term IDs are non-negative and strictly increasing; weights are finite and
non-zero. All integers are little-endian and every record/file ends in CRC32.

`sparse.wal` contains independently checksummed upsert/delete records with the
shared collection sequence, point ID, element count, and optional elements. A
complete malformed record fails recovery; only an incomplete final record is
truncated. `sparse.wal.tmp` is fsynced and atomically renamed during checkpoint
rotation.

`sparse-<manifest_sequence>.bin` is a full snapshot sidecar. Its header stores
format version 1, record count, and the exact manifest checkpoint sequence.
Records are ordered by ascending point ID. The sidecar is written and fsynced
before the dense manifest commit. Recovery loads it only when present and
rejects a sequence mismatch, then replays newer sparse WAL mutations. Missing
sidecars remain valid for databases created before Phase 7.

## Incremental segment v2

Manifest v2 checkpoints pair every dense base/delta descriptor with a sparse
segment descriptor and checksum. Sparse v2 uses the existing `AKPR` magic:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic ASCII `AKPR` |
| 4 | 2 | Version (`2`) |
| 6 | 2 | Kind (`1` base, `2` delta) |
| 8 | 8 | Record count |
| 16 | 8 | Minimum contained collection sequence |
| 24 | 8 | Maximum contained collection sequence |
| 32 | variable | Point records |
| final 4 | 4 | CRC32 of bytes `[4, final 4)` |

Each point record contains signed point ID, UInt64 mutation sequence, UInt8
operation (`1` upsert, `2` delete), one zero flag byte, two reserved zero bytes,
UInt32 element count, and the ordered sparse elements. Base segments contain
only upserts. Delta segments may contain tombstones. IDs strictly increase and
record sequences lie inside the descriptor interval.

Multiple sparse mutations to one point between checkpoints collapse to the
latest mutation before a delta is written. Recovery applies paired sparse
segments in manifest order, then sparse WAL records newer than the checkpoint.
Legacy manifests without paired descriptors continue to load the v1
`sparse-<sequence>.bin` sidecar when present.
