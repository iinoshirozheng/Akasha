# JSON expression, residual and snapshot integration

Objective: complete the native Lance JSON expression execution path over actual
Akasha read snapshots. Durable catalog/public Python integration remains the
next independently tracked index stage, not a prerequisite for this native API.

## Contracts

- One prepared query owns an ArcPointer[ReadGeneration] acquired from ReadSnapshot.
  Index construction, residual reads and result IDs use that same root. No index
  supplied from a different root can be selected. Existing read leases preserve
  the view across collection updates, compaction and handle close.
- Expressions are bounded owned trees: typed JSON function leaves, equality,
  ordered comparisons, IN, IS NULL, ranges, AND/OR/NOT. Function/path/column and
  literal binding supports native Int64-to-Float64 coercion; unsupported coercions raise during binding rather
  than silently changing comparison semantics. Preserve exact native scalar types.
- Native comparison ordering follows the pinned Lance scalar target. SQL parsing
  and wider DataFusion coercions are not implied by this API.
- Nullable truth is true/false/unknown. AND stops on false, OR stops on true, NOT
  preserves unknown. Unknown does not pass a filter. Residual leaves execute in
  original tree order and only on rows that reach them.
- Preparation may replace a leaf only with a matching guarded index mask. A
  declined leaf remains in the tree; never treat None as an empty result. A function/type
  incompatibility with a successfully built index leaves the leaf residual.
  Explicit index construction errors, cancellation, resource failures and
  unexpected errors are reported; none are swallowed.
- Index preparation is explicit and bound to this snapshot. Avoid eager probing
  of error-prone residual functions. Build failures must not hide scan errors or
  evaluate branches which the query would skip. Prefer indexing explicitly
  requested column/path pairs, with construction errors reported as such.
- Enumerate only visible live points, preserving signed Int IDs by mapping local
  snapshot row ordinals to UInt64 postings. Never cast negative point IDs into
  a public UInt64 identity contract.
- Cancellation/deadlines cover preparation, index search and residual execution;
  row, expression-depth/node, JSON-work and materialized-index limits stay bounded.

## Implementation sequence and acceptance

1. Bounded expression representation and direct three-valued row evaluator.
   Reuse JsonbProjection/source consumers and Lance scalar primitives. Test all
   logical truth tables, null literals, IN nulls, boundaries and short-circuit
   errors, including unsupported literal types.
2. Snapshot-owned prepared executor and explicit column/path index construction.
   Bind covered leaves to guarded masks; retain remaining leaves. Execute the
   same expression with indexes disabled as the correctness oracle.
3. Expose preparation through ReadSnapshot. Verify actual persistent collections:
   mixed indexed/residual AND/OR/NOT, negative IDs, deletes/replacements, snapshots
   before/after writes, flush/compaction, collection/snapshot close, cancellation,
   incompatible construction and failed queries preserving reusable state.
4. Relevant Mojo regression gates and documentation/source provenance. Review
   coverage against every contract above before marking the active goal complete.

Pinned source: Lance scalar/expression.rs and scalar/json.rs at
ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e; existing nullable_rows and JSON consumer
ports. Akasha query/index_evaluator.mojo already documents why independently
executing fallible JSON leaves violates its short-circuit contract. We retain
leaf order instead of copying upstream AND extraction across fallible residuals.

## Acceptance result

The native expression/residual/snapshot objective is implemented and verified.
Nine new integration tests, 26 related Mojo tests, Python module build and 109
targeted Python boundary tests pass. Full evidence and limitations are in
[validation](../research/2026-11-07-json-expression-snapshot-validation.md).
Durable catalog and service/SDK exposure of the new prepared API remain separate
index stages; no full CPU, performance, native Linux or GPU completion is claimed.
