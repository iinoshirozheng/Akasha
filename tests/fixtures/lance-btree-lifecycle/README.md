# Lance B-tree lifecycle source oracle

Regenerate with `pixi run python scripts/lance_btree_lifecycle_reference.py`.

105 inputs cover five scalar types, empty/nonempty old rows, NULL, NaN,
infinities, signed zero, removed rows, appended rows, absent remap entries,
explicit deletion and ID reassignment. Each case records update and remap rows:
210 independently generated operation results. Equal-key output order is not
part of the comparison; row identity/value and Float64 bits are.

The generator verifies pinned Git source bytes and extracts unchanged Lance
`merge_segments`, `filter_row_ids`, `filter_keeps_nothing`, `remap_row_ids`,
`FlatIndex::remap_batch`, the old-ID filter mask and `OneShotExec`. Update uses
actual DataFusion 54.1.0 UnionExec/SortPreservingMergeExec and Arrow 58.4.0.
The original source is copyright The Lance Authors, Apache-2.0.

Adapters supply in-memory batches, exact set/map row-ID containers, schema names
for display and the final row collector. Chunking is identity, and training/file
IO are replaced by that collector. No Lance file codec, fragment-reuse mapper,
partitioned index, scheduler, spill-policy or durable-publication parity is
claimed. Inputs use Arrow sorting before the upstream sorted-stream merge.

`sources.json` records pinned source/unit, generator, scaffold, fixture and lock
hashes. Dependency archives are checked against Cargo.lock; Arrow/DataFusion
source files are compared byte-for-byte with those archives. Akasha native tests
independently verify local persistence, duplicate-ID rejection and failures.
