# Original Lance JSON consumer oracle

Reproduce with `pixi run python scripts/lance_json_functions_reference.py`.
The pinned Lance checkout is `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`.

The full original `lance-arrow/src/json.rs` is compiled with an appended
constructor adapter for supplying raw LargeBinary storage to JsonArray.
Twenty-six original functions from `lance-datafusion/src/udf/json.rs` are
extracted byte-for-byte, including all ten public UDF Arrow row implementations,
shared null/broadcast/type validation, selection, casts and array operations.
Only DataFusion's Execution error carrier and outer operation dispatch are
supplied for these UDFs by the harness. The eleventh operation vectorizes the
original per-row `JsonArray::json_path`; its nullable path/broadcast wrapper is
outer transport, not an additional original Lance SQL UDF.
SQL registration, ColumnarValue scheduling and the
DataFusion query engine are not compiled or claimed.

`cases.json` retains 47,223 scenarios and 216,337 operation results, including
202,761 source successes, 13,312 source errors and 264 source panics. It includes
all 29,003 writer bodies, codec/legacy bodies wrapped by original constructors,
explicit and sampled selector scenarios, numeric/Unicode/literal keys,
broadcast/null/sliced arrays, missing fields and batch failure ordering.
Binary results compare bytes; floating results compare IEEE bits. Type tags
are produced by original Lance code, not inferred by the generator.

Two original wrapped inputs exceed Akasha's established 64-level binary depth
limit (six operation results). They retain their original outcomes and an
`input_limit` annotation; native/public tests require rejection instead of
weakening the existing codec limit. Source panics become bounded native errors.

Metadata pins source files, the exact extracted function units, dependency
source/archive checks, compiler identity, input corpus hashes and generated
files. Existing dependency license notices remain under `docs/upstream/licenses`.
No runtime dependency is added. This is a function/Arrow oracle, not full Lance
format, SQL, collection predicate/index or product equivalence acceptance.
