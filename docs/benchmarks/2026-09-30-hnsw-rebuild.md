# HNSW rebuild and bounded catch-up outside writer

Date: 2026-09-30. Source: worktree changes on `31f27e5`; the raw report records
source SHA256s. Host: macOS arm64, pinned Mojo 1.0.0 / MAX 26.5.0.

## Behavior and ownership

`rebuild_hnsw()` now captures a pinned read root under writer, builds a graph and
its source map outside writer, and conditionally publishes. The existing builder
still orders live rows by accepted sequence then ID; it borrows root-owned dense
values and retains the prior deterministic graph behavior.

The centralized accepted-write hook records the latest dense state for each ID
in a bounded journal. Replacements, deletions, reinserts and every ID in a batch
are covered, including when the old graph is unavailable. Descriptors share dense
owners; payload and sparse fields are not copied into this journal. Sparse-only
writes advance sequence coverage without repeating already-covered dense updates.

Each journal holds at most 1,024 IDs. Publication swaps it for a fresh empty
journal under writer, applies the detached journal outside writer, and checks
again. An empty journal, complete accepted-sequence coverage, identical collection
config and matching live count are required for the final swap. There are at most
four catch-up passes per capture and four captures per explicit operation. On
overflow or sustained writes the candidate is discarded and recaptured; exhausted
explicit calls report an error while keeping the current graph. A failed or stale
candidate never replaces a valid graph. The old graph and detached journals are
released outside writer. This bounds incremental work and retained journal state;
it is not a fixed wall-clock completion guarantee.

A separate rebuild job lock serializes builders without blocking writers. Explicit
rebuild and due maintenance before flush, compaction, synchronous maintenance and
backup use this path. A checkpoint can proceed while another builder is active.
The obsolete locked rebuild and unused `replace_owned_base` path were removed.
Recovery before opening a collection retains its existing deterministic builder.

## Why catch-up also moved outside writer

An exploratory 128D run found that applying a bounded 1,024-row tail under writer
still took roughly 125 ms. A row-count cap alone was therefore insufficient for
writer latency. The final design transfers the journal in constant time and
performs graph updates outside writer. A regression explicitly accepts a second
update to the same ID during catch-up and checks the final value and graph. When
catch-up was deliberately put back under writer, this regression failed its
`wrote_during_catchup == 1` assertion (`left: 0, right: 1`). It passes unlocked.
The flush-specific regression also failed before its locked builder was removed.

## Phase measurements

`benchmarks/mojo/hnsw_rebuild_bench.mojo` runs deterministic 128D F32/L2 vectors,
M=8, M0=16, efConstruction=64. Each cell has three rounds in each of three fresh
processes (nine observations; 54 total). Setup, initial writes, the root's first
publisher bootstrap, structure validation and a nearest-point exact oracle are
outside the timed phases. The worker is disabled. No other agent-started compile
or benchmark ran concurrently with these final measurements.

Medians:

| Points | Tail IDs | Capture µs | Build ms, unlocked | Detach µs | Catch-up ms, unlocked | Final publish call µs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 0 | <1 | 122.085 | 2 | <0.001 | 13 |
| 1,024 | 16 | 1 | 122.314 | 1 | 0.221 | 68 |
| 1,024 | 1,024 | 1 | 121.753 | 2 | 120.115 | 9 |
| 4,096 | 0 | 1 | 571.867 | 2 | <0.001 | 5 |
| 4,096 | 16 | 1 | 574.018 | 1 | 0.226 | 124 |
| 4,096 | 1,024 | 1 | 575.394 | 2 | 120.732 | 11 |

The harness uses the real `take_tail` and `catch_up` primitives separately before
calling final publication with an empty journal, so phases can be distinguished.
The final publish call includes old-graph destruction outside writer; these are
phase timings, not p99 lock holds or end-to-end ingestion/query throughput.
Zero clock deltas are below the timer's observed microsecond resolution.
The concurrency tests, rather than these sequential timings, establish that writes
proceed during graph build and detached catch-up.

[Raw process results and source hashes](results/2026-09-30-hnsw-rebuild.json).
Reproduce with:

```sh
pixi run mojo build -I src benchmarks/mojo/hnsw_rebuild_bench.mojo -o .build/hnsw-rebuild-bench
pixi run .build/hnsw-rebuild-bench
```

## Validation and remaining scope

The 18 new `test_hnsw_rebuild_publication.mojo` cases cover all five checkpoint
entry points, replace/delete/reinsert/flush/batch interleaving, sparse-only writes,
shared dense owners, unavailable graph recovery, stale config/job/coverage,
build/catch-up failures, journal overflow, both retry budgets, close, concurrent
updates during catch-up, WAL-tail reopen and a later checkpoint reopen.
78 targeted Mojo tests passed: publication (18), existing rebuild (10),
concurrency (6), compaction publication (11), background publication (20),
maintenance (5), storage operations (7), and backup during compaction (1).
Existing HNSW crash boundaries remain covered by
`test_hnsw_checkpoint_order.mojo` (five cases). `pixi run build` and
`pixi run test-c` passed. The freshly compiled Python extension passed all
66 tests (`pixi run env PYTHONPATH=python:. pytest tests/python -q`), retaining
the two existing FastAPI/httpx and extension-type deprecation warnings.
GPU execution did not change; its actual-device gate was not rerun for this slice.

Both locked quality gates passed: `check-hnsw-quality` (six cells, recall 1.0) and
`check-post-hnsw-quality` (11 metric/scalar cells × four filter modes, recall 1.0).
The latter retains the documented selective-filter exact-plan fallback; it is
not evidence that every cell ran ANN. These gates do not compare Qdrant or real
embedding datasets; #59 remains required.

This is the in-memory portion of #56. No durable-format contract changed in this
slice. The subsequent [sidecar publication slice](2026-09-30-hnsw-sidecar-publication.md)
adds the manifest v4 migration, pin retirement, captured HNSW backup and new crash
boundaries; see that report for its separate verification. Snapshot/index-cache file I/O and
initial delta promotion still run under writer. Cold read-publisher bootstrap is
outside this benchmark's scope. The overall single-node completion goal remains
open, including #57–#63 and named/native/binary/multivector support.
