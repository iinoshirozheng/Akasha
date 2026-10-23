# Preserve named graph partitions across unchanged reopen

Continue M5/M6 from `d52a287`; production kernel is `780e8aaf…`, core remains
`cc15f37`. This is an isolated implementation plan, not an adopted change or
completed milestone. Earlier reconciliation, point-refresh, overlay and batch
repair experiments remain unadopted; do not rerun those algorithms.

## Evidence and choice

`ReadGenerationCache.publish_field_caches_best_effort` currently returns for multiple
layers or a nonempty head. `PersistentCollection.open_with_fields` reconstructs
the current authoritative point table, and the first captured read view builds
one complete base run. Saving separate old run files alone therefore cannot
match that new base's content key. A mere removal of the publication guard is
incorrect. The current regression explicitly expects multi-run saving to skip.

Named search already merges candidates from independently built immutable run
graphs, then reranks once against current authority. Preserve these graph
partitions and their current membership in a single bounded optional cache.
Loading an exactly matching collection state rebinds the partition members to
current ordinals; it does not insert, delete, repair or rebuild graph nodes.
This trades more explicit artifact metadata for avoiding the prior candidates'
topology changes and graph mutation costs. It does not persist historical
payload/authority or reconstruct the entire read publisher from an index cache.

Local Qdrant reference is at `/Users/ray/Projects/Akasha/reference/qdrant`, commit
`74f3e85b9473c62560006c043e13737ce6b48412` (the worktree has no `reference/` folder).
Its segment constructor's `vector_index.rs` opens an index with that segment's
ID tracker/vector storage/payload index; `hnsw.rs:65` loads configuration and
`GraphLayers::load` rather than rebuilding on every unchanged open. This supports
preserving graph/partition identity, not copying Qdrant's storage architecture.

## Implementation boundary

Represent a named artifact as owned graph partitions with a validated mapping
from current field IDs to partition/slot and run-local authority ordinal. A
fresh build has one partition. Restored partitions retain their original graph
bytes/order, including navigation-only shadowed nodes. Membership excludes those
nodes; each current field ID must appear exactly once. Every admitted node's
prepared vector must match current native authority, and every graph retains
the existing complete structural, finite/vector and codec checks. Extra hidden
navigation nodes are never a source of current values or results.

Search performs the existing per-partition admission/traversal, global bounded
merge and native F64 rerank. Preserve all candidate/ef budgets, filters and score
operations. Check coverage once at artifact construction/load and route filtered
IDs through the validated partition/slot map; do not rescan all matching rows
once per partition. Existing read-layer shadowing must still exclude later
updates after a bundle is loaded. Base/delta statistics describe current read
layers; compare their sum across reopen where the physical layer layout changes,
and explicitly report any partition-related counter difference.

Use the existing AKIC bounded atomic envelope with an explicit new cache kind
and versioned partition payload. Keep one committed and one temporary file per
field. Bind schema/configuration and sorted *current* ID/vector content exactly;
changed content is a cache miss, not reconciliation. A stale old optional kind
may be invalidated explicitly in the format specification; authority formats
and backup requirements stay unchanged. Validate counts, lengths, duplicate or
missing membership, slot IDs, vector identity and trailing bytes before publishing.

Saving captures only already-ready graphs from the current publisher layers
and its matching frozen head; it performs no graph build or merge. Resolve
visibility newest-first, including tombstones and removed fields. Flush can
invalidate `publisher.root` without dropping layers/frozen head, so use the
writer's current authority and sequence to validate capture, not a stale root.
Artifact/query locks retain single-attempt acquisition; busy/incomplete graphs
skip publication and later flush/close retry. Queries and held snapshots never
publish. No new configuration, dependency, GIL change or authority migration.

## Verification sequence

1. Reproduce the missing updated multi-run save/reopen hit on the current core.
2. Implement the smallest complete bundle codec, load, save and query path in a
   copied source tree. Compile the copied binding entry with Mojo 1.0.0/M4/Metal.
3. Test one/multiple/empty partitions, shadowed/replaced/deleted IDs, field removal,
   metadata/ordinal changes, all native field types and existing graph codecs;
   reject corrupt/torn/oversized/CRC-correct invalid coverage or vectors.
4. Cover subsequent writes after load, repeated flush/reopen, busy readers/builders,
   retry, cancellation, old snapshots, compaction and backup. Keep native/F64
   oracles; verify pre-close versus loaded partition results at unchanged state.
5. Run affected Mojo/crash, isolated full Python, C ABI and examples. No benchmark
   may overlap tests/builds/compression. Guard source/binary/runtime identities.
6. Measure all original named lifecycle corpora/trials/ef/filter curves, including
   build, updates, publication, reopen/first query, warm samples and cache bytes.
   The prior baseline rebuilds a different topology on reopen: compare both to
   independent recall/score oracles, not an invented across-version ID requirement.
   Preserve low recall, slower trials and failed starts. Then assess affected
   original fixed Qdrant gates without changing service/workload boundaries.

No acceptance claim follows from a successful cache hit. The original per-cell
Recall@10 ≥ .95 / QPS ≥ Qdrant / p95 ≤ Qdrant gates remain unchanged. Linux
nonresident/memory-limit is still unavailable; no runner is to be requested again.

## Baseline reproduction and next implementation

Isolated snapshots and identities are in `.build/2026-10-04-named-graph-bundle`.
`test_field_hnsw_bundle.mojo` seeds a cached base, adds one point, queries the
resulting multi-run view, flushes/closes, reopens and requires a cache hit with
the existing exact/F64 oracle. The current core compiles and fails exactly at
`cache_hit == True` (`False` observed), exit 1. TestSuite reports **72.347 ms**;
this is a correctness reproducer, not a benchmark. Full command/log are in
`before-targeted.json` / `before-targeted.log`. Production remains unchanged.

The initial implementation can keep `FieldHnswIndex` as the per-run artifact
owner, with owned graph partitions, canonical current row ordinals, a validated
ID→(partition, slot) map, existing cache flags and existing artifact query lock.
Each partition owns its `HnswIndex` and current-member mask/count. A fresh build
has one all-current partition; loaded partitions may contain navigation-only
slots. Keep filtering linear in current matches/total flag storage by routing
each ID through the shared map, not by probing every partition independently.

Publication can gather current publisher `_layers` plus an already-existing
matching `_frozen_head`. Determine membership newest-first over all row IDs,
including tombstones, without copying historical native authority into the
cache. Pass current authority, ready artifact owners and per-source member IDs
to the cache writer; verify complete coverage before atomic replacement.
If a head has no matching frozen ready graph, skip this optional publication.
Flatten already-restored partitions into the new bundle on a later close; never
nest bundles or grow one file per old generation. Omit zero-current-member
partitions because they perform no search. Empty current fields need an explicit
valid empty bundle case rather than relying on an empty HNSW codec allocation.

Payload framing can reuse existing HNSW snapshot bytes per partition plus a
bounded list of admitted `(slot, point ID)` memberships; no ordinals persist.
On load, bind those IDs to current sorted rows, require each live field ID once,
validate the slot ID/current bit and exact prepared vector, then build the map.
Missing/stale/invalid optional cache still uses the existing authoritative build
contract; this is not a legacy API compatibility layer. Reject old optional kind
explicitly if the new format cannot represent it, and update format/tests together.

## Isolated implementation and correctness checkpoint

The candidate now owns graph partitions with current membership masks and an
ID-to-partition/slot map, saves a kind-5/version-1 bundle from ready current runs,
and restores graph bytes unchanged. It omits empty partitions, retains navigation
nodes without admitting their stale values, preserves per-partition budgets and
native F64 rerank, and retries incomplete/busy/failed publication without waiting
on graph locks. A shared 512 MiB conservative decode budget covers the complete
bundle; a multi-graph over-budget regression verifies the previous cache survives
and graph locks are released. No production source or artifact has been replaced.

Current candidate validation: **112 targeted Mojo, 11 related crash, 506 complete
Python, C ABI client and three rebuilt examples passed**. This includes 55 original
single-graph native/codec combinations plus 55 multi-part combinations, repeated
update/reopen with exact graph bytes and score bits, filtered shadowing, missing
fields/deletes, empty sets, cancellation/limits, corrupt membership/current vectors,
failed saves, busy graph/build locks, retained snapshots, backup and compaction.
The complete Mojo/crash suites have not been rerun. Initial integration and test
compilation failures remain in the isolated evidence directory with source copies.

The complete three-corpus/three-trial named lifecycle diagnostic finished all
18 workers. It retained the original inputs, filters, K, ef grid and raw samples:
28,944 ANN audits and 4,824 exact checks passed. Fixed-ef quality moved from
132 to 141 of 216 cells, with 12 improvements and three new failures. All 36
common-recall warm comparisons regressed in QPS or p95, despite much faster
reopen queries. **NOT ADOPTED.** Production sources, binary and format stay
unchanged; M5/M6 remain incomplete. The report and frozen evidence are linked
from `docs/benchmarks/2026-10-04-named-graph-bundle.md`.

Before another algorithm change, isolate the query-wrapper cost from retained
partition topology using the same graph bytes. The current diagnostic counts
show extra distance work, but timing alone cannot assign all cost to one cause.
Do not rerun this complete lifecycle experiment or prior repair algorithms.
