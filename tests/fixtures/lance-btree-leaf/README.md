# Original Lance B-tree leaf and paged query oracle

Run `pixi run python scripts/lance_btree_leaf_reference.py` from the root.
This also regenerates the prerequisite lookup corpus. Rust dependencies are
pinned in Cargo.lock; archive checksums and verified source-file hashes are
recorded in sources.json. The generator checks the exact pinned Lance checkout
and rejects edited source files before extraction.

Pin: `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`. Executed unchanged bodies:
`SargableQuery::to_expr`, `FlatIndex::search`, `search_prebuilt`, `eval_expr`,
`all`, `all_ignore_nulls`, `all_non_null`, plus `BTreeIndex::search_with_options`,
`search_page`, `compile_predicate` and the original lookup/statistics methods.
DataFusion 54.1.0 and Arrow 58.4.0 execute the actual predicate expressions.

Adapters provide materialized BTreeSet row-address sets, no-op metrics,
immutable Arrow batches in an in-memory page reader and one task at a time.
The constructor directly computes all/null row sets. Row IDs are unique dense
ordinals; sorting preserves stable duplicate-value order. The oracle does not
exercise Lance's on-disk codec, cache, async I/O concurrency or training store.

16 input datasets cover five scalar types, empty inputs, mixed/null values,
NaN payload/sign bits, infinities, signed zeros, UTF-8 and binary values.
4,063 queries are evaluated with and without NULL tracking (8,126 leaf
searches), then at page sizes 1/3/7 (24,378 whole-index searches). Results retain
raw selected/null sets, including their overlap in All shortcuts.

Native tests:

```
pixi run mojo run -I src tests/mojo/test_lance_btree_predicate.mojo
pixi run mojo run -I src tests/mojo/test_lance_btree.mojo
```

Licenses: Lance, DataFusion and Arrow are Apache-2.0; copies and notices are in
`docs/upstream/licenses/`. Shared scalar ordering also uses the previously
recorded Rust total-order implementation. See sources.json for exact provenance.
