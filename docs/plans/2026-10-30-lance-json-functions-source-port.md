# Lance JSONB functions and query integration

Continue from `027210a` and the complete JSONB query plan. This is a dependency
and consumer sequence within D01/D03/A03; retain all 49 product packages and
feature-before-optimization order.

Sources are the pinned Lance `lance-arrow/src/json.rs`,
`lance-datafusion/src/udf/json.rs`, jsonb 0.5.6 `functions/{scalar,path}.rs` /
`number.rs`, ethnum 1.5.3 native division and Rust's integer parsing contract.

1. Complete Number exact i64/u64 and rounded i128/i64/u64 conversions. Port
   ethnum's full unsigned 256-bit division, retaining its existing single-word
   branch, and source Decimal exact/half-away rounding and boundary rules.
   Verify all numeric variants/scales and floating boundaries against original
   Number methods and independent original ethnum quotients/remainders.
2. Port RawJsonb scalar casts, exact key/index access and source type tags.
   Preserve the distinction between strict/exact getters and rounded casts,
   Rust string parsing, nonfinite floats, invalid casts and JSON null.
3. Port the actual Lance consumer functions: Arrow first-text path selection;
   DataFusion extract/extract_with_type/exists/get/get_string/get_int/get_float/
   get_bool/array_contains/array_length. Execute original core and nullable Arrow
   row functions as the oracle. Any harness adapters must be restricted to
   outer type/error/registration boundaries, not expected-result algorithms.
   Cover null inputs, scalar path broadcasting, missing values, duplicate/multi
   matches, exact binary types and failures. Do not infer behavior from comments.
4. Expose native and thin Python/Arrow execution, preserving ownership and
   limits. Integrate collection filtering/projection with original semantics;
   verify indexed versus direct behavior when indexes are added. Cover reopened
   WAL/checkpoint values and read-only errors, then relevant regressions.
5. Keep SQL UDF registration/execution pending the actual SQL layer; complete
   remaining C/distributed/index contracts in their product work packages.

Known source distinctions: Arrow's path helper returns only the first rendered
value; DataFusion extraction wraps multiple matches into one JSONB array.
Typed extraction preserves bytes while reporting the source type tag. Integer
casts round ties away from zero; exact checks do not round. Boolean casts accept
case-insensitive true/false/yes/no strings but reject numeric 0/1. Array length
and contains must follow the actual get_by_index behavior, including nonarrays.
Number Display and RawJsonb JSON rendering are separate already-ported paths.

## Conversion checkpoint: D01c4e

Step 1's five Number conversions and full unsigned ethnum division are native
and verified. Step 2's five RawJsonb scalar casts are native and exposed through
Python `JsonbValue.cast`; Rust integer parsing source/license are pinned and
verified. 96,744 typed numbers, 19,975 binary values × five casts, and 22,188
original quotient/remainder results pass. Twenty-five native tests, 17 new
Python tests and full Python **3,698 passed / 1 skip** pass; source fixture/
metadata/lock reproduce. See [evidence](../research/2026-10-30-jsonb-cast-validation.md).

Continue exact key/index lookup and type tags, the actual consumer functions and
their nullable Arrow/Python/public integrations. This checkpoint is not full
Lance consumer, collection query, SQL or product completion.

## Consumer checkpoint: D01c4f

Steps 2 and 3 now have exact key/index access, source tags and all eleven actual
Lance consumer operations. Step 4's native and public Python/nullable Arrow
execution is verified; SQL/collection planner/index integration is still open.
47,223 scenarios / 216,337 source outcomes, 25 native tests, 18 new Python tests,
178 boundary tests and full Python 3,716 passed / 1 skip; final build and source
fixture/metadata/lock reproduction pass. Existing depth-limit differences are
explicitly retained, not hidden. [Evidence](../research/2026-10-30-lance-json-functions-validation.md).

Next, inspect the existing collection filter/project/index call paths and Lance
expression consumers before implementing planner integration. Reuse these
verified functions; do not reimplement conversions, path selection or formatting.
Complete the remaining 49-package ledger in its existing order, without starting
optimization or treating this consumer checkpoint as full D01/Lance completion.
