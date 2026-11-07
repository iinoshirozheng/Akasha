# JSON bitmap disk-cache acceptance

First storage layer from the [plan](../plans/2026-11-08-json-bitmap-disk-cache.md).
Mojo 1.0.0 (ed45d567), macOS arm64. Local Lance reference remains pinned at
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`; bitmap.rs key/posting persistence
and lazy loading were inspected. No Lance file-format or new algorithm port is
claimed. Akasha's existing cache envelope, atomic publication and source checksum
pattern are reused. The [payload format](../formats/json-bitmap-cache-format.md)
stores fixed type, provenance, exact definition and sorted key/posting lists.

## Evidence

- `test_json_bitmap_codec.mojo`: two passed. All five scalar types, negative
  integer, signed-zero Float64 bits, Unicode/binary, nulls, empty source,
  all-byte truncations, trailing data, invalid header/Boolean/provenance,
  wrong definition/count and duplicated/unordered/out-of-range ordinals.
- `test_json_bitmap_cache.mojo`: one passed. Create publishes a file; actual
  reopen succeeds with training failure injection enabled, proving a disk hit.
  Later data changes bypass the old cache; old prepared queries keep their view.
  Explicit rebuild changes the file, CRC corruption triggers safe rebuild, and
  a subsequent repaired reopen again bypasses training.
- `test_json_catalog_collection.mojo`: three passed. Concurrent first-build test
  now removes the optional disk cache before forcing a training failure; without
  this test setup adjustment it correctly hit the cache and did not raise.
- `test_index_cache.mojo`: final five passed. A preexisting frozen fingerprint
  test failed on both current code and an isolated HEAD source tree with exactly
  the same numbers. Its expected values predated default payload v3. The new
  independent `scripts/cache_fingerprint_reference.py` reproduces all old v1
  constants and calculates the v3 replacements; production checksum code was not
  changed. Baseline output: `.build/json-cache-baseline/result.log`.
- `pixi run build-python`: passed.
- Python suites `test_json_bitmap_disk_cache`, `test_json_catalog`,
  `test_json_catalog_fsync`, `test_json_arrow_scanner`, `test_arrow_scanner`,
  `test_rich_arrow_scanner`, `test_jsonb_projection`, `test_jsonb_condition`,
  `test_binding_conversion_close`: **205 passed**, four existing warnings,
  15.10 seconds. New tests verify shared-definition file retention/removal,
  actual temporary-file write failure preserving prior bytes, corrupt reopen,
  and repair through the public rebuild API.
- `git diff --check`: passed. No changes were committed or pushed by this task.

The new codec's mutation test initially failed to compile because an Int ternary
was assigned to UInt8; explicit conversion corrected it before the passing run.
Intermediate runs overlap and are not summed. The native evidence totals 11
distinct tests; this is not a full native/platform/performance run.

## Completed boundary and remaining layers

Catalog authority is unchanged. Cache load occurs on first root-local artifact
demand; it validates envelope/source/definition before full payload decoding.
Only collection create/rebuild publishes; snapshots are read-only. Publication
is best-effort, and invalid caches reconstruct from authoritative data. Drop
cleans up unshared cache definitions; physical backup can omit these derived
files and restore rebuilds them. Native/Python/Arrow semantics remain unchanged.

Whole-payload decode still materializes the bounded bitmap target. Per-posting
mapped access, bounded paging cache, external sorting/spill and source shard
k-way merge remain the next layers. This report does not close those items or
claim complete Lance disk-index compatibility/performance.
