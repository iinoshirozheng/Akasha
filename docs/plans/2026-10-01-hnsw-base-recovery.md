# Preserve the immutable HNSW base across checkpoints

The current graph is already an immutable base plus a bounded mutable delta.
Checkpointing after a small update drops its sidecar because `checkpoint_ready`
requires a complete owned base. Recovery then rebuilds every vector even though
only a few changed. Serializing a new full graph or forcing a full rebuild on
each flush would move that cost into the write path.

Keep the existing immutable base sidecar and reconstruct its overlay from the
already recovered authoritative point projection. Manifest v5 uses the existing
v4 descriptor layout but explicitly permits a canonical HNSW filename whose
sequence precedes the committed authority sequence. Its count and checksum still
describe that base file, not the current authoritative point count. Older v1–v4
contracts remain unchanged. The filename carries the exact base sequence and
creation generation and cannot name a future sequence or generation.

Recovery validates the base's config, checksum, structure and named sequence.
It removes base IDs absent from current default-dense authority, then applies
current default fields with document versions newer than the base in sequence
order. Named/sparse-only changes do not reinsert the default vector. A missing
unchanged base ID is a cache miss, not permission to accept incomplete coverage.
The final source map must exactly cover live default-dense authority. This uses
the existing segmented graph, source admission, metrics and reranking without
changing their search behavior or authoritative storage.

Newly built/promoted bases record their capture sequence. A rebuilt base remains
eligible for publication after catch-up writes add a delta: the immutable base
still represents its original capture, and v5 recovery reconstructs that delta.
The capture sequence must not be relabeled with the later checkpoint sequence.
Eight regressions cover legacy/point authority, with/without an old checkpoint,
and checkpoint publication during the detached rebuild. They passed after a
reproduced missing-sidecar failure. Existing threshold maintenance remains
responsible for merging a large delta. File leases,
backup, compaction and storage inspection retain/validate the base reference and
use its sequence. Atomic manifest publication remains the only durable commit
point. Point-format collections use the same default-field sidecar lifecycle.

For v3 sidecars, preserve the strict old filename contract while moving to v5:
stream the old graph bytes through the shared verified immutable-copy helper
into an exclusive canonical job name. CRC, header sequence/config and live count
must match before sync/publication. The old name remains pinned through active
snapshots; retries skip collisions. Both legacy and point-authority regressions
preserve byte identity and recover a mapped base plus one updated vector.

Acceptance: independent v5 fixture, old-version rejection and corrupt/torn tests;
owned and mapped base updates/deletes/reinsert/payload/named-only changes;
repeated checkpoints and compaction; backup/restore; matching corruption before
WAL repair; no-write reopen; actual 8192×1536 update/flush/reopen measurements
showing retained mapped base and bounded replay with no full graph build.
