# Maintenance shared state must survive lock waits

The resumed M5/M6 mixed run hung in unmodified `a710aa5` on uniform-1536,
trial 0. Both the foreground query and the background maintenance callback
were waiting for the same status lock. This trial failed and has no completed
performance result. Its database and diagnostic captures were retained before
terminating the isolated worker.

## Cause and change

On Mojo 1.0.0 (`ed45d567`), passing `state[]` into
`_merge_sealed_runs(mut state: _MaintenanceState)` generated a whole-state
load before acquiring the writer lock, followed by a whole-state store after
releasing it. That store included the inline status lock, cancellation flag,
status counters and pending compaction flag. Concurrent foreground changes
could therefore be overwritten. The captured status lock contained an old
foreground stack address while both live callers waited to acquire it.

The new regression holds the writer lock until the callback is running,
allows it to reach the lock, then cancels and records a status update before
releasing the lock. The original implementation fails because cancellation is
lost. Changing only the helper's argument to `ref` also fails and emits the
same whole-state transfers; that unsuccessful probe is preserved.

Both maintenance helpers now receive the shared `Pointer` and dereference
individual fields within the existing lock scopes. The controller retains its
`ArcPointer` until the worker joins. The compiled callback reads cancellation
after acquiring the writer lock and no longer copies the entire state back.
No durable format, public API, scheduling policy or lock ordering changed.

## Verification

All Mojo commands used `--target-accelerator=metal:4 --target-cpu=apple-m4`
on the local Apple M4 Pro, with `-I src` and the existing native worker library.
Jobs and benchmark workers ran serially.

| Check | Result |
|---|---:|
| `tests/mojo/test_maintenance.mojo` | 6 passed; new regression failed before the fix |
| `test_background_publication.mojo` | 20 passed |
| `test_compaction_publish.mojo` | 11 passed |
| `test_backup_compaction.mojo` | 1 passed |
| `test_point_compaction.mojo` | 4 passed |
| `test_compaction.mojo` | 2 passed |
| Full `tests/python` against the freshly built isolated package | 351 passed, 1 skipped |
| Skipped Qdrant adapter case with the existing pinned dependency on `PYTHONPATH` | 1 passed |

The Python skip was solely the optional Qdrant dependency; the separately
executed case was
`test_public_adapter_exact_filters_mutations_and_reopen[Qdrant]`.
The suite commands use `pytest -o pythonpath=` so repository configuration
cannot select the stale `python/akashadb/_kernel.so`. The extension was built
from a copied source tree and copied binding entry point; its complete source
hash inventory and binary hash are in the artifact.

These are 44 targeted Mojo tests and all 352 Python cases across the two
commands. Existing crash/C ABI results were not rerun or relabelled as new.
This is macOS ARM64 validation, not a Linux or GPU device gate.

## Fresh resident mixed matrix

The original three workload checksums, archived 32-block query/write plans,
frozen ef values, K=10, recall target .95 and public binding boundary remain
unchanged. Three alternating engine-order trials per corpus produced 18
completed workers. All 36 quality cells passed, all nine Akasha Arrow leases
survived close, and all 18 engines matched the final exact oracle after reopen.
There were no worker timeouts. Query speed passed only **17/36** cells; the
overall result is **FAILED**.

Ratios below are medians of the three paired trials; acceptance still checks
each individual trial and never offsets a failure with another cell.

| Corpus | Filter | QPS A/Q | p95 A/Q | Passed |
|---|---|---:|---:|---:|
| uniform-128 | all | 1.368 | 0.579 | 2/3 |
| uniform-128 | correlated | 2.988 | 0.496 | 3/3 |
| uniform-128 | independent | 2.792 | 0.557 | 2/3 |
| uniform-128 | selective | 1.030 | 2.406 | 1/3 |
| uniform-1536 | all | 2.243 | 0.460 | 3/3 |
| uniform-1536 | correlated | 1.387 | 0.810 | 3/3 |
| uniform-1536 | independent | 1.285 | 0.861 | 3/3 |
| uniform-1536 | selective | 0.667 | 1.986 | 0/3 |
| real-1536 | all | 0.715 | 1.509 | 0/3 |
| real-1536 | correlated | 0.655 | 1.597 | 0/3 |
| real-1536 | independent | 0.438 | 2.362 | 0/3 |
| real-1536 | selective | 0.706 | 1.490 | 0/3 |

This new run is not a paired comparison to the October 2 result of 23/36;
host state and database rebuilds differ. The hang prevents a complete new
unmodified-baseline comparison. The correctness fix is not presented as a
speed optimization. Sustained nonresident queries, controlled memory limits
and concurrent clients remain outside this run.

[Raw reports, exact commands, source/binary identities, regression failures,
LLDB/native samples and assembly excerpts](2026-10-12-maintenance-shared-state.json.gz).
SHA-256: `ac5d8242c83a60ea4ccedae834c2022965b09985652dd07ad62676a8dfd61c67`.
Archived plan contents remain available in the immutable
[October 2 artifact](../benchmarks/results/2026-10-02-prepared-exact.json.gz);
the new artifact records their verified byte hashes.
