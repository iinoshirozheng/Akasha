# Reconcile named HNSW caches against current authority

Continuation of the authorized M5/M6 goal from `b0d791a`. This is a proposed,
unimplemented slice until its tests and measurements are recorded. No M5/M6 gate
is complete merely because the cache can be reused.

## Choice and contracts

Reuse a validated prior graph and apply current committed additions, replacements
and deletions on a private decoded index before publishing it to an immutable run.
The existing HNSW `upsert`, `delete`, structural validation, snapshot v2 tombstones
and `needs_rebuild` policy provide the required mechanisms. Rebuilding after the
existing inactive threshold is a normal cache miss; no new threshold is added.

Alternatives considered: a durable bundle of every read run would need to preserve
old shadowed authority and rebuild partition/visibility state, greatly expanding
the durable contract. Rebuilding a complete graph on every flush moves full build
latency into the writer. The private reconciliation step is smaller and does not
mutate a graph owned by a reader. [Hnswlib's documented incremental updates and
deletions](https://github.com/nmslib/hnswlib) support the general approach; Akasha's
own tested mutation/codec APIs remain the implementation, with no new dependency.

Use one new AKIC kind for a reconcilable field graph. Its payload prefixes the
existing graph snapshot with an exact field identity (ID/name/native scalar/
metric/dimension/graph configuration). The source checksum still binds sorted
current IDs and exact F32 projections. Identity equality is checked independently
of content freshness, which the original kind 4 cannot express for quantized or
normalized graphs. Kind 4 remains a recognized envelope, but an old field cache
is a safe miss and is replaced on a later flush/close. Authority formats, backup
requirements and file names are unchanged; optional caches require no authority
migration. This explicit cache invalidation must be documented and tested.

When the source checksum matches, require complete current graph coverage and
exact prepared-vector equivalence; a mismatch remains corruption/miss. When it
differs, verify the independent identity, delete missing/currently absent fields,
compare prepared vectors against authority, and upsert only additions/changes.
Check query cancellation during traversal and mutation, the existing rebuild
policy after mutations, and full graph/authority coverage before publication.
Every cache error leaves the ordinary authoritative rebuild path available.

Keep sorted live native row ordinals for source checksums and matched counts.
Admission masks must use graph slot count, including inactive slots. Reuse the
graph's current-ID map for slot lookup rather than a second dense-only map that
cannot represent replaced/deleted slots. Native F64 rerank always reads current
authority. Exact hits and reconciled loads are distinguished internally for tests
and evidence; no public API or new configuration layer is introduced.

Flush/close may save the already-ready base run even with a head/sealed runs.
This is a reusable seed, not a claim that it covers current collection state.
It is reconciled at the next open/query. Only the collection writer publishes;
both artifact and query locks retain their one-attempt nonblocking protocol.
Queries/held snapshots never write files. Retention remains one committed plus
one temporary file per field. Publication failure remains retryable.

## Implementation and validation sequence

1. Reproduce two missing behaviors on the baseline: ready base publication with
   later writes, and reuse after vector/presence/ID changes without full rebuild.
2. Implement the identity envelope, authority reconciliation and inactive-slot
   admission in an isolated copied tree; compile with installed Mojo 1.0.0.
3. Test additions/replacements/deletes/field removal, metadata and ordinal changes,
   all native types and supported graph codecs, empty/all-deleted cases, inactive
   rebuild threshold, malformed/CRC-correct wrong graphs and old-kind misses.
4. Cover repeated reopen, old snapshots, canceled/failed construction and retry,
   busy graph publication, close, compaction/backup and torn cache publication.
5. Run affected Mojo/crash tests, isolated complete Python, C ABI and examples.
6. Preserve the original corpora/seeds/filters/K/config/ef grids and update/delete
   streams. Measure initial build, update, flush/close, reopen/first query and all
   named curves in three paired trials. Reconciliation can change graph topology:
   use independent live-ID/filter/recall/F64 score oracles, report all result/stats
   differences and all failed recall cells rather than asserting identical ANN IDs.
7. Evaluate warmed resident query/maintenance regressions before adoption. Keep
   M5/M6 unchecked until their complete original strict gates pass; no Linux
   nonresident/memory-limit result is possible on the currently available runner.
