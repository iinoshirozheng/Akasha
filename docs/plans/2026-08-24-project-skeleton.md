# AkashaDB Project Skeleton Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a reproducible Pixi project using stable Mojo with a compilable layered database skeleton and one test-driven public API.

**Architecture:** Keep the Mojo database kernel independent from adapters. Python bindings, CLI, and FastAPI live outside `src/akasha`; future vector indexes and GPU kernels depend inward on small traits rather than on the server layer.

**Tech Stack:** Pixi, Mojo stable, Python 3.11, FastAPI, Uvicorn, pytest, Hypothesis, NumPy, GitHub Actions.

---

### Task 1: Initialize the reproducible environment

**Files:**
- Create: `pixi.toml`
- Create: `pixi.lock`

**Step 1:** Run `pixi init . -c https://conda.modular.com/max/ -c conda-forge`.

**Step 2:** Run `pixi add mojo "python==3.11" fastapi uvicorn pytest hypothesis numpy`.

**Step 3:** Run `pixi run mojo --version` and confirm the stable 1.0 channel resolves.

### Task 2: Drive the first Mojo API with TDD

**Files:**
- Create: `tests/mojo/test_database_config.mojo`
- Create: `src/akasha/__init__.mojo`
- Create: `src/akasha/api/__init__.mojo`
- Create: `src/akasha/api/database.mojo`

**Step 1:** Write a test importing `DatabaseConfig` and asserting that it retains its name and format version.

**Step 2:** Run `pixi run mojo run -I src tests/mojo/test_database_config.mojo` and verify it fails because the package is absent.

**Step 3:** Add the minimal `DatabaseConfig` implementation and package initializers.

**Step 4:** Re-run the test and require a clean pass.

### Task 3: Create architectural package boundaries

**Files:**
- Create package and placeholder modules under `src/akasha/{common,document,compute,index,query,storage}`.
- Create adapter skeletons under `src/bindings`, `python/akashadb`, and `apps`.
- Create benchmark, format, example, tool, documentation, and CI placeholders.

**Step 1:** Add every Mojo package directory with an `__init__.mojo`.

**Step 2:** Add only declarations or documentation placeholders; do not pretend unimplemented indexes work.

**Step 3:** Add Pixi tasks for Mojo tests, build, and Python tests.

### Task 4: Verify the generated project

**Files:**
- Verify all generated files.

**Step 1:** Run the Mojo unit test task.

**Step 2:** Build the Mojo smoke executable.

**Step 3:** Run Python tests.

**Step 4:** Inspect the directory tree and ensure generated caches are ignored.

**Step 5:** Do not commit because this directory was not supplied as a Git repository.
