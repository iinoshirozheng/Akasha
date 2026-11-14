# JSON bitmap external sort validation — 2026-11-13

## Delivered

Collection create/rebuild/cache-miss training now uses an 8 MiB logical sort-run
budget and 512 MiB combined temporary-file limit. Sorted runs are written into
an anonymous POSIX file; stable two-way merge passes retain two row heads and
two files. The final row stream feeds the existing bitmap value-run algorithm
without collecting all sorted input into a List.

Only converted key/row-ID pairs spill. Long null-only inference prefixes stage
IDs without retaining extracted JSON; type selection still waits for the first
non-null value or EOF. Standalone native in-memory training keeps its documented
aggregate input bounds. No failed external build retries using an unbounded path.

Temporary files are exclusive mkstemp files, immediately unlinked and RAII owned.
Records have length, type and CRC checks. Flush/merge disk limits, cancellation,
invalid data and I/O errors abort staging; failed output is never published.
No authoritative format or catalog transition changed.

## Validation

Environment: macOS arm64, project Mojo 1.0.0 (`ed45d567`).

- `pixi run mojo run -I src tests/mojo/test_bitmap_sort.mojo`: **4 passed**.
  Five scalar types, nulls, signed-zero/NaN preservation, multi-pass merge,
  stable ties, no-file empty input, oversized-row behavior, row limit,
  descriptor cleanup, anonymous directory contents, truncated temporary file,
  unavailable directory, flush and merge disk-budget failures, cancellation,
  long null prefix, external update and final bitmap limits.
- `pixi run mojo run -I src tests/mojo/test_lance_json_stream.mojo`: **6 passed**.
  All **786 original Lance stream scenarios** also run through forced external
  sorting: **593 successes and 193 expected errors**, preserving type, inference
  timing, result membership and error messages.
- `pixi run mojo run -I src tests/mojo/test_lance_bitmap.mojo`: **5 passed**,
  including original train/search/merge/remap oracle and exact state bounds.
- `pixi run mojo run -I src tests/mojo/test_json_bitmap_codec.mojo`: **4 passed**,
  retaining lazy mapped posting/cache and corruption coverage.
- `pixi run build-python`: **passed**.
- Nine related Python suites: **206 passed**, four existing deprecation warnings.
  Suites: `test_json_bitmap_disk_cache`, `test_json_catalog`,
  `test_json_catalog_fsync`, `test_json_arrow_scanner`, `test_arrow_scanner`,
  `test_rich_arrow_scanner`, `test_jsonb_projection`, `test_jsonb_condition`,
  `test_binding_conversion_close`.
  The new public create/rebuild/reopen case supplies 9,600,000 converted string
  key bytes, exceeding the real 8 MiB default run threshold, while repeated keys
  keep the resulting bitmap small. Indexed queries return all 32 expected IDs.

- `pixi run mojo run -I src tests/mojo/test_json_catalog_collection.mojo`:
  **3 passed**, covering durable lifecycle, learned-type preservation and parallel
  preparation. Total targeted native tests: **22 passed**.
- `git diff --check`: **passed**.

Full CPU/platform/crash and performance gates were not rerun for this transient
build-stage change.

## Scope limits

Run bytes are logical and exclude stable-sort workspace, per-batch JSON
extraction/conversion, run descriptors, source snapshot and output bitmap. A
single oversized row may exceed the run target but is bounded by max_bytes;
merging retains at most two row heads. This is not a peak-RSS or global resource
pool guarantee. The final bitmap remains materialized and bounded at 64 MiB /
1,000,000 rows. Native temporary storage currently uses `/tmp` for collection
builds, with no public configuration API.

Next work is persistent bitmap shard k-way merge and incremental publication,
not another input-sort staging layer. Full disk-native output and overall product
acceptance remain open. No performance claim is made.
