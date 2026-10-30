# D01c4f: native/Python/Arrow Lance JSON consumers

Base: `66a7f98`; Mojo `1.0.0 (ed45d567)`. All eleven consumer operations now
execute in Mojo and are publicly usable on a JsonbValue or nullable Arrow
LargeBinary array through `akashadb.json_functions`. The complete 49-package
product scope and feature-before-optimization order remain unchanged.

## Source and delivered behavior

Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` supplies
`lance-arrow/src/json.rs` and `lance-datafusion/src/udf/json.rs`.
jsonb 0.5.6 `functions/path.rs` and `core/databend/util.rs` supply exact owned
key/index access. Existing native selector, writer, Number and scalar-cast ports
are reused; no alternate query/numeric algorithm or runtime package is added.

- Arrow `JsonArray::json_path`: full selection, render first match.
- DataFusion `json_extract`, `json_extract_with_type`, `json_exists`.
- `json_get` and nullable `json_get_string/int/float/bool`.
- `json_array_contains` and `json_array_length`.
- Exact object-key/unsigned-array-index lookup and source storage type tags.
- Native row null/broadcast/error behavior and typed Arrow output; Python
  supplies primitive transport and validates Arrow structure/UTF-8.

`LanceJson` is the native API; public Python functions are named like their
source consumers. Typed extraction preserves binary bytes separately from its
source tag; storage null/missing differs from selected JSON null. Float storage
remains Float64, while exact integral Decimal/UInt64 within range may be Int64.
Extensions keep their bytes with String tags. Typed extraction returns a
non-null struct with nullable value and non-nullable UInt8 type_tag.

Multi-match extraction wraps an array, unlike first-text selection. Array
contains compares rendered element strings and a deliberately unescaped quoted
needle. Array length returns **0 for valid nonarrays**, and null for missing
paths; the actual source code overrides its misleading UDF comment. Integer
keys use exact Rust unsigned decimal parsing, not rounded scalar casts.

See [public contracts/examples](../native-jsonb.md#lance-json-functions).

## Independent oracle and adaptations

The full original Lance Arrow module is compiled, with an appended constructor
adapter to supply raw LargeBinary storage. Twenty-six original DataFusion-file
functions are extracted unchanged, including all ten Arrow row implementations.
The harness supplies only an Execution error carrier and outer dispatch instead
of compiling the DataFusion engine. Source revision/file/function/dependency/
license/input hashes are retained. `json_path` vectorization and nullable path
broadcast are outer transport around the original per-row Arrow method, not a
claim that Lance defines an eleventh SQL UDF.

| Evidence | Count |
| --- | ---: |
| Input scenarios | 47,223 |
| Consumer operation outcomes | 216,337 |
| Original successes / errors / panics | 202,761 / 13,312 / 264 |
| Exact successful outcomes in existing native input bounds | 202,759 |
| Exact original error messages in those bounds | 13,308 |
| Over-depth original wrapped inputs / affected outcomes | 2 / 6 |

The two source wrappers produce 65-level input bodies, exceeding the existing
64-level codec contract. Their two original successes and four original errors
remain in fixtures with an explicit input-limit annotation; native/public tests
require the existing depth rejection. Original panics become native errors.
No original input/result is silently dropped or used to loosen format limits.

Coverage includes all 29,003 writer bodies, codec/legacy values wrapped by source
constructors, explicit and sampled selector scenarios, exact Unicode/dotted/
empty/numeric keys, nullable broadcasts, sliced arrays, malformed masked bodies,
missing paths and ordered batch failures. Binary outputs compare exact bytes;
floats compare IEEE bits; error strings match source at the consumer boundary.
The existing parser keeps its detailed diagnostics internally while these
consumer interfaces expose the source InvalidJsonPath contract.

Native per-row traversal/consumer budgets, batch input/output/row caps,
cancellation and deadlines are checked. Repeated source index scans charge work
for every visit; null output slots also consume budget. Native getters return
owned values, and errors do not mutate collections. Arrow transport currently
materializes primitive lists; no zero-copy or performance claim is made.

## Validation

- New native consumer suite: **3 passed**, including the full source corpus,
  independently owned results and budgets/cancellation/deadlines.
- Codec (6), path (3), selector (5), casts (4), writer (4): **22 passed**;
  **25 native tests** total.
- `pixi run build-python`: passed for the final native/binding sources.
- New public Python suite: **18 passed**. Combined boundary/reentry suite:
  **178 passed**, including original source Arrow results, null and type
  contracts, corruption, resource limits and WAL/checkpoint reopening.
- Full Python: **3,716 passed / 1 skipped** (existing optional pinned Qdrant
  benchmark dependency). Command: `PYTHONPATH=python:. pixi run python -m pytest
  tests/python -q`, on the rebuilt kernel.
- Cases, source metadata and Cargo.lock reproduce byte-for-byte.

The first full Python invocation omitted the environment configured by the
project's `test-python` task. All 162 failures were isolated subprocess imports
of `akashadb`; running with `PYTHONPATH=python:.` resolves them without changing
production behavior or skipping tests. The failed log/XML is retained.

A focused failing test exposed a raw UnicodeDecodeError for an invalid Arrow
Utf8 buffer. The boundary now runs Arrow full validation before materialization
and maps the failure to ValidationError; that test and the full suite pass.
Earlier native compile/test diagnostics, the source error-message correction,
and a test expectation corrected for the earlier Arrow input-byte guard are
retained under `.build/lance-json-functions-validation/`.

## Remaining product work

Integrate these source functions into native collection JSONB filtering and
projection, then dedicated query indexes and remaining C/distributed boundaries.
SQL UDF registration/execution requires the real SQL layer; the oracle error
carrier is not a DataFusion/SQL engine implementation. Lance storage format,
versions/schema/object storage, general SQL/transactions, full protocols/UI/
security/cluster/ops and all other master packages remain open. No durable
format changed; existing crash acceptance remains applicable to this read-only
API. M5/M6 optimization is still deferred, and native Linux acceptance remains
deferred by the user's instruction.
