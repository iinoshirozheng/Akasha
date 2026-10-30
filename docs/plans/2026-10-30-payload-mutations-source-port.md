# D05a collection payload mutations

Continue the complete feature ledger, before optimization. Source baseline is
Qdrant v1.19.0 `74f3e85b9473c62560006c043e13737ce6b48412`:
`lib/shard/src/update/payload.rs`, `update/mod.rs`, `operations/payload_ops.rs`,
`segment/src/segment/entry.rs`, and the already ported JSON-path/map operations.

1. Adapt the source root-map operations to ordered DocumentField lists, keeping
   the document root outside the existing 64-level per-field bound. Reuse native
   value traversal/merge/remove; overwrite retains null, merge removes null.
2. Add a native PayloadUpdate operation and prepare complete payload replacement
   PointMutations for live IDs or the existing native filter. IDs take precedence
   when both selectors are present, matching source dispatch. Missing IDs fail.
   Explicit duplicate IDs select a point once; filter selection is ID ordered.
3. Select, read, transform and commit under the collection writer lock and its
   existing backpressure admission. Preserve all vector fields and snapshot
   owners. Use the existing checksummed atomic batch; no new durable format.
   Akasha atomic batches reject the whole operation on any failure, rather than
   reproduce Qdrant's possible partial updates across internal chunks. Empty
   selection returns count=0, first_sequence=0 and unchanged last_sequence;
   native row sequences are not Qdrant operation-acknowledgment numbers.
4. Expose Python set_payload/overwrite_payload/delete_payload/clear_payload and
   corresponding current HTTP routes. Python only transports requests; Mojo
   owns selection, path semantics and mutation. Recheck owner after conversion.
   Respect max_batch_rows for explicit and filter-selected targets.
5. Compare root-map results to existing original-source fixtures; verify null,
   order, wide indexes, wildcard/idempotent deletion and maximum-depth values.
   Test public storage/reopen, snapshots, preserved vector types, filters,
   duplicate/missing/empty selectors, resource errors, torn atomic WAL and
   conversion re-entry. Record source hashes, boundaries and evidence.

This does not close D05: combined operation batches, full vector/filter CRUD and
Qdrant-compatible REST/gRPC remain. D01 rich Arrow, D02 keys/IDs, D03 nested
indexes, formula integration, Lance/SQL/UI/security/cluster and all other ledger
items stay open. No performance gate or parameter retuning is included.
