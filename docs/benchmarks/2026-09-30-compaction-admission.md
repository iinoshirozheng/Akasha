# Full compaction admission and the flush-race regression

Date: 2026-09-30. Source: this change on top of `1b9f22f`.
Environment: Apple M4 Pro, macOS arm64, project-pinned Mojo 1.0.0/MAX 26.5.0.

## Cause and fix

The foreground and worker independently captured the entire committed segment
set. A winning compaction replaced the loser's inputs, causing retries even
though flush publication itself correctly rebased appended segments. Under load,
four losses exhausted the foreground retry budget. A new regression starts a
worker, observes its captured job, accepts another write and calls public
`compact()`. Before the fix, its assertion of zero publication conflicts failed
with `left: 1, right: 0`; after the fix it passes with both writes and reopen
verified. The existing worker delay hook controls the interleaving.

All full-compaction entry points now share one job lock, separate from the writer
lock. The only lock order is job then writer. A caller waiting for a builder holds
no writer lock; writes and checkpoint append continue during the merge. Since all
current jobs select the entire input set, serial admission is sufficient. The
local RocksDB `DBImpl::CompactRangeInternal` / `RunManualCompaction` paths and their
`exclusive_manual_compaction` option were inspected as a reference for excluding
competing maintenance; Akasha does not need per-file compaction scheduling yet.

Synchronous `maintenance()` and no-worker flush/backup maintenance now call the
same captured-input, unlocked builder. The obsolete locked memtable compaction
and its private retirement helper were deleted. A no-worker backup captures and
pins under the writer lock before running synchronous compaction. It releases the
pin on an error, and successful copying still uses the exact captured file set.

Conditional publication, durable ordering, bounded defensive retries and stale
output discard remain unchanged. Tests that intentionally bypass job admission
still validate the losing-job and exhausted-worker-budget paths. One test helper
also now holds the writer lock across snapshot/manifest comparison; a worker may
otherwise legitimately publish between those reads.

## Verification

62 targeted Mojo tests passed:

- `test_compaction_publish.mojo`: 11
- `test_background_publication.mojo`: 20
- `test_maintenance.mojo`: 5
- `test_compaction.mojo`: 2
- `test_storage_operations.mojo`: 7
- `test_backup_compaction.mojo`: 1 (captured files survive synchronous compaction,
  release and source deletion; the backup independently reopens)
- `test_hnsw_rebuild.mojo`: 10
- `test_concurrency.mojo`: 6

Nine crash tests passed: `test_checkpoint_order.mojo` (7) and
`test_backup_publication.mojo` (2), covering output fsync, manifest temp/rename,
root swap, cleanup, rebase, torn backup and retry.

`pixi run build`, `pixi run test-c`, and the freshly built Python extension's
66 tests (`pixi run env PYTHONPATH=python:. pytest tests/python -q`) also passed.
Python reports the same two existing FastAPI/httpx and extension-type deprecation
warnings. GPU execution is unchanged and its actual-device suite was not rerun.

The original `test_racing_flushes_rebase_without_conflicts` also ran 12 times
without extra CPU load and 12 times with six independent busy-loop processes.
All 24 cases passed their zero-failure/zero-conflict/zero-exhaustion and reopened
data assertions. Each case races eight public compactions against 200 upsert/flush
pairs. [Raw process results](results/2026-09-30-compaction-admission.json).
This is a stability regression check, not a latency benchmark or proof of every
possible interleaving.

Reproduce individual gates with
`pixi run mojo run -I src tests/mojo/<file>.mojo` and
`pixi run mojo run -I src tests/crash/<file>.mojo`.
For repeated stress, a Mojo harness imports
`test_racing_flushes_rebase_without_conflicts` from `tests/mojo` and invokes it
12 times; compile with `-I src -I tests/mojo`. CPU-load children are terminated
and joined after the harness exits.

## Remaining scope

This does not complete #56. HNSW rebuild and checkpoint/index-cache I/O can still
hold the writer lock. HNSW sidecar retirement and bounded mutation catch-up remain
separate work. The previously documented orphan-output crash leak is unchanged;
job admission prevents normal competing builders but is not a replacement for
durable recovery and reclamation.

Follow-up on the same date: the in-memory HNSW builder and bounded mutation
catch-up now run outside writer. See
[HNSW rebuild measurements](2026-09-30-hnsw-rebuild.md). Sidecar publication,
retirement and file I/O remain separate work.
