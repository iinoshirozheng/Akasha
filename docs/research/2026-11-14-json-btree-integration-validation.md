# Native B-tree full-scope validation — 2026-11-14

The authorized four-part B-tree scope is implemented: pinned source parity,
native paged storage/search, durable catalog and public query integration, and
failure/recovery/compatibility validation. Environment: macOS arm64, project
Mojo 1.0.0 (`ed45d567`). Earlier bitmap/shard work remains preserved.

## Requirement audit

| Requirement | Implementation and direct evidence |
| --- | --- |
| Source ordering, NULL, NaN and range contracts | Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`; lookup and leaf fixture generators execute original lookup/statistics/search bodies and actual DataFusion/Arrow predicates. 48,720 lookup queries, 8,126 leaf searches and 24,378 paged searches match. Six fixture/lock/provenance artifacts reproduced byte-for-byte. |
| Real native paged B-tree | `lance_btree.mojo`, `lance_btree_lookup.mojo`, `lance_btree_predicate.mojo`, `btree_pages.mojo`: sorted value/row-ID leaves and resident page statistics, independent mmap leaf decoding, Eq/range/IN/IS NULL, checked resource/cancellation paths. No bitmap intermediate. Five scalar types, cross-page duplicates, signed-zero/NaN bits and u64 IDs are source-tested. |
| JSON training and guarded substitution | Shared sorted JSON input feeds the B-tree directly; all 786 original JSON streaming cases pass with exact conversion errors/type-learning timing. Typed getter/path equivalence and string provenance are retained. NULL literals/IN members/bounds and unbounded ranges stay residual; empty IN preserves FALSE including NULL. |
| Durable kind/schema migration | Catalog v2 supports kinds 1/2; bitmap-only/empty catalogs keep canonical v1 bytes. Old v6/v1 fixture still round-trips byte-for-byte; independently packed mixed-kind v2 fixture round-trips. Unknown kind/version and malformed/truncated sections reject recovery. Point formats and outer manifest v6 are unchanged. |
| Root/snapshot ownership | One bounded artifact registry keyed by kind/column/path/target; native lifecycle tests prove one concurrent build, failed rebuild preserves prior ready state, learned types persist, and old prepared queries survive writes/compaction/drop/close. A later unhandled index does not clear an earlier valid mask. |
| Public lifecycle and query execution | Native create/list/drop/rebuild, Python `kind="btree"`, HTTP kind selection/listing and existing prepared JSON/Arrow scanner dispatch are tested. Default bitmap behavior remains; listing adds `kind`. Tests include 5,000 rows spanning two pages and four public typed getters. |
| Cache integrity/recovery | Kind-6 cache reuse checks exact envelope/source identity and dense ordinal domain. Native tests cover every payload truncation, valid-CRC semantic corruption, duplicate IDs, CRC errors, page limits, failed publication and held mappings. Public tests cover stale source, torn/invalid caches, snapshot-only rebuild without publication, repair and restart. Native injected trainer failure proves a valid reopen cache hit avoids training. |
| Authoritative publication/recovery | Public tests reconstruct create/drop states before rename, torn/full temporary writes and after rename; only committed manifest wins. Actual directory-fsync failure injection runs for bitmap and B-tree and requires writer reopen. Backup/restore retains B-tree definitions; corrupt committed authority is not replaced by a valid temporary file. |
| Build/regression/documentation | Both `build-python` and `build-mojo` passed (the two constituents of `pixi run build`, including native worker). 17 targeted integration Mojo tests and 227 related Python tests passed. Format, API, migration and validation docs are updated; `git diff --check` passed. |

## Commands and results

Native commands: `pixi run mojo run -I src tests/mojo/<file>.mojo`.

- `test_json_catalog`: 3 passed.
- `test_manifest_json_catalog`: 3 passed.
- `test_json_catalog_collection`: 3 passed.
- `test_json_btree_collection`: 4 passed.
- `test_json_btree_cache`: 1 passed.
- `test_json_bitmap_cache`: 1 passed.
- `test_json_scanner`: 2 passed.

Python commands used `pixi run env PYTHONPATH=python:. pytest -q`:

- `tests/python/test_json_btree.py`: 15 passed.
- Ten related suites: 212 passed — `test_json_bitmap_shards`,
  `test_json_bitmap_disk_cache`, `test_json_catalog`, `test_json_catalog_fsync`,
  `test_json_arrow_scanner`, `test_arrow_scanner`, `test_rich_arrow_scanner`,
  `test_jsonb_projection`, `test_jsonb_condition`, `test_binding_conversion_close`.
- Four existing deprecation warnings: Starlette/httpx and native Python types
  without `__module__`; no new failures.

`pixi run build-python` and `pixi run build-mojo` completed successfully. The
public-only Protocol annotation/HTTP whitespace cleanup after compilation has
no runtime/native change; Python compile checks also passed.

Earlier unchanged native-target/source evidence is retained in
[lookup and paged validation](2026-11-14-json-btree-lookup-validation.md) and the
fixture provenance files; those successful checks were reused rather than
repeating unchanged source tests.

## Contract and validation limits

This is an Akasha derived format following Lance's page architecture, not a
Lance file-format implementation. Opens perform full integrity/source scans;
only leaf materialization is lazy. No per-write incremental B-tree update,
performance improvement, full SQL planner, whole-product test pass, Linux/GPU
run, actual power-loss or device-level durability claim is made. The changes
are CPU-only and do not modify GPU behavior. Targeted crash-state reconstruction
and actual fsync fault injection cover the changed authoritative publication
paths; the complete crash/CPU suites were not rerun.

The four-part B-tree goal has no remaining implementation or validation item
within this scope. This does not complete the repository's broader feature
roadmap. No commit or push was performed for this implementation step.
