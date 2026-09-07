# Post-HNSW stabilization and performance

User-authorized scope: merge 31, then complete 32–38 as independent commits.
Preserve durable formats, exact semantics, deterministic ID ties, and the ADR 0005
boundary between distance specialization and execution policy. ECS is out of scope.
Use Mojo 1.0.0 and MAX 26.5.0, the latest stable packages verified on 2026-09-07.

## Delivery sequence and acceptance

| Package | End-to-end change | Evidence required | State |
| --- | --- | --- | --- |
| 31 | mmap ABI guard and complete independent OS CI | Native macOS and Linux CPU, crash, C ABI, build, examples, quality | Merged `71f86cf` into main; Actions 34086702699 passed |
| 32 | MemTable ID lookup, live count, borrowed scans, efficient owned sorting | Scrambled IDs, stale writes, delete/reinsert, clone and recovery ordinal changes; before/after ingest and scan measurement | Complete; 67 targeted Mojo tests, 49 Python tests, 3 actual-device GPU tests passed |
| 33 | Reproducible larger workload harness and quality observability | Fixed seeds, high dimensions, updates/deletes, filters, base/delta; candidate recall, final recall, fallback rate and end-to-end latency reported separately | Complete; 11 smoke cells, 22 representative cells and 18 supplemental cells; 10,240 large/supplemental query observations, scaling through 65,536 points, high-dimensional F32 controls and ef tradeoff recorded |
| 34 | Reusable GPU execution resources tied to immutable F32 snapshots, ragged batches | Actual device differential tests; old/new snapshot freshness; preparation, allocation and transfer evidence | Complete; 7 actual-device tests and CPU regressions passed; six paired 31-sample workloads recorded |
| 35 | Tiled distance and parallel partial Top-K with deterministic merge | All metrics, ties, odd dimensions, varied K, ragged/empty sets; actual device end-to-end comparison and bounded scratch | Complete; eight actual-device tests and four planner tests passed; six paired workloads recorded |
| 36 | Measured compact SIMD and HNSW allocation improvements | Codegen inspection and benchmark evidence; deterministic recall gates preserved | Complete; packed owned/mapped loads, accumulator experiment, exhaustive decode tests and quality gates; profiling did not justify scratch refactoring |
| 37 | Cold/warm open and validation scratch accounting/optimization | Same CRC algorithm and corruption checks; stage timings and peak memory recorded | Complete; CRC table, sorted reciprocal audit, mincore-confirmed cold/warm benchmark, recovery and peak RSS evidence |
| 38 | Execution policy calibrated from measured crossover | CPU/HNSW/GPU selection reasons; cold/resident, latency/throughput separated; no slower GPU default | Complete; 15 paired actual-device cells, GPU opt-in policy and K-boundary reduction regression; final CPU/HNSW comparisons recorded with 33 |

## Validation policy

Start with narrow tests per package and commit each working slice. Run the full
CPU/Python, crash, C ABI, build, examples and locked HNSW quality gates after the
integrated changes. GPU changes require `pixi run test-gpu` on the available Apple
M4 Pro; CPU fallback never counts as device coverage. Native Linux CI covers
portability. Timing assertions are diagnostic, while semantic and quality gates
are deterministic. Preserve successful evidence when the relevant code is unchanged.

## Baselines and execution notes

- 31 was fast-forward merged and pushed before starting 32; implementation branch is
  `codex/post-hnsw-performance`.
- Existing actual-device GPU tests pass before changes: one flat scan test and
  two snapshot/failure tests, all executing against MAX on Apple M4 Pro.
- Raw local measurements and compiler output are kept under `.build/post-hnsw/`;
  summarize reproducible commands and results in versioned benchmark documents.

- 32: MemTable lookup/count and borrowed exact/filtered/parallel/GPU preparation
  passed 67 distinct targeted Mojo tests, 49 Python binding/service tests and all
  three actual-device GPU tests. Added recovery/clone/slot/count and export ownership
  regressions. See `docs/benchmarks/post-hnsw-performance.md` for before/after data.

## Integrated acceptance: 2026-09-07

Core commit `9b98dbc5878578dd158011be6366e6cdbd34dcdc` passed
[Actions 34099524657](https://github.com/iinoshirozheng/Akasha/actions/runs/34099524657)
on both native targets independently:

| Gate | macOS ARM64 | Linux x86-64 |
| --- | --- | --- |
| Native mmap ABI / compiler probes | Passed | Passed; Darwin-only probe skipped |
| Mojo CPU tests | 638 passed in 83 files | 638 passed in 83 files |
| Python tests | 49 passed | 48 passed; one Darwin-only test skipped |
| Crash recovery | 9 passed | 9 passed |
| C ABI, build, smoke, persistent and HNSW examples | Passed | Passed |
| Existing locked HNSW quality and new 11-cell quality gate | Passed | Passed |

The same core passed all nine actual-device GPU tests on Apple M4 Pro, including
snapshot freshness/concurrency, ragged candidates, tile boundaries and exact
near-tie ordering. The final GPU binary completed 15 shapes × 31 paired samples
with ID/score differential verification; all 465 samples are retained. NVIDIA
and AMD device execution was unavailable and is not counted as passing.

The 22-cell representative matrix and 18 supplemental cells completed all 10,240
query observations, with explicit candidate/final recall and fallback rates.
Timings from paused or superseded representative binaries are excluded from the
durable quality report. Supplemental scaling reaches 65,536 points; the full
cross-product and million-point builds were not run. High-dimensional recall
limitations and the two local resident-GPU crossover wins are reported without
changing the existing quality thresholds or enabling GPU by default.

Package commits after 31: `143f659` (32), `94ff55f` (33), `78e1037` (34),
`fa959b0` (35), `c26461e` (36), `9749453` (37), `d13bad8` and `9b98dbc` (38).
The final evidence update changes benchmark documents/data only; the tested
source, tests, dependency lock and workflow remain those of `9b98dbc`.
