# Native numeric formula validation

Date: 2026-10-30. Mojo 1.0.0 (ed45d567), macOS ARM64.
Qdrant revision `74f3e85b9473c62560006c043e13737ce6b48412`, Apache-2.0.

Subsequent Q04c/D01a work replaces this slice's provisional variable grammar
and signed-index restriction with a shared source-backed JSON-path parser,
UInt64 score indexes and `FormulaDefault`. See the
[JSON-path validation](2026-10-30-json-path-validation.md). The results below
remain the historical Q04b evidence; nested/date/geo value work is still open.

## Source and implementation

`query/formula.mojo` ports numeric evaluation, payload/score defaults and decay
parameter conversion from `segment/index/query_optimization/rescore_formula/`
`{formula_scorer,parsed_formula}.rs`. The ordered native arena replaces recursive
expression allocation. It preserves F32 constant promotion, F64 ordered math,
lazy multiplication/division, operation-specific nonfinite checks, condition
values, decay functions and final finite-F32 scoring.

`query/universal.mojo` adapts `segment/segment/read_view/formula_rescore.rs`:
one score map per ordered prefetch, last-inserted score for duplicates within a
source, deduplicated visible-head candidate union, whole-query error propagation,
and Top-K rescoring. It uses the same retained read generation as the prefetch.
Planner/conversion references include `shard/query/formula.rs`, local-shard
formula rescoring and the REST expression schema. Existing native ascending-ID
score ties and snapshot ownership remain; full Qdrant protocol parity is not
claimed.

Public native `Formula`/`FormulaNode`, Python `Formula`/`QueryRequest("formula")`
and the existing Arrow query boundary execute this native path. Python only
serializes the wrapper. The bound parser limits recursion/allocation before
constructing the arena; formula conditions also use bounded filter parsing.
All Python conversions finish before acquiring target or external lookup roots,
and closed handles are rechecked. No persistent format or GPU path changed.

## Independent reference and verification

The Rust oracle compiles eight **unedited** upstream function bodies with
transport/container/dependency adapters, using a release profile. Its 309 cases
include 57 expected errors. Both native and public Python paths compare exact
F32 bits against it. Cases cover every numeric operator, F64 cancellation,
signed zero, defaults and wrong types, ordered short circuits, intermediate
overflow/NaN, decay and seeded expression trees.

An adversarial decay caused an upstream debug-build assertion. The generator
now records a release build (`opt-level=3`, `debug-assertions=no`) so it exercises
the production final-score check without changing the copied function bodies.
An integration test's reversed equal-score IDs were corrected to the existing
documented ascending-ID contract; no implementation tie rule was changed.

Verified commands:

- `rtk proxy python scripts/qdrant_formula_reference.py`: 309 cases, 57 errors.
- `rtk proxy pixi run mojo run -I src tests/mojo/test_formula.mojo`: 4 passed,
  including all 309 source numerical fixtures.
- `rtk proxy pixi run mojo run -I src tests/mojo/test_universal_query.mojo`:
  5 passed, including prior planner fixtures and a formula snapshot retained
  across payload replacement, deletion and collection close; shared native
  cancellation is checked after constructing the control object.
- `rtk proxy pixi run test-python`: **2461 passed, 1 skipped**. Includes rebuilding
  the extension and maintenance worker, all 346 new formula cases, and all
  existing Python/Arrow/server tests. The skip remains optional Qdrant Edge
  integration; three existing binding/FastAPI deprecation warnings remain.
- `rtk proxy git diff --check`: passed.

Public tests additionally cover nested formulas, independent child score slots,
union deduplication, filters before leaf Top-K, threshold/root offset, empty
unions, wrong types even below Top-K/threshold, Arrow ownership after close,
shared work/structural limits, cancellation/deadline, cyclic/deep expressions
and conditions, invalid/conflicting options, live heads after reopen, and
conversion callbacks closing the target or an external lookup.

## Explicit remaining scope

This completes the numeric/flat-payload formula slice, not all Q04 or all formula
behavior. Full JsonPath syntax (including quoted and Unicode identifier rules),
nested/array/null values, datetime parsing/time arithmetic, geo distance and
rich defaults remain linked to D01/D03. The current payload adapter uses native
flat field names and nonnegative native Int score indexes; duplicate normalized
score-default aliases are rejected. Those are explicit boundary limitations,
not evidence of full upstream parsing compatibility. Conditions use Akasha's
existing scalar filter behavior and representation, not the REST condition wire
format. The oracle's geo/date stubs are never exercised, and it does not validate
the entire Qdrant server, distributed merge or compiler/platform combinations.

Formula expression/default entries share the query-node structural budget.
Candidate work charges prefetched input rows; expression/condition bounds cap
work per row. Core evaluation checks deadlines/cancellation recursively. This
is a bounded implementation, not a latency or memory performance claim.

Full CPU/C ABI/crash/GPU and native Linux gates were not rerun for this query-only
change. Existing M5/M6 failures, repeated-vector recall gaps and native Linux
deferral remain. Sampling/feedback, other query/data/schema/SQL/Lance/UI/security/
cluster/operations deliverables stay open. No optimization was performed.
