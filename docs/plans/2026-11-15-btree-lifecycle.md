# Native B-tree update and row-ID remap

This layer adds immutable native lifecycle operations, independent upstream
comparison, and incremental collection rebuild publication. It does not add
another scalar index type or maintain indexes on every document write.

Source reviewed at the existing Lance pin
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`:

- `scalar/btree.rs::update`: filter old data, union new data, sort and retrain.
- `scalar/btree.rs::remap` and `scalar/btree/flat.rs::remap_batch`: retain
  unmapped IDs, remove explicit `None`, replace explicit IDs, retrain pages.

Use the existing external sorter for updates and a one-page stream for remap.
Rebuilding from source documents would repeat extraction unnecessarily; adding
a delta format would introduce another durable lifecycle. Both are unnecessary
for this native layer. Existing kind-6 page encoding and validation suffice.

The caller supplies the new source checksum and sequence explicitly. Update
accepts an optional old-ID removal set, so replacement requires explicit removal
of the previous row. Akasha's existing unique-ID invariant rejects collisions,
including remaps onto retained rows. No existing index or published file changes
on success or failure. New raw scalar values cannot establish JSON string-getter
provenance, so update conservatively clears that flag when adding rows; remap
preserves it because it changes IDs only.

- [x] Implement immutable update with bounded external sorting.
- [x] Implement streaming remap, preserving sorted key order.
- [x] Test replacement, deletion, absent mapping, collision, empty output,
  five scalar types, forced spill, cancellation, limits and mapped reopen.
- [x] Independent execution of upstream lifecycle routines for parity evidence.
- [x] Connect JSON learned-type handling and collection incremental publication.

The collection retains one successful B-tree baseline (root plus index), with
no predecessor chain. A matching `rebuild_json_index` reconciles document IDs
and exact JSONB column bytes, remaps unchanged rows to current dense ordinals,
and converts only changed/new JSON. The fixed learned type and conservative
string provenance flow through the JSON trainer. Cold or different-definition
rebuilds train from current documents. Snapshot-only rebuild remains a complete
read-only rebuild; it does not publish or change the writer's baseline.

Only the existing writer-lock sequence/catalog check can advance the baseline
and publish a cache. Cache publication remains best-effort; baseline staging
failure preserves the old version. Close and final definition drop release the
baseline. Persistent encodings are unchanged. This still scans source data and
rewrites the output artifact; it is not a per-write delta index or a speed claim.
