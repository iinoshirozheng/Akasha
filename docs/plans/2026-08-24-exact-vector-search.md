# Exact Vector Search Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement validated `Float32` distance primitives and deterministic exact Top-K flat search in Mojo.

**Architecture:** Put mathematical primitives in `src/akasha/compute/distance.mojo` and the owning in-memory index in `src/akasha/index/flat.mojo`. Keep the implementation scalar as a correctness baseline and expose it only through Mojo package exports.

**Tech Stack:** Mojo 1.0.0 stable, Pixi, `std.testing.TestSuite`.

---

### Task 1: Distance primitives

**Files:**
- Create: `tests/mojo/test_distance.mojo`
- Modify: `src/akasha/compute/distance.mojo`

**Step 1:** Write separate tests for dot product, L2 squared distance, cosine similarity, mismatched dimensions, empty vectors, and zero-norm cosine inputs.

**Step 2:** Run `pixi run mojo run -I src tests/mojo/test_distance.mojo` and verify failure because the imported functions do not exist.

**Step 3:** Implement shared validation plus the three scalar `Float32` functions.

**Step 4:** Re-run the test and require all cases to pass.

### Task 2: Exact FlatIndex

**Files:**
- Create: `tests/mojo/test_flat_index.mojo`
- Modify: `src/akasha/index/flat.mojo`

**Step 1:** Write tests for dot, L2, and cosine Top-K order; stable ID tie-breaking; result limits; query dimensions; and positive `k`.

**Step 2:** Run `pixi run mojo run -I src tests/mojo/test_flat_index.mojo` and verify failure because `FlatIndex` does not exist.

**Step 3:** Implement owned records, `SearchResult`, validation, and deterministic exact selection.

**Step 4:** Re-run the test and require all cases to pass.

### Task 3: Integration and verification

**Files:**
- Modify: `src/akasha/compute/__init__.mojo`
- Modify: `src/akasha/index/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`
- Modify: `pixi.toml`
- Modify: `examples/smoke.mojo`
- Modify: `README.md`

**Step 1:** Export the public API and make the Pixi Mojo task discover all test files.

**Step 2:** Extend the smoke example to execute exact search.

**Step 3:** Run `pixi run test`, `pixi run build`, `pixi run smoke`, and `mojo precompile`.

**Step 4:** Do not commit because the directory was not supplied as a Git repository.
