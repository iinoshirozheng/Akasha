# Boolean Filter Expressions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add bounded owned Condition/And/Or/Not metadata expressions while preserving the Phase 4.2 AND-list APIs.

**Architecture:** `FilterExpression` stores an explicit node tag, an optional owned condition, and owned child expressions. The evaluator recursively short-circuits with strict payload semantics; new `search_*_where` collection methods pre-filter entries before SIMD scoring without changing persistence.

**Tech Stack:** Mojo 1.x stable, Pixi, existing `FilterCondition`, `PayloadValue`, exact SIMD scan, `BoundedTopK`, and `std.testing.TestSuite`.

---

### Task 1: Bounded owned expression model

**Files:**
- Create: `tests/mojo/test_filter_expression.mojo`
- Modify: `src/akasha/query/filter_ast.mojo`

1. Write failing tests for Condition, empty/non-empty All, empty/non-empty Any, Negate, deep ownership, raw invalid node shapes, maximum depth 16, and maximum node count 256.
2. Run `pixi run mojo run -I src tests/mojo/test_filter_expression.mojo` and require RED because `FilterExpression` does not exist.
3. Implement movable recursive `FilterExpression` with explicit tags, `condition`, `all`, `any`, `negate`, `clone`, and full-tree `validate`; reject malformed shapes, depth overflow, and node-count overflow.
4. Run filter expression and filter AST tests; format, inspect `git diff --check`, and commit `feat: add boolean filter expression model`.

### Task 2: Recursive short-circuit evaluator

**Files:**
- Modify: `tests/mojo/test_filter_evaluator.mojo`
- Modify: `src/akasha/query/evaluator.mojo`

1. Add failing evaluator tests for nested `(A AND B) OR NOT C`, empty All=true, empty Any=false, missing-field propagation, and mutated invalid expression rejection.
2. Run the focused evaluator test and require RED because `matches_expression` does not exist.
3. Implement recursive `matches_expression(fields, expression)` using the existing typed condition comparison, short-circuiting All/Any and negating exactly one child after validating the full tree.
4. Run evaluator/expression/Phase 4.2 filter tests; format, inspect `git diff --check`, and commit `feat: evaluate boolean filter expressions`.

### Task 3: `search_*_where` public APIs

**Files:**
- Modify: `tests/mojo/test_persistent_filters.mojo`
- Modify: `tests/mojo/test_public_api.mojo`
- Modify: `src/akasha/api/collection.mojo`
- Modify: `src/akasha/query/__init__.mojo`
- Modify: `src/akasha/__init__.mojo`

1. Add failing tests for root export and dot/L2/cosine `search_*_where`, nested expressions, pre-filter-before-cosine behavior, stable ties, WAL-only reopen, snapshot reopen, delete, and search-result-to-get.
2. Run focused tests and require RED because the public methods and export do not exist.
3. Export `FilterExpression`, add three backward-compatible where methods, and share exact score/Top-K result construction while expression evaluation happens before metric scoring.
4. Run all query, persistence, compatibility, and crash tests; format, inspect `git diff --check`, and commit `feat: add boolean-filtered vector search`.

### Task 4: Documentation and full verification

**Files:**
- Modify: `examples/persistent_collection.mojo`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/query-model.md`

1. Update the example with an OR/NOT expression and document compatibility, strict semantics, empty-node behavior, and configured limits.
2. Format Mojo changes.
3. Run `pixi run test`, `pixi run test-crash`, `pixi run build`, `pixi run smoke`, and `pixi run example-persistent`.
4. Run `git diff --check`, inspect the roadmap requirements, and commit `docs: complete boolean filtering phase`.
5. Fast-forward `main`, re-run `pixi run test`, remove the worktree/branch, and push `main`.

