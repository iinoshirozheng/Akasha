# Durable JSON catalog and Python/HTTP acceptance

Date: 2026-11-08. Compiler: Mojo 1.0.0 (ed45d567), macOS arm64.
Scope: [implementation plan](../plans/2026-11-07-json-index-catalog-api.md).

## Requirement audit

| Requirement | Implementation and direct evidence | Result |
| --- | --- | --- |
| Bounded catalog with stable learned types | `json_catalog.mojo`; codec tests reject every truncation, bad kind/type/reserved/version, duplicate names and trailing bytes | Pass |
| Manifest v6, existing formats preserved | `manifest.mojo`; 14 existing manifest tests, three v6 tests, independently packed frozen fixture; downgrade rejection and exact CRC/length validation | Pass |
| Atomic publication and retained catalog | PointStore checkpoint-before-publication; flush/compaction/reopen/drop tests; publication revision checks | Pass |
| HNSW migration and retained base | `test_json_catalog_hnsw.mojo`: v3→v6, identical graph bytes, pinned old file, newer data over retained base, reopen hits and HNSW rebuild | Pass |
| Create/list/drop/rebuild lifecycle | Collection and snapshot APIs; native catalog tests plus Python/HTTP tests; incompatible later data rejects indexed preparation/rebuild without changing learned type | Pass |
| Immutable snapshot ownership | Native prepared root and Python owned wrapper; mutations, drop, close, repeated execute and execute-after-close tests | Pass |
| Root-local bitmap reuse | Exact column/path/type registry on ReadGeneration; build-count tests and eight concurrent first preparations after injected failure | Pass |
| Public expression parser | Kernel-only evaluation; all comparisons, range, logical nodes, nullable IN, typed float/binary, invalid keys/types and depth/node boundaries exercised through real bindings | Pass |
| Controls and limits | Native expression/snapshot tests plus Python preparation/execution cancellation and timeout tests; failed execution permits reuse | Pass |
| Thin Python/HTTP boundary | Compiled binding, facade, create/list/drop/rebuild routes and JSON query route; actual kernel operations, invalid requests and close/reopen tested | Pass |
| Backup, restore and inspection | v6 physical backup captured before source mutation/drop restores original data/catalog; nine storage-operation regressions | Pass |
| Failure and recovery | Eight reconstructed create/drop publication states; actual temporary-file open failure; corrupt committed authority rejects valid temporary fallback; actual post-rename directory fsync failure requires reopen | Pass |
| Documentation and provenance | Format documents, API examples, this audit, plan checkpoints and ports entry D01c4o | Pass |

Catalog creation checks accepted sequence and catalog revision after training
outside the writer lock. A layout-only generation change does not invalidate
the data/type inference, so it need not reject creation. Publication checkpoints
the current accepted data under writer exclusion and advances manifest generation.
Rebuild is an operation on a captured root, not a write barrier or catalog mutation.

## Executed validation

- `pixi run build-python`: passed; also rebuilt by `pixi run test-python`.
- `pixi run test-python`: 3,764 passed, 1 skipped, four deprecation warnings.
  Optional pinned `qdrant_edge` benchmark dependency was absent. This suite ran
  before the final parser cases and fsync probe were added; production code has
  not changed since this run.
- `PYTHONPATH=python:. pixi run pytest -q tests/python/test_json_catalog.py
  tests/python/test_json_catalog_fsync.py`: final 34 passed, four warnings.
- `pixi run mojo run -I src tests/mojo/test_manifest_json_catalog.mojo`: final
  three passed, including the independently encoded frozen fixture.
- `test_json_catalog_collection.mojo`: three passed, including parallel builder.
- `test_json_catalog_hnsw.mojo`: one passed.
- `test_json_expression_snapshot.mojo`: nine passed after artifact reuse changes.
- Six storage suites: 32 passed (manifest 14, catalog manifest 2 before fixture
  addition, catalog codec 1, catalog store 1, storage operations 9, point compaction
  5). Return codes and output: `.build/json-catalog-validation/results.json` and
  adjacent logs. The later three-test manifest run supersedes its two-test result.
- `git diff --check`: passed.

Counts overlap; they are not summed into a new full-suite count. The initial
binding compile failed on `Span[Int]` conversion and was repaired with owned
PythonObject elements. The HNSW test initially failed to compile because a
non-Copyable descriptor list was iterated by value; indexed clone access fixed it.
Both corrected artifacts were compiled and tested successfully.

## Explicit behavior and limits

Python cancellation is sampled at call entry, matching existing controlled APIs;
native deadlines/checkpoints enforce execution limits. Bitmap payloads are
derived in-memory artifacts and rebuild lazily after reopen; the durable catalog
stores definitions and fixed learned types. A root registry holds at most 256
distinct column/path/type keys. Failed rebuilds retain a ready artifact.

The fsync probe uses the existing interposer in a child process on this Mac;
it proves actual failure propagation, not hardware power-loss durability. No
Linux/GPU/performance claim is made. The full native suite was not rerun; native
validation targets modified persistence, ownership and query paths. Four warnings
are missing `__module__` on three extension types and Starlette's httpx deprecation.

Arrow-specific prepared-query output, additional index kinds, disk bitmap/spill
storage, the larger product checklist and paused performance gates remain outside
this Python/HTTP catalog objective.
