# B-tree lifecycle and incremental collection rebuild validation

Environment: macOS arm64, Mojo 1.0.0 (`ed45d567`).

## Independent upstream comparison

`pixi run python scripts/lance_btree_lifecycle_reference.py` executes unchanged
Lance `merge_segments`, old-row filtering, `FlatIndex::remap_batch`, and
`OneShotExec` at `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`.
The update path uses actual DataFusion 54.1.0 UnionExec/SortPreservingMergeExec.
105 cases produce **210 operation results**, all matched by Mojo, including
five types, NULL, NaN, infinities, signed-zero bits, deletion and ID reassignment.

The three generated artifacts reproduce byte-for-byte. **211 dependency
archives** match Cargo.lock, and **731 Arrow/DataFusion source files** match
those archives. The fixture README records IO/row-set adapters and exclusions.

## Native behavior and integration

Commands: `pixi run mojo run -I src tests/mojo/<name>.mojo`.

- `test_btree_lifecycle`: **4 passed**, including the upstream corpus, 5,000-row
  forced-spill update, explicit replacement, mapped publication/reopen,
  duplicate-ID/type rejection, all-deleted output, cancellation and limits.
- `test_json_btree_collection`: **5 passed**, including incremental rebuild after
  insert/delete/update ordinal changes, learned-type failure retaining baseline,
  cache temporary-directory failure and repair, compaction/reopen, old snapshots,
  alias/kind isolation, close/drop release and concurrent snapshot preparation.
- `test_lance_json_btree`: **3 passed**, including all 786 original JSON
  stream cases, update type/path retention, closed trainer and persisted string
  provenance for both ordinary strings and date extensions.

Total: **12 native tests passed**.

`pixi run build-python`: passed.

`pixi run env PYTHONPATH=python:. pytest -q tests/python/test_json_btree.py tests/python/test_json_catalog.py tests/python/test_json_catalog_fsync.py tests/python/test_json_arrow_scanner.py tests/python/test_binding_conversion_close.py`: **111 passed**, with four existing deprecation warnings. Coverage includes three successive ordinal-changing updates compared with unindexed scans, failed learned-type conversion, held snapshots, reopen, HTTP lifecycle, Arrow ownership, catalog fsync failure and binding close.

`git diff --check`: passed. The complete CPU/crash/GPU suites and separate
worker build were not rerun for this scoped change.

The collection keeps one successful B-tree root/index baseline, never a chain.
Changed/new rows alone pass through JSON conversion; unchanged exact JSONB
columns reuse old scalar values after remapping to current dense ordinals.
The existing writer-lock sequence/catalog guard controls both persistent cache
publication and advancement of the baseline. Build failure leaves the old
baseline and published cache untouched; optional publication failure does not
invalidate the current query result. Snapshot-only demand never publishes.

## Scope and limits

No durable schema or API shape changed. Cold/different-definition rebuilds use
full training. This is incremental extraction during explicit writer rebuild,
not per-write delta maintenance: source comparison and output page rewriting
still happen. One baseline retains its captured root until replaced, final
matching definition drop, or close. Existing memory/disk/row bounds remain.

Upstream comparison covers lifecycle row results, not Lance file encoding,
fragment-reuse mapping, partitioned indexes, DataFusion spill policy, or durable
IO. Native publication/recovery tests exercise Akasha's existing kind-6 format.
No full-product, Linux/GPU, performance or actual device power-loss claim.
