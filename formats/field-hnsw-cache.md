# Optional named HNSW cache

`field-hnsw-<field-id>.cache` is a rebuildable artifact, never authoritative
collection data. It is not part of the manifest or required in backup. Removing
it only costs a graph rebuild. Existing authoritative formats do not change.

The existing AKIC v1 envelope gains kind **4**. For this kind, `dimension` is the
field dimension, the `generation` word contains the stable field ID and the
`sequence` word is zero. `source_checksum` is CRC32/ISO-HDLC of the following
canonical little-endian stream:

1. Field ID (u32), kind/scalar/metric/index (four u8), dimension (u32), UTF-8 name
   byte length (u32), name bytes, existing 60-byte encoded graph configuration.
2. Number of live rows containing the field (u64).
3. In ascending signed point-ID order: ID (i64), then dimension F32 coordinates.
   F32 authority uses its exact bits; F16/BF16/I8/U8 promote exactly to F32.

The payload is the existing HNSW v1/v2 snapshot at sequence zero, including its
own CRC. The AKIC envelope retains its whole-file CRC and 512 MiB payload bound.
Its field-specific interpretation cannot alias the other cache kinds. Unsupported
versions, corrupt/truncated/oversized bytes, mismatched identity/config/source,
and any snapshot validation failure are misses.

Loading additionally requires one current graph slot for every sorted live field
ID, with no extra slots. Each stored vector is checked against the current
authority after the graph metric's exact preparation/encoding, including I8 codes
and scale. Run-local ordinals and ID lookup are rebuilt from current authority.
Payload changes, accepted sequence changes, or ordinal reordering alone therefore
do not invalidate an otherwise identical graph. Native F64 reranking always uses
current authority. Root-specific filter/visibility admission remains in effect.

Only a complete current single immutable run's already-ready graphs are saved
on flush/close. Publication holds the collection writer/file lock and graph query
lock, writes `<name>.tmp`, fsyncs, replaces atomically, and fsyncs the directory.
Artifact and graph locks are attempted once; a busy builder/search is skipped
instead of blocking the collection writer. A subsequent flush/close may retry.
Failure neither rejects authority writes nor poisons the ready graph; a later
flush/close retries. A torn temporary file is ignored. One committed file and at
most one temporary file per named HNSW field bound retention. Queries and held
snapshots only read optional files.

Multi-run views are not flattened or serialized by this path. After their writes,
a stale cache is rejected on reopen and the new complete graph is built once.
Avoiding that rebuild is a remaining M5 lifecycle task, not a guarantee of this
format or a completed M6 performance gate.
