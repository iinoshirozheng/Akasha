# Durable JSON index catalog and Python/HTTP APIs

Status (2026-11-08): implemented and accepted against the six work stages below.
See the [final requirement audit](../research/2026-11-08-json-catalog-api-validation.md).
Checkpoint notes below are historical; the final audit supersedes outstanding items.

Goal: persist JSON index definitions and learned types under the existing
collection authority, and expose real native query/index operations through thin
Python and HTTP boundaries. Preserve the completed snapshot executor.

## Design decision

`collection.bin` v2 is the immutable vector field identity; its canonical checksum
is embedded in point/WAL envelopes. Mutable scalar index definitions must not
silently change that identity. Extend the generation manifest with an embedded,
versioned catalog section instead. No independently published mutable sidecar
may become a competing authority. Existing v1-v5 manifests read as empty catalog;
new catalog publication uses v6. Old formats remain unchanged and tested.

A definition records name, payload column, exact JSONPath, bitmap kind, learned
scalar type and revision. Creation validates/builds against a captured collection
view, then checks sequence/generation under the writer lock before atomic
publication. Catalog mutation changes manifest generation and read-root identity.
All subsequent flush, HNSW publication and compaction preserve the catalog.
Drop removes only the definition from the new generation; already acquired
snapshots/prepared queries retain their previous view. Learned type remains fixed
for updates/rebuild; incompatible data must have an explicit, tested write/query
contract, never be silently omitted from results.

Derived bitmap data may be rebuilt from authoritative point data, but must retain
learned type, source identity and snapshot sequence. Establish root-local reuse
and update/rebuild behavior before claiming persistent index lifecycle complete.
Backup capture includes the exact catalog in the captured manifest; restore,
inspection, orphan handling and legacy migration recognize v6. Test partial
publication, corrupt lengths/types/checksum, interrupted writes and reopen.

## Work sequence

1. Bound native definition/catalog types and binary section codec; document bytes
   and prove roundtrip, malformed input and limits before publication changes.
2. Manifest v6 migration and catalog retention across every constructor/publication
   path, HNSW base checks, backup/restore and recovery. Add format fixtures.
3. Native collection create/list/drop/rebuild and catalog-aware snapshot query
   preparation, immutable catalog capture and lifecycle tests.
4. Structured native JSON expression binding from public specs; Python facade and
   compiled binding methods with owned prepared-query lifetime and cancellation.
5. HTTP endpoints using existing service collection lifecycle/error handling;
   API tests use actual kernel operations, including restart and invalid inputs.
6. Relevant native, Python, HTTP, persistence/crash, backup and compatibility gates.

This plan records the full end state, not only a codec helper. Do not mark the
goal complete until durable lifecycle and both public boundaries are verified.

## Storage integration checkpoint (2026-11-08)

Catalog section codec, manifest v6 encoding/decoding, exact-length/CRC validation
and legacy downgrade rejection are implemented. New v6 tests (2) and existing
manifest suite (14) pass. PointStore now publishes a checked next catalog revision
under caller-owned writer exclusion, checkpoints accepted data first, preserves
catalogs across flush/HNSW replacement, and fails closed on uncertain I/O.
Committed compaction preserves the latest manifest catalog; HNSW recovery and
inspection accept v6's v5-compatible overlay behavior. Segment format detection
continues to inspect actual segment headers and is unchanged.

A real PointStore lifecycle test passes: publish -> write/flush -> stale revision
rejection -> compact -> reopen -> drop -> flush -> reopen, with an empty catalog
retaining revision and v6. Collection lock/capture integration, captured backup,
crash injection and public APIs remain open. No end-to-end completion claimed.

## Collection integration in progress

Native create/list/drop and snapshot catalog capture are connected. Creation
trains on an owned root outside the writer lock, checks accepted sequence and
catalog revision under writer exclusion, then checkpoints/publishes. Snapshot
metadata is an owned catalog copy captured alongside its root; old snapshots
retain dropped definitions. Catalog-selected preparation fixes the stored learned
type rather than re-inferring it from new documents.

Write contract: catalog indexes are derived, not schema constraints. Authoritative
writes remain accepted; incompatible later data makes catalog-index preparation
fail explicitly, with no partial result or silent row omission. Drop/recreate is
the explicit route to a new learned type. Rebuild must retain the existing type.
Two collection lifecycle tests pass: create/capture/query/write/flush/compact/
reopen/drop and learned-type incompatibility/recreation. Backup/failure/public
boundary checks and root-local artifact reuse remain outstanding.

## Public one-shot API checkpoint (2026-11-08)

The compiled binding, Python facade and HTTP routes now expose create/list/drop
and native expression queries using catalog-selected indexes. Fixed the binding
result conversion to use owned PythonObject elements, matching existing list
ownership patterns. `pixi run build-python` succeeds with Mojo 1.0.0.
`PYTHONPATH=python:. pixi run pytest -q tests/python/test_json_catalog.py
tests/python/test_server.py tests/python/test_jsonb_projection.py
tests/python/test_jsonb_condition.py` passes all 49 cases (three existing
deprecation warnings). New cases cover signed IDs, residual/indexed results,
Python and HTTP close/reopen, durable drop, duplicate creation, invalid specs,
strict HTTP timeout types and unknown catalog names after drop.

This verifies the one-shot boundary only. Owned Python prepared queries,
cancellation, native rebuild/root-local reuse, backup/fault injection and the
remaining persistence compatibility gates are still open.

## Owned Python query and backup checkpoint (2026-11-08)

`Collection.prepare_json` now returns an owned native prepared query exposed as
`PreparedJsonQuery`, with repeatable execute, idempotent close and context-manager
support. One-shot queries use the same binding construction/execution path.
Cancellation follows the existing Python boundary contract: the token is sampled
at call entry; each execution also accepts its own timeout. Both preparation and
execution enforce native controls. The compiled extension builds successfully.

All eight catalog Python tests pass, including snapshot survival after mutation,
catalog drop and collection close, execute-after-close rejection, cancelled
preparation/execution, timeout and successful reuse after a rejected call.
Backup/inspect/restore of a real v6 collection preserves the captured catalog and
data despite subsequent source mutation/drop. The extension emits an additional
`PreparedJsonQuery` missing-`__module__` deprecation warning, matching existing
Scanner/Collection binding warnings. Root-local reuse/rebuild and fault/recovery
compatibility gates remain open.

## Publication recovery checkpoint (2026-11-08)

The catalog Python suite now passes 11 cases. It reconstructs eight create/drop
publication states: empty, torn and complete temporary manifests with the old
committed authority, plus the new committed manifest. Each recovers the expected
catalog, accepts another point mutation, flushes and reopens. A directory at the
temporary filename forces an actual publication write failure; the committed
manifest remains unchanged and subsequent writes require reopen. Recovery then
preserves accepted data and permits a successful create. A corrupt committed
manifest is rejected even with a valid temporary manifest; no fallback replaces
the corrupt authority. These are disk-state boundary and I/O failure tests, not
power-loss or directory-fsync fault injection. The format specifications now
describe the implemented v6 publication and retention behavior.

## Root-local artifacts and rebuild checkpoint (2026-11-08)

ReadGeneration now owns a bounded JSON artifact registry using existing
ArtifactState locks and ownership. Keys are exact column/path/learned type;
different roots never share row ordinals or artifacts. Preparation reuses ready
bitmaps. Explicit native snapshot/collection, Python and HTTP rebuild operations
retain the stored type and replace only after success; failure retains a ready
artifact. Rebuild captures a root and changes no durable catalog or manifest.

Two native catalog lifecycle tests prove build-count reuse, explicit rebuild,
failed rebuild retention, new-root rebuild and fixed-type rejection. Nine native
expression/snapshot regressions pass. The extension builds; 129 Python tests pass
across catalog, server, projection, condition and Arrow scanner suites (four
warnings). Public tests cover rebuild routes, unchanged manifest bytes, type
mismatch and old prepared-view preservation.

Remaining acceptance includes HNSW v3-to-v6 and retained-base compatibility,
publication durability fault coverage, broader native storage regressions and
the final requirements/documentation audit. Concurrent first-builder behavior
uses the existing artifact lock pattern but still needs a dedicated JSON test.

## HNSW compatibility and concurrent artifact checkpoint (2026-11-08)

The new native HNSW catalog test passes: seed a v3 manifest using the established
sidecar migration test pattern, verify checkpoint hit, create catalog to migrate
to v6 with identical HNSW bytes, retain the old filename behind a snapshot pin,
flush a newer point using the retained base, reopen with checkpoint hit, execute
catalog query, rebuild HNSW and reopen again with catalog retained.

The native catalog collection suite now has three passing tests. Its new test
injects first-build failure, then launches eight parallel preparations with a
build delay. All query results match and the shared state records exactly one
successful build and one failed build. This verifies retry and concurrent
first-builder publication rather than relying only on the shared lock pattern.

Full Python and targeted native storage regression runs are in progress; no
completion claim is made until their terminal results are inspected.

## Broad regression and directory-fsync checkpoint (2026-11-08)

`pixi run test-python` completed: 3,764 passed, 1 skipped, four warnings in
132.91 seconds. A new test added after collection was separately run and passed:
`tests/python/test_json_catalog_fsync.py` compiles the existing directory-fsync
interposer and scopes it to a child Python process. The marker is consumed by an
actual directory fsync failure during catalog publication; create reports error,
subsequent writes require reopen, and reopening observes the renamed committed
catalog with accepted data intact. This does not simulate power-loss hardware.

Six native storage suites completed with 32 passing tests: manifest (14), v6
catalog manifest (2), catalog codec (1), catalog PointStore (1), storage operations
(9), and point compaction (5). Logs and return codes are under
`.build/json-catalog-validation/`. HNSW and concurrent catalog tests above add
separate evidence; these counts do not imply a full native suite run. Final
requirements, parser boundary coverage and documentation/provenance audit remain.
