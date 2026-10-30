# Original Lance JSON-index input oracle

Reproduce with `rtk proxy python3 scripts/lance_json_index_reference.py`.
The Lance revision is `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`.

The unchanged `infer_type_from_batch`, `validate_json_types` and
`convert_batch_by_type` methods from `rust/lance-index/src/scalar/json.rs`
execute against real Arrow arrays and jsonb 0.5.6's actual Serde deserializer.
The original `extract_json_path_with_type`, path helper and JsonbType enum
produce the selected bytes and tags. Error carriers, entry-point visibility,
array transport and panic capture are harness adapters. There is no generated
expected converter/inference algorithm.

6,481 scenarios include all 6,331 existing source codec/legacy bodies plus
multi-row ordering, null and deliberately inconsistent validity/tag cases.
There are 32,405 conversion outcomes: 7,767 successes, 24,616 errors and 22
source panics mapped to native errors. Inference has 6,456 successful outcomes
(including no inferred type) and 25 errors. Successful binary/text/bool/integer
results and F64 bits match exactly; source nonpanic errors also match exactly.
The source harness verifies passthrough row IDs remain in their input order;
the native input converter retains row order and leaves column transport to its
future index caller. It does not yet implement that collection caller.

The methods validate all type tags before attempting any conversion. Numeric
inference uses the first non-null tag without widening. Integer-tagged Decimal
can still fail strict Int64 deserialization; general JSON casts are unsuitable.
Binary-null masks tag errors in conversion but does not mask tags in inference.
Array/object targets preserve raw bytes; extension String conversion follows
the source formatter, including its bounded error mapping for source panics.

The metadata records exact source/method/dependency/archive hashes, toolchain,
input corpus, generator/scaffold, Cargo.lock and generated cases. Existing
Apache-2.0 notices are under `docs/upstream/licenses`. No runtime dependency is
added. This does not execute the target index, DataFusion planner, streaming
training, sorting, persisted index lifecycle or full Lance format.
