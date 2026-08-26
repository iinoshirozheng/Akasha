# Phase 13 GPU Execution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add batched Mojo GPU scoring and Top-K with a deterministic planner and CPU fallback that preserves scalar query semantics.

**Architecture:** A pure host planner decides from hardware availability, batch size, dimensions, candidate count, transfer bytes, memory budget, and a work threshold. The GPU path flattens an immutable MemTable view, launches one score thread per query/candidate pair, then one deterministic Top-K thread per query. CPU SIMD remains the oracle and fallback for disabled/unsupported devices, small workloads, memory rejection, allocation/launch failure, or score validation failure. A compile-time `use_accelerator` switch keeps the fallback testable on hosts whose optional device compiler is unavailable.

**Tech Stack:** Mojo 1.0 stable, `max.gpu.host.DeviceContext`, `TileTensor`, Mojo GPU kernels, Pixi, Apple Metal/NVIDIA/AMD backends, existing SIMD/Top-K executors.

---

### Task 1: Device planner and fallback contract

**Files:**
- Create: `src/akasha/compute/gpu/planner.mojo`
- Modify: `src/akasha/compute/gpu/__init__.mojo`
- Test: `tests/mojo/test_gpu_planner.mojo`

1. Add failing tests for unavailable/disabled hardware, small workloads, memory budget, overflow-safe byte estimation, and eligible plans.
2. Prove RED.
3. Implement `GpuExecutionOptions`, `GpuPlan`, and deterministic reason strings.
4. Run focused tests and commit.

### Task 2: Batched score kernels

**Files:**
- Replace: `src/akasha/compute/gpu/flat_scan.mojo`
- Test: `tests/gpu/test_gpu_flat_scan.mojo`

1. Add GPU-only differential tests for dot, squared-L2, cosine, tails, and non-multiple block sizes.
2. Implement a plain Mojo kernel over 1-D `TileTensor` views with fixed-width scalar launch arguments and one thread per query/candidate score.
3. Validate finite/nonzero inputs on the host, allocate/copy through `DeviceContext`, launch, synchronize, and copy scores back.
4. Run on actual accelerator hardware; do not count a skip/fallback as GPU evidence.
5. Commit.

### Task 3: Deterministic GPU Top-K

**Files:**
- Modify: `src/akasha/compute/gpu/flat_scan.mojo`
- Test: `tests/gpu/test_gpu_flat_scan.mojo`

1. Add failing tests for all metrics, ascending-ID ties, `k > point_count`, and multiple queries.
2. Implement one Top-K kernel thread per query, with no heap allocation, deterministic selected-ID exclusion, and metric-aware comparison.
3. Compare IDs and scores with CPU SIMD within documented Float32 tolerance.
4. Run on actual accelerator and commit.

### Task 4: Snapshot/API integration and mandatory fallbacks

**Files:**
- Modify: `src/akasha/api/snapshot.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Test: `tests/mojo/test_gpu_fallback.mojo`
- Test: `tests/gpu/test_gpu_snapshot.mojo`

1. Add RED tests for disabled GPU, small workload, insufficient memory, allocation/launch failure injection, filtering, and closed snapshots.
2. Expose device batch dot/L2/cosine and filtered variants returning results plus execution metadata.
3. Route every rejection/failure through the existing exact batch executor and preserve input order, scores, and ties.
4. Add actual-GPU snapshot differential tests.
5. Run focused CPU and GPU suites; commit.

### Task 5: Benchmarks, docs, and completion gate

**Files:**
- Create: `benchmarks/mojo/phase13_gpu_bench.mojo`
- Create: `docs/benchmarks/phase13.md`
- Modify: `pixi.toml`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`

1. Benchmark CPU vs GPU end-to-end QPS/p95 across batch, dimension, and candidate crossover points; record transfer and kernel-inclusive time.
2. Require CPU/GPU ID parity and Float32 score tolerance for all metrics and ties.
3. Document current device/compiler prerequisites and every fallback reason.
4. Run full tests, GPU tests on real hardware, crash tests, build, smoke, examples, benchmark, and `git diff --check`.
5. Commit only after the actual GPU differential gate exits zero.
