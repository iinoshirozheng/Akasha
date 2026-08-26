# Sparse WAL and Snapshot Formats v1

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
