# B-tree lookup validation — 2026-11-14

The native page directory matches the frozen original-source oracle on 183
page datasets and 48,720 queries. Exact comparisons include page ordering and
All/Some flags, across five scalar types and three page sizes. Source provenance
and reproduction instructions are in `tests/fixtures/lance-btree-lookup/`.

`pixi run mojo run -I src tests/mojo/test_lance_btree_lookup.mojo`:
3 tests passed (source corpus, duplicate-minimum/straddling regression, and
null/empty/control/statistics validation). Compiler: project Mojo 1.0.0.

This evidence covers the resident lookup directory only. Native leaf rows,
lazy persistent pages, leaf predicate parity, catalog migration, Python/HTTP,
JSON/Arrow dispatch and recovery remain outstanding under the full B-tree plan.

## Subsequent paged target and JSON training validation

`test_lance_btree_predicate.mojo`: 4 passed, including 16 original-source
DataFusion datasets, 4,063 queries with both NULL-tracking modes (8,126 searches).
`test_lance_btree.mojo`: 5 passed. Its whole-index oracle executes original
Lance search_with_options/search_page with source lookup and DataFusion leaf
predicates: 24,378 searches at page sizes 1/3/7 match exact raw selected/null sets.
The test also covers five-type spill/reopen, bounds, duplicate values, full u64
row IDs, cancellation/resource limits, every payload truncation, valid-CRC
semantic corruption, duplicate IDs, invalid CRC, failed publication, atomic
replacement, retained old mappings and the 8 MiB leaf split threshold.

`test_lance_json_btree.mojo`: 2 passed. The 786 original JSON streaming cases run
through the shared extraction/type-learning/external-sort path into native
leaves, including exact conversion errors and learned-type timing. A focused
case verifies null-prefix inference, closed trainers and expression guards.
Only a bare equivalent getter key can use a mask; JSONPath spelling alone is
insufficient. Unbounded ranges stay residual because raw Lance makes NULL true
where the existing JSON expression contract keeps UNKNOWN.

`test_lance_json_stream.mojo`: 6 passed after adding shared finish_sorted input
transfer and using it in the existing externally sorted bitmap finish path.
No bitmap is built as an intermediate representation for B-tree training.

These results cover the native paged target, JSON trainer and query guards.
Catalog migration, root-owned B-tree registry, collection reuse/recovery,
Python/HTTP creation and prepared JSON/Arrow dispatch remain outstanding.

## Shared-path regression and provenance

After extracting the mmap publisher into index_cache.publish_mapped_cache:
`test_index_cache.mojo` 5 passed, `test_json_bitmap_shards.mojo` 2 passed,
`test_json_bitmap_cache.mojo` 1 passed and `test_json_catalog_collection.mojo`
3 passed. Together with the paged/predicate/JSON-training suites above, this
implementation step ran 28 targeted native tests successfully. The unchanged
lookup suite previously passed 3 tests against 48,720 source queries.

The combined leaf/paged reference generator reran successfully with identical
case bytes after dependency provenance was added. All 154 locked dependency
archives were checksum-verified; 476 Arrow/DataFusion Rust source files were
compared byte-for-byte with those archives. Fixture, lock, generator and
scaffold hashes match sources.json. Relevant licenses remain under
`docs/upstream/licenses/`. These crates are reference-tool dependencies only;
the runtime remains native Mojo and gains no DataFusion dependency.

Python bindings were not rebuilt in this step; their B-tree API is still pending.
No full-product, GPU, power-cut or performance gate is claimed.

Subsequent catalog/public integration and the final four-part audit are complete;
see [full-scope validation](2026-11-14-json-btree-integration-validation.md).
The earlier remaining-work statements above describe this report’s native-only
checkpoint, not the final status.
