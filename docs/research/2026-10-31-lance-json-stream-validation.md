# Lance JSON Bitmap Training Stream Validation

Date: 2026-10-31. Baseline: `f494a3d`. Mojo `1.0.0 (ed45d567)`.

The native JSON input and bitmap target now form an incremental training,
update, rebuild, search and remap path. JSON batches are extracted and typed
in source order; a complete index becomes available only after successful
finish. This remains a materialized native index, without collection catalog,
planner selection, disk publication or public Python index management yet.

## Source-backed behavior

Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-index/src/scalar/json.rs`, defines the flow:

- `extract_json_with_type_info` buffers only through the first batch whose
  first non-null tag supplies a type; it recreates the stream from that prefix
  followed by the unconsumed input. Only end-of-stream defaults to Utf8.
- `convert_stream_by_type` converts each batch using the fixed target, retaining
  whole-batch tag validation before row conversion and preserving row locations.
- `train_index` distinguishes initial inference from a provided learned type;
  sorting occurs on converted path values, not raw JSON.
- `update` uses the existing target's training type, and `derive_index_params`
  carries that type into rebuilds. Remap/search delegate to the target while
  the wrapper retains its path.

The new `LanceJsonBitmapTrainer` is a single-consumer push/finish adaptation
for Mojo. It buffers owned extracted JSON and IDs until a type is found, flushes
that prefix through the existing source converter, and converts later batches
immediately. Converted keys are retained under a separate bound for the
source-ported bitmap target's value sort. It does not retain the rest of the
input as raw JSON or silently widen an inferred Int64 to Float64.

`finish` creates a new `LanceJsonBitmapIndex`; `index.trainer()` preserves the
path, learned type and target limits for an update or rebuild. `finish_update`
requires the old path/type and delegates old-row filtering and sorted merge to
the verified target. Empty/all-null rebuilds retain their supplied type.
`search` delegates nullable predicates and `remapped` preserves the path/type.

Any extraction, conversion, budget, cancellation or final target-build failure
closes the trainer and clears staged logical data. Reusing a closed trainer is
an error. An explicit `abort` lets a caller discard it if its input reader fails.
Neither failure nor success mutates an old index; no WAL/catalog writes occur.

## Original-source oracle

The new Rust oracle executes unchanged original methods for batch inference,
prefix inference/reconstruction, validation, batch conversion and lazy stream
conversion. It also calls the original JSON UDF extractor. Real Arrow 58.4.0,
jsonb 0.5.6 and futures 0.3.32 provide arrays, JSONB and stream polling.

The extraction projection and RecordBatchStream adapters replace DataFusion
transport, and error carriers preserve unadorned inner messages. They do not
replace inference or conversion logic. Actual DataFusion physical execution,
sort/spill and the plugin registry are not executed by this oracle. The full
`train_index`/`update` methods were inspected for orchestration; their complete
durable execution is not claimed as oracle coverage.

| Original-source scenarios | Count |
| --- | ---: |
| Total | 786 |
| Successful streams | 593 |
| Conversion-stage errors | 188 |
| Inference-stage errors | 5 |
| Batches in successful streams | 2,842 |
| Converted rows in successful streams | 2,283 |

Native checks compare inferred/fixed type, first-useful-prefix batch count,
consumption through errors, exact inner error messages, final value/UInt64-ID
correspondence and total posting cardinality. All recorded successful rows
reach the actual native bitmap target. Source partial conversion output before
errors stays in fixtures for evidence; native construction discards staging,
so no partially built index is returned.

The oracle separately records row addresses and their preserved Arrow columns.
This slice's native bitmap trainer accepts UInt64 IDs, not arbitrary Arrow
passthrough columns, so it does not claim a native generic Arrow stream schema.

Cases cover empty/all-null prefixes and streams; first Int64 versus first
Float64; all five learned targets; Boolean false; nonfinite floats and signed
zero; strings/arrays/objects; selected/missing/multi-match paths; invalid paths
and lazy errors; and high/maximum UInt64 IDs. Additional native tests exercise
prefix release, fixed-type update/rebuild, nullable search, remap, empty update
filters, aggregate budgets, cancellation, abort, path/type mismatch and failure
during the final index build while the old index remains usable.

## Validation and reproducibility

Five new native tests and ten existing bitmap/input tests pass (**15 total**):

```text
rtk proxy pixi run python scripts/lance_json_stream_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_stream.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_bitmap.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_index_input.mojo
```

The missing-module red test preceded implementation. The generator's initial
function extractor did not recognize async methods; reusing the existing async
source extractor fixed that without changing any original source method.
All four fixture/provenance files reproduce byte-for-byte, and the final cases
are identical to those used for native verification. Source files, methods,
extracted crate sources/archives, Cargo.lock, compiler and final code hashes
are recorded. `.build/lance-json-stream-validation/results.json` retains local
commands/logs/hashes; committed evidence is in the fixture and port registry.

No application runtime or durable format changed. The prior full Python
**3,752 passed / 1 skip** evidence is reused, not reported as a new test run.

## Resource bounds and remaining work

Each input batch retains the existing 65,536-row bound. The trainer defaults
to one million rows across all pushes and 64 MiB separately for the extracted
prefix and converted row/key storage. Empty prefix batches count their owned
descriptors, preventing an unbounded list of empty batches. Path bytes have a
65,536-byte cap. Existing per-call extraction/conversion and target limits also
apply. These logical bounds exclude allocator capacity, existing caller data,
temporary converted batches, prefix/converted overlap during flushing and the
target's sort/merge copies; they are not peak-RSS guarantees.

QueryControl checks aggregate input count, each push/finish and the existing
extraction/conversion/target checkpoints. The bounded standard sort remains
checked before/after, not internally cancellable. The caller must call finish
only at EOF, or abort on a reader failure; push does not infer EOF from an empty
batch. All-null streams can buffer their entire bounded input before defaulting,
as the original algorithm does.

Next: exact function/path matching, residual predicates and planner integration,
then the authoritative catalog/index-definition migration and public durable
create/list/drop/update/rebuild/backup/recovery path. Source external sort/spill,
disk-backed streaming publication, shard merging, file/cache support, generic
Arrow passthrough and other scalar targets remain open. All 49 full product
packages, M5/M6 and deferred Linux acceptance remain open. No tuning.
