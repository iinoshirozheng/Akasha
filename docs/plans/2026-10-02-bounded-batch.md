# Bounded legacy batch publication

The resident mixed benchmark shows 8-point legacy replacement p95 of 13.7 ms at
128D and 23.7–36.4 ms at 1536D. `_apply_batch_unlocked` clones the whole MemTable
and rebuilds every metadata posting before appending one v3 envelope. Named-field
authority already prepares only affected IDs in `PointTable._prepare` and blocks
operations after uncertain I/O or derived publication failure.

Reuse that prepare/commit/publish rule in the legacy path without a format change:

1. Validate the complete input before changing authority; seed a small MemTable
   only on each affected ID's first appearance, sharing its immutable owners.
2. Apply repeated mutations in input order to these states. New stable slots
   follow first appearances; final entries preserve sparse owners unless deleted.
3. Set the failure latch before appending/fsyncing the existing atomic envelope.
   Publish only final affected states under the writer lock. Keep the latch set
   on any append or publication exception; recovery resolves durable authority.
4. Update metadata only for those IDs. Exact representation equality can skip an
   existing live payload, after validation and bulk duplicate checks. Preserve
   type, name, order and signed-zero bits; empty tombstones still resurrect.
5. Publish one immutable read state; process every sparse deletion and update
   HNSW once per final dense mutation. Existing snapshots remain valid on failure.

The first measurement removed 38% of write p95 but regressed 8192-point ingestion
by 12%. Incremental metadata insertion exposed existing full posting scans and
adjacent swaps. The next layer keeps the same sorted representation and total
order, finds full entry keys by binary search, and uses the official `List.insert`
and indexed `List.pop` to move descriptors. Three posting types share the helper;
bulk loading still appends/sorts and permits removal before sorting.

Reference inspection: local Qdrant's immutable numeric index uses binary search
on sorted `(value, point)` entries in
`lib/segment/src/index/field_index/numeric_index/immutable_numeric_index/mod.rs`.
Its tombstone bitmap is unnecessary for Akasha's existing mutable arrays.
Mojo's [List API](https://mojolang.org/docs/std/collections/list/List/) provides
the descriptor insertion/removal operations; compilation on pinned 1.0.0 verifies
their availability despite current documentation being version 1.1.0. The
algorithm index exposes no ready-made ordered posting container. No dependency,
new persisted index, full-table copy or threshold heuristic is introduced.

Validation covers WAL failure, partial derived publication after committed WAL,
old roots, repeated/negative IDs, stable ordinals, sparse delete/reinsert, typed
payload changes, signed zeros, duplicate postings and unsorted bulk removals.
Measure fresh ingestion and mixed maintenance against the saved pre-change binary
in alternating serial processes; retain failed screens and every timing sample.
No Qdrant or non-resident parity claim follows from this local optimization alone.
