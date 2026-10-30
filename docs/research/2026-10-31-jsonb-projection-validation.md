# Native JSONB computed scanner projections

Base `4080799`; integration ID `D01c4h-jsonb-scanner-projections`.
This completes the eleven-function computed scanner layer described in the
[plan](../plans/2026-10-30-jsonb-projection.md), using the same source-ported
Lance/jsonb consumers as the value and collection-filter APIs.

## Implementation and source boundaries

`LanceJsonResult` preserves owned nullable text/binary/scalars and the source
typed-extraction tag. A shared native dispatcher now serves both the existing
scalar/Arrow Python functions and computed projection; their duplicated call
dispatch was removed. No selector, numeric cast, string writer or traversal
algorithm was replaced.

`JsonbProjection` compiles a bounded sequence of nested JSONB function calls.
Input is an exact stored field name; intermediate values are source `json_get`
JSONB outputs. The new scanner column calls it over the captured native batch
and builds final Arrow C Data buffers using existing ownership/release/budget
helpers. Python only transports configuration and constructs schemas. There is
no Python row materialization or Python expression evaluator in this path.

The result deliberately does not use persisted `PayloadValue` floating fields:
those prohibit nonfinite values, while the source float function can return
NaN/Infinity. The result and Arrow Float64 preserve source bits, including
signed zero. Typed extraction preserves its non-null struct and nullable binary
child; storage null, missing and JSONB null remain distinct where the source
distinguishes them.

Source remains Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-arrow/src/json.rs` and `rust/lance-datafusion/src/udf/json.rs`, with
the pinned jsonb 0.5.6 dependency. Reuses `D01c4f-lance-json-functions`,
`D01c4c-jsonb-selector`, and existing Arrow buffer ownership code. Source
cases/provenance/Cargo.lock/README hashes were checked unchanged; their prior
successful source-generation evidence remains applicable.

This integration is not DataFusion SQL execution. Arguments are constant
strings/null, aliases are Akasha scanner columns, and non-null path syntax is
validated eagerly. Column-valued arguments, arbitrary SQL expressions,
computed document-record projections and complete C/distributed/protocol APIs
remain pending. See [public contract and limits](../native-jsonb.md#computed-jsonb-scanner-columns).

## Source outcomes and public verification

The new native expression test checks **215,780 original-source scalar
outcomes** across all eleven operations: **202,342 successful values**, **13,174
errors**, and **264 source panics mapped to errors**. Exact text, JSONB bytes,
F64 bits, scalar/null values and type tags are checked. Error cases must raise;
eager parser error wording is not claimed identical to the source UDF wrapper.

The selected input contract is one valid stored body and one non-null constant
argument (and non-null needle for contains). Other source Arrow broadcast,
empty/null-mask shapes and the two previously documented over-depth input
wrappers remain covered by the existing consumer suite, not counted as new
scanner expression inputs. No expected source results changed. The existing
consumer suite additionally verifies the shared dispatcher across its original
216,337 outcomes.

Public tests cover all output types, null structs, nested get calls, source
NaN/Infinity/signed-zero behavior, schema on empty scans, filtering before
projection, snapshot capture across updates/close, owned slices, WAL/checkpoint
reopen, strict configuration/alias limits, per-call budgets, separate row and
JSON work budgets, shared final-buffer limits, intermediate-cell limits,
cancellation/deadline failures, and late-row errors closing the scanner without
returning a partial batch. A Python callback closing the collection during
native configuration is rejected before snapshot acquisition.

Retained red/fix logs under `.build/jsonb-projection-validation/` include missing
native/public functionality, a non-Copyable field iteration correction, a test
bitcast import correction, early null propagation incorrectly skipping an inner
call's error, and direct binding aliases bypassing Python name validation.
Native alias validation and inner-to-outer evaluation now have regressions.

## Verification status

All commands are terminal and successful; command/JUnit/hash evidence is in
`.build/jsonb-projection-validation/results.json`.

- `pixi run build-python`: final kernel build passed.
- New native projection test plus source consumer/selector/scanner modules:
  **16 native tests passed**, including the 215,780-outcome expression oracle.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python/test_jsonb_projection.py tests/python/test_lance_json_functions.py tests/python/test_arrow_scanner.py tests/python/test_rich_arrow_scanner.py -q`:
  **104 passed**, including **13 new projection tests**.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python -q`:
  **3,752 passed, 1 skipped**, zero failures/errors. The skip remains the
  optional pinned Qdrant benchmark dependency. Existing extension/Starlette
  deprecation warnings remain.

No durable format or writer/recovery implementation changed. Existing crash
validation remains applicable; new public checks exercise captured generations,
WAL/checkpoint reopen and read-only error behavior.

## Remaining work

Lance's dedicated JSON index implementation is located at
`reference/lance/rust/lance-index/src/scalar/json.rs`; it includes type inference,
conversion, query matching, index training/update and persistence. These are
not implemented by the computed projection layer. The full 49-package ledger,
M5/M6 and deferred native Linux acceptance remain open. No optimization or
performance retuning was performed.
