# JSON bitmap lazy postings validation — 2026-11-13

## Delivered behavior

Optional v1 JSON bitmap caches now retain a mapped artifact, ordered key directory
and posting offset/count pairs. No whole-payload copy or posting materialization
occurs during mapped open. Existing search/null semantics, update/remap and cache
encoding all use the same posting accessors.

The synchronized LRU retains at most 128 postings and 8 MiB logical storage per
mapped index. Byte and entry bounds are independent. Oversized postings bypass
retention, missing keys bypass the cache, and returned owned sets survive eviction.
The mapped owner survives atomic replacement, unlink and collection lifetime.

Full envelope CRC, key validation and complete ordinal validation remain mandatory.
A temporary coverage bitset replaces the full decoded `seen` set. The original
64 MiB decoded-state limit is checked from container cardinalities without building
postings, and directory size has its own 64 MiB bound. Existing v1 files need no
migration. Invalid optional files still rebuild from authoritative documents.

## Evidence

Environment: macOS arm64, project Mojo 1.0.0 (`ed45d567`).

- `pixi run mojo run -I src tests/mojo/test_json_bitmap_codec.mojo`: **4 passed**.
  Five scalar targets; owned/mapped equality, IN and null parity; range, update,
  remap and bit-exact encoding; no eager loads; LRU hit/eviction; independent byte
  bound; zero-capacity bypass; eight concurrent readers; cancellation on access;
  old mapping after atomic replace/unlink; all payload truncation positions;
  duplicate ordinals inside valid-CRC envelopes.
- `pixi run mojo run -I src tests/mojo/test_json_bitmap_cache.mojo`: **1 passed**.
  Reopen bypasses injected training failure; source changes miss; corrupt cache
  rebuilds; explicit rebuild repairs the optional artifact.
- `pixi run build-python`: **passed**.
- Nine related Python suites: **205 passed**, four existing deprecation warnings.
  `test_json_bitmap_disk_cache`, `test_json_catalog`, `test_json_catalog_fsync`,
  `test_json_arrow_scanner`, `test_arrow_scanner`, `test_rich_arrow_scanner`,
  `test_jsonb_projection`, `test_jsonb_condition`, `test_binding_conversion_close`.

Additional native regressions: **25 passed** (`test_lance_bitmap`: 5,
`test_lance_json_stream`: 5, `test_borrowed_binary_reader`: 4,
`test_mapped_binary_reader`: 4, `test_storage_checksum`: 7), each run with
`pixi run mojo run -I src tests/mojo/<name>.mojo`.
Total targeted native tests: **30 passed**. `git diff --check` also passed.
The full CPU suite and platform/performance gates were not rerun.

## Limits and remaining work

This is lazy decoding and bounded decoded-posting retention, not bounded startup
I/O: opening still scans the entire cache and fingerprints source documents.
Memory bounds exclude allocator capacity, mapped pages, directory and active query
copies/unions; they are per index rather than process-wide. In-memory training
continues to materialize postings. External sorting/spill and disk shard k-way
merge/incremental publication are the next storage layers. No performance or
full-product acceptance claim is made.

Upstream architecture reference: Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-index/src/scalar/bitmap.rs` `load`/`load_bitmap`. Akasha retains its own
file format and cache policy; this is not a new Lance file-format port.
