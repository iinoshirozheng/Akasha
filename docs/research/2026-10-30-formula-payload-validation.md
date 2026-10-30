# Q04d rich formula payload validation

Date: 2026-10-30. Parent `4bca4ef`; Mojo `1.0.0 (ed45d567)` on macOS ARM64.
Plan: [source port](../plans/2026-10-30-formula-payload-source-port.md).

## Implemented behavior

Native/Python/Arrow formula queries now traverse stored objects, array indexes
and wildcards with the shared Qdrant JSON-path port. The original payload
retriever flattens arrays once unless the path ends in a wildcard. No retrieved
values use a default, exactly one supplies the value, and multiple form a
nonnumeric array. Null and wrong types do not trigger defaults. JSON defaults
are not flattened. UInt64 values/defaults are converted through F64 like
serde_json::Value::as_f64; nonnumeric score defaults remain zero.

Formula defaults accept all bounded JSON values, including unused object/array/
null values. Native validation and the shared Python-to-native converter enforce
65,536 aggregate value nodes, 16 MiB content including names and 64 container
levels per default, in addition to existing expression/query budgets. The root
DocumentField map is not wrapped in another container, preserving depth-64
stored field values. Python only converts inputs; scoring remains native.

## Independent source evidence

`scripts/qdrant_formula_payload_reference.py` compiles **15 extracted unchanged
units** plus Qdrant's original parser from
`74f3e85b9473c62560006c043e13737ce6b48412`:

- JSON-path structs, get traversal, wildcard-suffix check and display.
- Formula variable parsing, authoritative payload retriever, score/evaluation,
  payload/default selection and decay functions.

The provider/counter/MultiValue/expression/error wrappers are documented adapters.
Real serde_json 1.0.151 (preserve_order), nom 8.0.0 and serde 1.0.228 replace the
old scalar oracle's simplified values. Cargo.lock fixes reference dependencies;
there is no new runtime Rust dependency. Geo/date/typed indexes are not exercised.

The resulting **1,068 cases** include **458 expected errors**. Expected F32 bits
and errors come exclusively from the compiled upstream evaluator. Native and
actual public Python/Arrow calls check every case. The older **309 scalar cases**
remain unchanged and pass their existing native/Python tests.

Five upstream file hashes, the compiled scaffold hash and Cargo.lock hash were
verified independently against the fixture. The port registry records current
implementation/test/script hashes and the fixture hash.

## Commands and results

All heavy builds/tests ran serially.

| Command (all prefixed with `rtk proxy`) | Result |
| --- | --- |
| `python3 scripts/qdrant_formula_payload_reference.py` | Release oracle built; 1,068 cases / 15 extracted units |
| `pixi run mojo run -I src tests/mojo/test_formula_payload.mojo` | 3 passed |
| `pixi run mojo run -I src tests/mojo/test_formula.mojo` | 4 passed |
| `pixi run mojo run -I src tests/mojo/test_universal_query.mojo` | 5 passed |
| `pixi run build-python` | Passed |
| `pixi run env PYTHONPATH=python:. pytest tests/python/test_formula_payload.py tests/python/test_formula_query.py tests/python/test_formula_paths.py -q --tb=short` | 933 passed, 2 existing warnings; 7.59 seconds |
| `pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` | **3,092 passed, 1 optional skip, 3 existing warnings**; 71.68 seconds |
| `git diff --check` | Passed |

There are 18 new Python tests. Four former rejection parameters were removed
because nested paths and JSON defaults are now supported; positive/default/error
behavior is covered by the source oracle and new tests. The 548 existing path
parser cases now accept nested paths instead of asserting the old rich-value gap.

Public integration covers actual point writes, path payload mutations, WAL-only
and checkpoint reopen, nested query nodes, owned Arrow results after close,
normalized defaults, maximum-depth fields/defaults, cycles/nodes/bytes/type
limits and mapping-conversion owner closure. Native tests also retain an old
payload snapshot across mutation and writer close while a reopened writer sees
the new state. Existing universal-query tests cover cancellation and budgets.

## Failures retained

The first new native run failed both cases on the old explicit rejection of
nested/array formula values, before implementation. During implementation, one
compile attempt incorrectly called a nonexistent FormulaVariable.display;
using its existing parsed path/index representation fixed it. Final native,
binding and Python verification above ran after that correction. No tests or
source cases were dropped to suppress a failure.

## Remaining scope

This verifies Qdrant's **payload-backed** numeric formula retrieval, not full
typed-index selection/coercions, full condition schemas, geo/date formulas or
REST/gRPC compatibility. Those remain Q04/D03/A01/A02. Rich Arrow payload columns,
all other D/C/L/R/U/S/X/O rows, Q04 sampling/feedback and full product acceptance
remain open. No durable format, recovery engine, C ABI or GPU implementation
changed; their separate suites were not rerun for this read-path integration.
Native Linux remains deferred. M5/M6 and recommendation recall failures remain;
no performance experiments or acceptance gates were resumed.
