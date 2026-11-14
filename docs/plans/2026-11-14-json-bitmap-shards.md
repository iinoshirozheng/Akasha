# JSON bitmap shards and incremental publication

Build the next storage layer using Lance's pinned `bitmap.rs::merge_shards`
(`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`) cursor/min-heap/union algorithm,
Mojo BinaryHeap and Akasha's existing AKIC/v1 bitmap format and atomic publisher.

- Partition the captured ID-ordered snapshot into at most 245 groups of 4,096
  rows. Infer the target globally before building any group; all-null prefixes
  cannot fix the type prematurely.
- Store shard-local dense ordinals. Fingerprint each group using its point IDs
  and canonical payloads plus full index definition. Reuse only matching,
  validated shards; rebuild missing, stale or corrupt groups from authority.
- Stage changed groups in anonymous mapped files. Retain mappings through shared
  owners, release unnecessary descriptors, and never publish from snapshot demand.
- Merge with a cursor and heap head per shard, union equal keys, and add each
  shard's current row base. Validate/count in a first pass, then stream v1 bytes
  in a second pass. The result is mapped, with lazy decoded posting retention.
- Under existing writer/file exclusion, publish only changed shards, then the
  merged cache, using temporary write, file fsync, atomic replace and directory
  fsync for each file. There is no cross-file authority transaction: partial
  publication remains valid because every derived file is source-validated.
- Remove obsolete tail shards after successful full-cache publication; drop
  removes known shard names only when no definition shares the projection/type.

No new dependency or authoritative format migration. Existing full v1 caches
remain readable. Native in-memory training still serves its documented API.
Snapshot builds and collection create/rebuild use shards and streaming output.

Verify all scalar types and interleaved key unions against an owned build;
validate nulls, empty shards, mismatches, cancellation and descriptor ownership.
Public tests cover unchanged-shard inode reuse, changed-shard replacement, row
rebasing after insertion, shrinking/drop, valid-CRC corruption, no writes during
snapshot demand, old prepared query lifetime and restart after partial publication.
Keep builds serial and preserve preceding uncommitted implementation layers.

Bounds remain 1,000,000 rows, 64 MiB logical final bitmap and 128 MiB encoded
payload. Shards plus staged merge output are bounded by 512 MiB, with a 64 MiB
logical cursor/heap head budget. Batch/sort workspaces, mapped pages and active
queries are outside these logical limits. This is not a global peak-RSS bound.

Completed: [28 native / 211 Python tests and publication recovery validation](../research/2026-11-14-json-bitmap-shards-validation.md).
