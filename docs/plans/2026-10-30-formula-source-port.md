# Q04b source-backed score formulas

Status: numeric/flat-payload slice implemented and verified; full formula remains open. Qdrant revision
`74f3e85b9473c62560006c043e13737ce6b48412`.

Port `rescore_formula/formula_scorer.rs`, `parsed_formula.rs`, shard formula
conversion and segment formula rescoring. Preserve F32 constant promotion,
F64 ordered evaluation, lazy multiply/divide, per-operation nonfinite rules,
defaults, condition values, decay parameter conversion and final F32 scoring.
Rescore the visible union of prefetched IDs on the same retained query root.
Compile unmodified upstream numerical evaluation and decay functions as the
independent oracle. Keep Python limited to transport/shape serialization.

The first usable layer covers all numeric operators, score variables, current
flat numeric payload values, native conditions, missing-value defaults and
linear/exponential/Gaussian decay. Expose native/Python/Arrow query integration,
errors, cancellation and resource bounds with source fixtures and regression
tests. Do not evaluate unvisited branches or replace failures with zero.

Full formula acceptance also requires source JSON-path semantics, nested/array
payload retrieval, date parsing/time arithmetic and geo-distance values. Those
remain open with D01/D03 until their source-backed data/type implementations
are integrated. This layer does not redefine full Q04 completion or remove any
other feature/product/performance gate. No tuning or performance experiments.

Delivered native/Python/Arrow integration, 309 unedited-source numerical cases
(57 expected errors), nine relevant native tests and full Python validation
(2461 passed, one optional skip). See
[verification and remaining boundaries](../research/2026-10-30-formula-validation.md).
