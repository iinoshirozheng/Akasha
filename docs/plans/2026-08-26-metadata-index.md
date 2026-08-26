# Phase 9 Metadata Index Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add derived typed metadata indexes and bitmap-driven filter-aware query execution without changing durable formats or public query semantics.

**Architecture:** Stable MemTable slots are metadata ordinals. Keyword postings and sorted numeric blocks evaluate conditions into bitmaps; Boolean expressions combine those bitmaps and the collection executes only candidate ordinals. Recovery rebuilds the derived index, while writes update it after authoritative WAL and MemTable mutations.

**Tech Stack:** Mojo stable through Pixi, Mojo `TestSuite`, existing CPython extension and pytest adapters.

---

### Task 1: Bitmap primitive

**Files:**
- Modify: `src/akasha/index/bitmap.mojo`
- Create: `tests/mojo/test_bitmap.mojo`

1. Write failing tests for growth, set/clear, cached cardinality, AND, OR, and
   live-universe subtraction.
2. Run `mojo run -I src tests/mojo/test_bitmap.mojo` and confirm missing API
   failures.
3. Implement a 64-bit-word owned `Bitmap` with validated indexes and equal-size
   set operations.
4. Re-run the focused test and existing Mojo tests.
5. Commit `feat: add metadata candidate bitmap`.

### Task 2: Typed field indexes

**Files:**
- Create: `src/akasha/index/keyword.mojo`
- Modify: `src/akasha/index/sorted_block.mojo`
- Create: `tests/mojo/test_metadata_field_indexes.mojo`

1. Write failing tests for String/Bool equality postings and Int64/Float64
   equality/range results.
2. Confirm the focused test fails because typed indexes are absent.
3. Implement sorted keyword postings plus type-specific sorted numeric blocks,
   including same-type presence semantics for inequality.
4. Run focused and regression tests.
5. Commit `feat: add typed metadata field indexes`.

### Task 3: Metadata expression evaluation

**Files:**
- Create: `src/akasha/index/metadata.mojo`
- Create: `src/akasha/query/index_evaluator.mojo`
- Modify: `src/akasha/index/__init__.mojo`
- Create: `tests/mojo/test_metadata_index.mojo`

1. Write failing equivalence tests for all operators, missing/type mismatches,
   nested All/Any/Negate, empty Boolean nodes, and cardinality.
2. Confirm failure from missing `MetadataIndex` and indexed evaluator.
3. Implement stable ordinals, live universe, incremental replace/delete, and
   iterative flat-arena expression evaluation.
4. Compare indexed candidates with `matches_expression` across deterministic
   mixed documents.
5. Commit `feat: evaluate filters with metadata indexes`.

### Task 4: Collection integration

**Files:**
- Modify: `src/akasha/storage/memtable.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/query/executor.mojo`
- Modify: `tests/mojo/test_persistent_filters.mojo`
- Modify: `tests/mojo/test_persistent_hnsw.mojo`
- Modify: `tests/mojo/test_persistent_sparse.mojo`

1. Write failing tests proving replacement/delete/reuse, WAL/snapshot rebuild,
   exact candidate execution, approximate planning, and sparse/hybrid filter
   membership remain correct.
2. Add stable MemTable slot access and build `MetadataIndex` after recovery.
3. Update it after successful upsert/delete and route all filtered execution
   through indexed candidate bitmaps.
4. Use cached bitmap cardinality in `QueryPlanner`; keep exact fallback when
   HNSW over-fetch cannot fill `k`.
5. Run focused tests and the complete test task.
6. Commit `feat: integrate metadata index query execution`.

### Task 5: Adapter compatibility, benchmark, and documentation

**Files:**
- Create: `benchmarks/mojo/metadata_bench.mojo`
- Modify: `pixi.toml`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`
- Modify: `tests/python/test_package.py`
- Modify: `tests/python/test_server.py`

1. Add Python/HTTP regression assertions for indexed nested filters and reopen.
2. Add a `bench-metadata` harness for 10K and 100K candidate evaluations.
3. Document derived-state recovery, strict typing, complexity, and the unchanged
   storage/API boundary.
4. Run `pixi run test`, `pixi run test-crash`, `pixi run build`,
   `pixi run smoke`, `pixi run example-persistent`, focused benchmark smoke,
   `mojo format`, and `git diff --check`.
5. Commit `docs: complete metadata index phase` and stop for user review.
