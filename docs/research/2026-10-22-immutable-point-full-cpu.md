# Complete retained-candidate Mojo CPU coverage

The retained deferred-ID candidate now has passing evidence for all **166
repository Mojo CPU test modules / 1,095 tests**, with **zero failures and zero
skips** in the final applicable results. This combines **138 freshly executed
modules / 885 tests** with **28 unchanged modules / 210 tests** whose archived
sources and successful results are verified. It is not a claim that all 1,095
tests were rerun in this session.

The earlier 262-case validation covered a relevant subset and additional
candidate fixtures. It did not cover the complete repository suite. This audit
finds three more private caller adaptations and two missing mappings to already
validated owner-aware fixtures. All original repository test function names are
preserved; the auditor checks their count against executed results for every
module. The candidate's **132 engine files remain unchanged**.

## Corrections exposed by complete coverage

| Consumer | Correction and preserved check |
| --- | --- |
| `test_compaction_capture` | Supply `_CheckpointRetention` to the private checkpoint helper, then release it after leaving the writer lock. Preserve the capture/write race, publication and restart assertions. |
| `test_hnsw_delta_scan` | Pass the authoritative entry's numeric reader to the existing F32 score helper. Preserve all metrics/scalars, filtered/unfiltered results, ranking and traversal statistics. |
| `test_hnsw_rerank_batch` | Use the same numeric reader boundary. Preserve exact score-bit checks, pair/tail dimensions, stale graph values, ordinal lookup counts and error assertions. |
| `test_compaction_reclaim_boundary` | Reuse the existing `test_compaction_reclaim_owner_boundary` fixture byte-for-byte under the repository module name. A disk-only publication retains live mapped source files until close; deletion and restart checks remain. |
| `test_point_compaction` | Reuse the existing five-case `test_point_compaction_leases` fixture byte-for-byte. After store close, a held row protects only its own file; dropping that row releases the remaining file. |

The two renamed fixtures had already passed in the retained candidate's earlier
matrix. Their **six replayed cases are not new unique coverage**. Ten other
existing caller adaptations are carried forward from the retained source
archive. In total, 151 repository test modules are byte-identical to their
originals and 15 use these documented candidate adaptations. The complete
`candidate-tests.patch`, original files and compiled test sources are archived.

These changes belong to the isolated candidate adoption package. Current
repository tests remain compatible with the current production engine; no
fallback or compatibility overload is added to either engine.

## Execution and failure history

The runner imports groups of at most twelve modules to share compilation, then
starts a **fresh process for each individual module**. An executable symlink
selects the module using `argv()[0]`; it adds no test-runner arguments. This
also preserves the file-retirement test's self-executing child-reader protocol.
All compilation explicitly includes retained source. The CPU suite's existing
GPU planner/fallback tests are included; this is not an actual-device GPU gate.

The first runner passed an ordinal argument and the Mojo test framework
rejected it before running Arrow tests. Its original source and failure remain
recorded. After correcting the entrypoint, complete coverage exposed two
compile failures (checkpoint retention and delta-scan numeric reader), followed
by two obsolete immediate-deletion expectations. Those expectations are
replaced with the already validated owner-aware fixtures described above.
All five failed actions, subsequent corrections and final successful outcomes
remain in `execution.json` and their source snapshots. Successful unchanged
groups are reused; a changed group is rebuilt and its affected module processes
rerun.

Coverage includes current and legacy durable formats, corruption, bounded-memory
paths, independent file leases, concurrency, named vectors, sparse search, rank
fusion, query control, exact scoring, HNSW and all existing repository WAL CPU
tests. The separate eight-module crash matrix, C ABI, Python and integration
results remain applicable to the unchanged engine; they are not counted as
part of these 1,095 CPU tests.

## Reproduction and audit

The working evidence root is
`.build/qdrant-alignment/immutable-point-full-cpu`. `prepare.py` inventories all
repository modules, verifies the prior source archive and carries over existing
adaptations. After applying the recorded additional adaptations, execution is:

```sh
rtk proxy pixi run python .build/qdrant-alignment/immutable-point-full-cpu/validate.py
rtk proxy pixi run python .build/qdrant-alignment/immutable-point-full-cpu/freeze_evidence.py
```

Use a fresh root for a fresh run. Resume verifies commands, input hashes, log
hashes and completed build identities before reusing results. The project
compiler is Mojo **1.0.0 (`ed45d567`)**. Source provenance remains the
[deferred-ID archive](2026-10-20-immutable-point-deferred-id.md), SHA-256
`f2b129cf133ec06161b24121751112fcc0a0437ae68c23ef9c0a28f20eeff713`.

The [full CPU evidence archive](2026-10-22-immutable-point-full-cpu.json.gz)
contains **2,693 text artifacts, 3,291,203 compressed bytes**, SHA-256
`4ba8a87f063da1ef47df66d787626be1307f80d13660aed8d98bea41ae5aa86d`.
Archive-only extraction and `verify_evidence.py` reproduce the complete audit
exactly and verify every artifact hash. Repeated snapshots and executions are
evidence artifacts, not additional tests.

This closes the retained candidate's complete local Mojo CPU coverage gap.
The [examples/integration audit](2026-10-22-immutable-point-example-integration.md)
and [Python child-compiler audit](2026-10-22-immutable-point-child-compiler.md)
close their separate local gaps. Production `src` remains unchanged from
`a6822c3`; no candidate engine is adopted. The latest strict mixed result stays
**21/36**, including twelve speed failures and three Qdrant quality failures.
Sustained nonresident capacity, native Linux and the remaining performance
gates still prevent M5/M6 completion.
