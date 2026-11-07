# Native JSON expression / residual / snapshot integration

Baseline: 7e474aa. Compiler: Mojo 1.0.0 (ed45d567).

## Implemented contract

`JsonExpression` binds JSON scalar projections to typed equality, range, IN and
IS NULL predicates and composes bounded AND/OR/NOT trees. Literal binding ports
the applicable `safe_coerce_scalar` rules for the five native scalar types;
nonnull Int64 -> Float64 is allowed, other cross-type combinations are rejected.
Float64 comparison retains the existing Lance target's ordering. This is not a
SQL parser or a claim of full DataFusion type-system compatibility.

`ReadSnapshot.prepare_json` acquires an immutable read root. `PreparedJsonQuery`
constructs explicitly requested materialized indexes on exactly that root and
binds only leaves accepted by the existing equivalence guard. Postings use local
UInt64 row ordinals; returned point IDs remain signed Int. Unhandled leaves are
retained and evaluated in their original order. Index masks do not reorder or
pre-evaluate residual functions. NOT preserves unknown; unknown is not selected.
Empty IN, nullable literals, nested projections, extension string conversions and
custom JSON work limits preserve the necessary residual path.

The prepared query owns the root through collection/snapshot close and later
writes, deletion and compaction. New preparation on a closed snapshot fails.
Explicit construction errors are propagated; successfully built indexes with
incompatible function references simply leave their leaves residual. Cancellation,
deadline and candidate budgets propagate through preparation/search/execution.
Tree topology, type, depth, node and literal limits are validated before execution.

## Requirement evidence

| Requirement | Evidence |
| --- | --- |
| nullable AND/OR/NOT | `test_json_truth.mojo`: exhaustive nine-pair truth tables and null literal/IN behavior |
| mixed indexed/residual execution | 100 combinations in `test_nullable_boolean_index_and_residual_matrix`, compared against identical all-residual trees |
| scalar binding and bounds | comparison suite exercises six operators; integration tests Int64 -> Float64, range inclusion, rejected types and limits |
| preserve short circuit/errors | direct and prepared AND/OR with erroring getters; extension string getter remains residual, skipped branch succeeds and reached branch errors |
| correct snapshot identity | old/new views after replacement; negative IDs; deleted row absent after flush/compaction/reopen, retained prepared view unchanged |
| independent lifetime | execution after both collection and snapshot close; new preparation on closed handle rejected |
| cancellation/resource errors | cancelled preparation/execution, exceeded row budget, expired deadlines, invalid path including empty snapshot, depth/node and malformed tree cases |
| nested values | nested projection remains residual beside a covered indexed leaf and matches full scan |
| failed operations preserve state | incompatible index creation and failed execution followed by successful use of existing snapshot/prepared query |

## Validation

Nine tests in `tests/mojo/test_json_expression_snapshot.mojo` pass on the final
native implementation. A previous reopen failure was a test fixture lifetime
error: Mojo released Python TemporaryDirectory after its last path access,
deleting the directory before reopen. An explicit final cleanup keeps it alive;
the actual reopen/retained-view test then passes.

Related Mojo runs pass: json_truth 2, lance_json_comparison 2,
lance_json_matcher 4 (1,344 original-source scenarios), snapshot 10,
point_snapshot 4, scanner 4. These are 26 distinct related tests, plus the nine
integration tests, not a complete CPU suite. Logs for the related runs are under
`.build/json-expression-validation/`. Existing source bitmap/nullable/consumer
oracle evidence is reused; the mixed executor is tested against direct evaluation,
not represented as an independently executed full DataFusion planner.

`pixi run build-python` passes. Targeted Python JSON projection/condition and
Arrow/rich Arrow scanner regression passes **109 tests**, with three existing
deprecation warnings. Commands and output are recorded in
`.build/json-expression-validation/boundary-results.json` and boundary logs. No persisted bytes,
writer/publication rules or GPU query paths change, so no new crash or GPU gate
is claimed. Durable catalog/index management and Python/Arrow/HTTP exposure of
this new prepared API remain the next index stage. M5/M6 remains unchanged.
