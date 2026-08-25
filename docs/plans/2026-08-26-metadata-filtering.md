# Metadata Filtering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add strict typed AND metadata filters that reject documents before exact SIMD vector scoring.

**Architecture:** Introduce an owned `FilterCondition` with validated explicit operator tags, then evaluate conditions against Phase 4.1 document fields in the query layer. `PersistentCollection` exposes backward-compatible filtered variants of all three exact metrics and leaves WAL, Segment, and Manifest formats unchanged.

**Tech Stack:** Mojo 1.x stable, Pixi, existing `PayloadValue`/`DocumentField` model, MemTable live-state scan, SIMD metrics, `BoundedTopK`, and `std.testing.TestSuite`.

---

### Task 1: Typed filter condition model

**Files:**
- Create: `tests/mojo/test_filter_ast.mojo`
- Modify: `src/akasha/query/filter_ast.mojo`
- Modify: `src/akasha/document/value.mojo`
- Modify: `src/akasha/document/record.mojo`

1. Write tests that construct all six operators, verify owned field/value copies, reject empty or NUL field names, reject String/Bool range operators, and reject non-finite Float64 filter values through `PayloadValue`.
2. Run `pixi run mojo run -I src tests/mojo/test_filter_ast.mojo` and verify it fails because `FilterCondition` does not exist.
3. Expose value-kind predicates on `PayloadValue`, make the existing document field-name validator reusable, and implement movable `FilterCondition` with `equal`, `not_equal`, `less_than`, `less_or_equal`, `greater_than`, and `greater_or_equal` constructors. Its validated raw constructor must reject unknown operator tags and invalid type/operator combinations.
4. Re-run the focused filter AST and document value tests and require all cases to pass.
5. Format changed Mojo files, run `git diff --check`, and commit as `feat: add typed metadata filter conditions`.

### Task 2: Strict AND filter evaluator

**Files:**
- Create: `tests/mojo/test_filter_evaluator.mojo`
- Create: `src/akasha/query/evaluator.mojo`

1. Write evaluator tests for String and Bool equality/inequality; Int64 and Float64 equality, inequality, and ordering; multiple-condition AND; empty conditions; missing fields; strict Int64/Float64 mismatch; and missing-field inequality returning false.
2. Run `pixi run mojo run -I src tests/mojo/test_filter_evaluator.mojo` and verify it fails because `matches_all` does not exist.
3. Implement `matches_all(fields, conditions) -> Bool` with linear exact field lookup, kind equality before typed getters, short-circuit AND, and no numeric coercion.
4. Re-run evaluator, filter AST, and document tests and require them to pass.
5. Format, run `git diff --check`, and commit as `feat: evaluate typed metadata filters`.

### Task 3: Filtered PersistentCollection search APIs

**Files:**
- Create: `tests/mojo/test_persistent_filters.mojo`
- Modify: `tests/mojo/test_public_api.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/query/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`

1. Write tests for the root `FilterCondition` export; `search_dot_filtered`, `search_l2_filtered`, and `search_cosine_filtered`; filtered Top-K ordering; deterministic ID ties; empty-condition equivalence; and no matches returning an empty list.
2. Add a pre-filter regression case with a zero-norm vector that would fail cosine scoring but is rejected by metadata; run the focused test and verify failure because the filtered APIs do not exist.
3. Export `FilterCondition`, add the three public filtered methods, and refactor the private exact scan so conditions are evaluated before metric scoring while existing unfiltered methods route through an empty condition list.
4. Run persistent filter, persistent document, persistent collection, public API, evaluator, and SIMD tests.
5. Format, run `git diff --check`, and commit as `feat: add pre-filtered exact vector search`.

### Task 4: Recovery and mutation integration coverage

**Files:**
- Modify: `tests/mojo/test_persistent_filters.mojo`

1. Add tests that filtered results survive WAL-only reopen and flush/reopen, vector-only replacement clears filterable fields, delete removes candidates, and `get(result.id)` returns the matched payload.
2. Temporarily target one assertion at a missing persistence behavior or fixture and run the focused test to establish RED before completing the integration cases.
3. Make only the minimal production correction if a real gap appears; otherwise complete the tests against the already composed Phase 4.1 recovery path and record that no storage-format change is required.
4. Re-run persistent filters plus WAL v1/v2, Segment v1/v2, MemTable, document codec, and crash recovery tests.
5. Format, run `git diff --check`, and commit as `test: cover persistent metadata filtering`.

### Task 5: Example, documentation, and full verification

**Files:**
- Modify: `examples/persistent_collection.mojo`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`

1. Update the persistent example to filter document type/page metadata before cosine search, reopen the collection, and resolve the winning payload through `get`.
2. Document the Phase 4.2 API, strict missing/type semantics, supported operators, AND-only boundary, pre-filter data flow, absence of a metadata index, and unchanged v1/v2 storage compatibility.
3. Format every changed Mojo file.
4. Run `pixi run test`, `pixi run test-crash`, `pixi run build`, `pixi run smoke`, and `pixi run example-persistent`.
5. Run `git diff --check`, inspect every requirement in the approved design, and commit as `docs: complete metadata filtering phase`.

