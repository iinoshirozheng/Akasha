# JSON bitmap shards and incremental publication — 2026-11-14

## Delivered behavior

Collection create/rebuild/cache-miss training partitions the captured ID-ordered
snapshot into groups of at most 4,096 rows. Global inference precedes shard
construction, so a null-only first shard cannot choose Utf8 prematurely. Each
shard uses local ordinals and its own definition/point-ID/payload fingerprint.
Unchanged validated shards are reused; changed/missing/invalid groups retrain.

The Lance cursor/min-heap/equal-key union algorithm merges mapped shards into a
new v1 payload, rebasing local ordinals to the current snapshot. A preflight pass
counts bytes and keys; a second pass writes the envelope/payload/CRC in bounded
chunks. No complete owned output bitmap or encoded payload is constructed. The
result remains mapped and uses the existing per-posting lazy cache.

Collection writers publish changed shard files, then the merged cache, with
file-fsync/atomic-replace/directory-fsync per file. Matching shards retain inode
and bytes. Obsolete tail files are removed after successful full publication;
last-definition drop removes known shard slots. Snapshot demand never publishes.
An interrupted multi-file publication is safe because these are optional caches,
and every shard/full-cache reuse checks its corresponding source identity.

Anonymous staging mappings retain their inodes independently of file descriptors;
unneeded descriptors are closed, and staging/duplicate handles are close-on-exec.
`MappedFile.from_file` borrows the owner through duplication, avoiding an early
FileHandle destructor after extracting a bare descriptor number.

## Validation evidence

Environment: macOS arm64, Mojo 1.0.0 (`ed45d567`).

- `test_json_bitmap_shards.mojo`: **2 passed**. Five scalar types, cross-shard
  duplicate keys/nulls, interleaved keys, global ordinal rebasing, empty input,
  type/definition/dimension rejection, cancellation, mapped output, released
  descriptors and byte-identical payload/envelope CRC validation against an
  owned full build.
- `test_json_bitmap_codec.mojo`: **4 passed**, retaining all-type/truncation,
  corruption, LRU, concurrent readers and mapping lifetime checks.
- `test_json_bitmap_cache.mojo`: **1 passed**, including reopen hit with injected
  training failure, changed-source miss, corrupt full cache and repaired reopen.
- `test_mapped_file.mojo`: **12 passed**, including anonymous file duplication,
  close-on-exec flags, writer close, descriptor release and surviving reads.
- `test_bitmap_sort.mojo`: **4 passed**, retaining sort/spill failure and cleanup
  coverage after moving anonymous-file creation into the shared storage helper.
- Native commands use `pixi run mojo run -I src tests/mojo/<file>`.
- `pixi run build-python`: **passed**.
- Ten related Python suites: **211 passed**, four existing deprecation warnings.
  `test_json_bitmap_shards`, `test_json_bitmap_disk_cache`, `test_json_catalog`,
  `test_json_catalog_fsync`, `test_json_arrow_scanner`, `test_arrow_scanner`,
  `test_rich_arrow_scanner`, `test_jsonb_projection`, `test_jsonb_condition`,
  `test_binding_conversion_close`.

The five new public shard tests cover unchanged-shard inode/mtime/byte reuse,
changed-shard replacement, insertion-induced ordinal shifts, shrink cleanup,
drop/close with an old prepared query, valid-CRC bad ordinals, truncated shards,
snapshot demand without persistent writes, v1 full caches without shards,
global inference after a null-only first shard, and restart after publishing
one changed shard while blocking publication of the next.

- `test_json_catalog_collection.mojo`: **3 passed**, preserving catalog lifecycle,
  learned type and parallel preparation/failure semantics.
- `test_json_scanner.mojo`: **2 passed**, including compaction ownership and
  expired-deadline cleanup.

Total targeted native tests: **28 passed**. `git diff --check` also passed.

## Limits and interpretation

This is source-group reuse, not per-write delta indexing. Inserting/deleting IDs
can shift subsequent groups and require their rebuild. Full source fingerprints
and integrity checks still scan data; no performance improvement is claimed.

The existing final limits remain 1,000,000 rows, 64 MiB logical decoded state and
128 MiB encoded payload. Input shard file lengths plus merged staging length are
bounded by 512 MiB. Cursor/heap key storage has a 64 MiB logical bound; each input
shard's temporary directory validation is released before the next. Sort staging
has its separate pre-existing 512 MiB cap. These are not a process-wide disk quota
or peak-RSS promise; allocator capacity, current posting/encoding workspaces,
source snapshots, mapped pages and active query results remain outside the caps.

No authoritative schema migration is required. Existing AKIC/v1 full caches remain
compatible; shards use the same payload with slot-specific generation and source
checksum. Full CPU/platform/power-cut/performance gates were not rerun; targeted
failure, corruption and restart tests cover the changed derived-cache paths.

Upstream: Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-index/src/scalar/bitmap.rs::merge_shards` and equal-key draining.
Akasha file identities, temporary ownership and incremental publication policy
are adaptations, not a Lance file-format implementation.
