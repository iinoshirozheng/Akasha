# JSONB Computed Projection Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Execute all eleven source-backed Lance JSON functions as collection scanner computed columns, retaining source output types, nulls and errors.

**Architecture:** Add an owned native result and shared function dispatcher over existing LanceJson methods. A bounded unary JSONB expression compiles nested calls into native steps, sourced from an exact payload column. The existing scanner exports computed results through its Arrow C Data ownership/budget machinery. Python transports configuration and constructs schemas only. Nonfinite F64 output is preserved independently of persisted PayloadValue's finite-only rule.

**Tech Stack:** Mojo 1.0.0, existing Python/PyArrow/C Data, pinned Lance ad2ee27f and jsonb 0.5.6 ports. No new dependency, source algorithm or durable format.

---

## Contract

`scan_record_batches(..., json_columns={alias: expression})` adds computed columns.
An expression is `{function, input, argument, needle?}`. Input is an exact
stored JSONB field name or another expression returning JSONB (`json_get`).
Arguments/needle are constant strings or null; needle is required only for
contains. Unknown properties and non-JSONB intermediate types are rejected.
The outer expression accepts max_work/max_results/max_bytes with existing
source defaults. At most 16 function steps, 256 computed columns, 65,536 UTF-8
bytes per argument; aggregate configuration remains bounded by ordinary JSON
transport. Invalid non-null paths are eager configuration errors, even for
empty/null input. Null arguments are valid source nulls. Missing/storage-null
input returns source null; typed extraction returns non-null struct with null
value/tag 0. Visited ordinary payload types error. JSONB null remains a value.
Output types match existing source functions: Utf8, LargeBinary, Boolean, Int64,
Float64, or Struct(value: nullable LargeBinary,type_tag: nonnullable UInt8).

The core does not route results through persistent payload fields: source F64
NaN/Infinity and exact owned JSONB bytes must survive. Native output buffers and
bounded intermediate cells own their data. Scanner errors close the cursor;
returned batches survive scanner/collection close. Query deadline/cancellation
are passed through each source call; row candidate budget and JSON work budget
remain separate. Bound output buffers with max_batch_bytes and separately bound
intermediate fixed cells plus owned string/binary bytes to that batch limit.
Per-call source limits remain in force through nested calls.

## Task 1: Native result and expression

Create `src/akasha/document/lance_json_result.mojo` and
`src/akasha/query/jsonb_projection.mojo`; export the native expression/result.
First create `tests/mojo/test_jsonb_projection.mojo` and confirm missing-feature
failure with `rtk proxy pixi run mojo run -I src tests/mojo/test_jsonb_projection.mojo`.
Then implement native ownership, all 11 function outputs, nested json_get,
strict configuration, null and nonfinite cases, source fixture comparisons and
controls. Reuse the dispatcher in `src/bindings/lance_json_python.mojo` instead
of retaining duplicate call dispatch. No parser/cast/selector reimplementation.

## Task 2: Scanner C Data projection

Create `src/bindings/arrow_jsonb_export.mojo`; modify ArrowColumn/schema/export
in `src/bindings/arrow_export.mojo` and scanner configuration in
`src/bindings/python_module.mojo`. Modify `python/akashadb/arrow.py` to transport
json_columns. Add `tests/python/test_jsonb_projection.py` before rebuilding;
verify missing-argument failure against the old kernel. Export all output types
with existing ArrowArrayExport/_ArrayData/_BufferBudget, including typed
extraction children. Test schema, source values/bits/nulls, empty scans, chained
calls, all final-buffer and intermediate limits, late-row errors, filter before
projection, captured generations, ownership, cancelled/deadline scans, and
strict direct binding/reentry boundaries. No Python row staging.

## Task 3: Verification and record

Run the native new test and related consumer/selector/scanner/Arrow lifetime
checks sequentially. Rebuild with `rtk proxy pixi run build-python`. Run targeted
Python tests then full `tests/python` using PYTHONPATH=python:. Validate unchanged
source fixture hashes; reuse existing successful source generation evidence.
Record exact scope, source oracle counts, commands, hashes and retained failures
in a validation report and `.build/jsonb-projection-validation/`. Update public
usage, source registry, task.md and the full ledger, then commit locally only.

This is the scanner computed-column layer, not full SQL, argument-column
expressions, document-record projection, dedicated JSONB indexes or complete
C/distributed/REST/gRPC exposure. Those and all 49 complete master packages stay
open. No optimization or performance-gate retuning.

## Verified outcome (2026-10-31)

- [x] Native result/dispatcher, all eleven operations, bounded nested expressions.
- [x] Original scalar/Arrow API shares the dispatcher; duplicate dispatch removed.
- [x] Native C Data columns preserve nonfinite floats, bytes, nulls and type tags.
- [x] Strict native configuration, controls, output/intermediate budgets and ownership.
- [x] 215,780 source outcomes, 16 native tests and 104 targeted Python tests pass.
- [x] Final kernel build and full Python: 3,752 passed / 1 existing skip.
- [x] Public docs, provenance registry, report and complete ledger updated.

[Validation](../research/2026-10-31-jsonb-projection-validation.md).
Next source inspection: `reference/lance/rust/lance-index/src/scalar/json.rs`
for actual type inference/conversion, query matching, training/update and
persistence. This slice does not complete the master packages or performance
acceptance, and no optimization has begun.
