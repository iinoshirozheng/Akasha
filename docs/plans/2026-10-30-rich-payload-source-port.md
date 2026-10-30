# D01b rich payload source port

Continue the full feature-completion ledger; no optimization or scope reduction.

Source: pinned Qdrant v1.19.0 (`74f3e85b9473c62560006c043e13737ce6b48412`),
`segment/src/json_path/mod.rs`, `common/utils.rs`, and its workspace
`serde_json` dependency with `preserve_order`. Existing JSON-path grammar is reused.

1. Port owned null/array/object values and UInt64 transport without putting
   database semantics in Python. Mojo 1.0 rejects `List[Self]` recursive ownership;
   use the existing project's flat-arena pattern with inline scalars and bounded
   preorder container nodes. Preserve map insertion order and swap removal.
2. Port original get/set/remove and merge behavior. Explicit array indexes never
   grow arrays; index deletion is a no-op; wildcard deletion empties the array;
   merge null removes a member while direct JSON storage retains null. Publish
   a replacement only after complete construction succeeds.
3. Add the independently versioned payload v2 codec, keeping frozen v1 readers.
   Existing length-framed WAL/segment envelopes migrate on rewrite. No new
   storage algorithm or Qdrant-format compatibility claim.
4. Integrate owned Python/HTTP value conversion, scalar-index coexistence,
   payload byte accounting, physical backup and versioned NDJSON. Keep original
   scalar filter contracts; rich filtering/indexing belongs to D03.
5. Compile original upstream functions with preserved dependency configuration;
   compare native values, order and operations on source-produced fixtures.
   Validate limits/cycles, corruption/truncation, WAL-only and segment reopen,
   torn atomic batches, old-format migration and backup/logical round trips.
6. Run relevant native tests, full Python and recovery checks; register provenance,
   update contracts and ledgers, then commit locally. Do not push.

Remaining parts of the full goal include top-level arbitrary JSON keys (D02),
rich Arrow schemas with missing/null distinction, collection payload path update
APIs, nested filters/indexes, formula traversal/date/geo, protocol coverage,
Lance/version/schema/object storage, SQL/transactions, UI/security/cluster and
operations. The current scalar-only Arrow/C/distributed boundaries must reject
unsupported rich payloads explicitly rather than discard them. D01 and D03 are
not complete until their remaining public paths and acceptance gates pass.
