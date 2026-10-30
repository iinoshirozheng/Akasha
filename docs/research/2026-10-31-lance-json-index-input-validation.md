# Lance JSON Index Input Validation

Date: 2026-10-31. Baseline: `4f1cafe`. Mojo `1.0.0 (ed45d567)`.

The native index input layer now executes Lance's extraction, first-non-null
batch type inference, whole-batch tag validation and strict typed conversion.
It is a verified dependency for the actual JSON index, not a completed
collection index. The remaining target, planner and durable lifecycle work is
tracked in the [index plan](../plans/2026-10-31-lance-json-index.md).

## Source and behavior

Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` supplies
`infer_type_from_batch`, `validate_json_types`, `convert_batch_by_type` and its
JSON UDF extractor. Actual jsonb 0.5.6 `core/databend/de.rs` supplies strict
Serde conversion. The source generator extracts original function bodies
unchanged, executes real Arrow/jsonb crates, and adapts only error carriers,
visibility and input/output transport. The full planner/target/stream is not
compiled by this harness.

Native `akasha.index.lance_json_input` reuses the existing LanceJson selector,
JsonbNumber, extension formatter and owned LanceJsonResult. It preserves:

- First non-null type, without widening based on later rows. Float64 accepts
  Int64 tags; Int64 rejects Float64 tags. All-null batches return no inference.
- Type validation for the entire batch before any value deserialization.
  A later tag mismatch takes precedence over an earlier conversion error.
- Binary-null masks missing/invalid tags during conversion; inference reads
  tags independently and stops before inspecting later rows once it has a type.
- Strict bool/integer/float/string deserialization. Decimal carrying an Int64
  tag can still fail Int64 deserialization; permissive JSONB casts are not used.
- Exact text, integer, boolean and binary results, Float64 bits including
  NaN/Infinity/negative zero, and source extension formatting.
- Row order, owned output values and no returned partial batch on failure.

Native resource extensions bound a batch to 65,536 rows and default 64 MiB of
fixed result cells plus owned output bytes. Callers may set the byte bound.
Directly sized text, binary and hex copies are checked before allocation;
time/interval formatted text has a bounded fixed representation. These are
allocation bounds, not a whole-process peak-RSS claim. Existing JSON selection
limits remain in force; cancellation/deadline state is shared while JSON work
and batch row limits remain separate.

## Evidence

The committed fixture contains 6,481 scenarios, including every one of the
6,331 source codec/legacy bodies and 150 multi-row/type-mask cases.

| Source result | Count |
| --- | ---: |
| Successful conversions | 7,767 |
| Conversion errors | 24,616 |
| Source conversion panics mapped to native errors | 22 |
| Total conversion comparisons | 32,405 |
| Successful inference (including no inferred type) | 6,456 |
| Inference errors | 25 |

Successful outputs and nonpanic error messages match exactly. All extracted
bytes and nullable tags match. The Rust harness also checks passthrough row IDs;
the Mojo converter preserves row order, with actual row-ID column transport
reserved for the future training caller.

Commands completed successfully:

```text
rtk proxy python3 scripts/lance_json_index_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_index_input.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json.mojo
```

Five new native tests and three existing consumer tests pass. New tests cover
mixed-type order, batch error precedence, strict conversion, masks, exact byte
limits, row cap, cancellation, fixed target-type rejection and owned results.
The existing Lance consumer test retains its original 216,337 source outcomes.
Re-running the source generator reproduces cases, metadata, lock and README
byte-for-byte. Detailed commands/hashes/logs are retained under
`.build/lance-json-index-validation/`; durable provenance is in the fixture
`sources.json` and `docs/upstream/ports.json`.

The red test first failed because the new native module was absent. The initial
Rust harness used a nonexistent convenience parse API; it was corrected to
jsonb's actual `parse_value` before producing any expected results. No source
algorithm was changed to accommodate the port.

## Scope and next work

No application runtime module imports this new dependency yet. Existing public
Python/HTTP/Arrow runtime and durable formats are unchanged; the prior verified
kernel and Python **3,752 passed / 1 skip** results remain applicable and were
not relabeled as a fresh full run. No persistence/crash gate is claimed here.

Streaming prefix buffering/default Utf8, sorting, target index training/search,
nullable result sets, query matching, create/list/drop/update/remap, durable
catalog publication/recovery and Python/Arrow/service exposure remain open.
Native converted values are ready for those source-backed consumers; there is
no temporary scan fallback presented as an index. All 49 full-product packages,
M5/M6 and deferred native Linux acceptance remain open. No optimization.
