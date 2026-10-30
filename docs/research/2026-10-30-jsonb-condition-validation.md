# JSONB collection filter integration

Base: `093340a`. Port/integration ID: `D01c4g-jsonb-collection-filters`.
This adds an Akasha collection-filter leaf using the already source-ported
jsonb predicate selector and Lance `json_exists`, `json_get_bool`, and
`json_array_contains`. Selection, casting and comparison remain in Mojo.
It is not a new Qdrant wire condition or a SQL implementation.

## Source and public contract

- jsonb 0.5.6 selector: provenance and unchanged source expectations from
  `tests/fixtures/jsonb-selector/{cases.json,sources.json,Cargo.lock}` and
  port `D01c4c-jsonb-selector`.
- Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
  `rust/lance-datafusion/src/udf/json.rs`, especially the existing boolean
  consumers at lines 451, 736 and 793. Reuses `D01c4f-lance-json-functions`.
- Lance dataset SQL tests at `rust/lance/src/dataset/sql.rs:578` and `:594`
  demonstrate JSON functions inside real SQL filter/projection expressions.
  Akasha composes these functions with its existing filter tree here; the
  DataFusion SQL engine itself has not been ported.
- Source fixture/metadata/lock/README hashes for both prior ports were checked
  unchanged (eight files). Their recorded source-generation validation remains
  applicable; this integration does not regenerate or edit their expectations.

See [API and limits](../native-jsonb.md#collection-jsonb-filters). A Qdrant-style
payload path selects JSONB carriers; a separate JSONB argument drives the source
function. Missing/storage-null values do not match. Source unknown/null boolean
results match only true. Visited ordinary payload values are errors. JSONB null
remains distinct from storage null. Existing outer Boolean semantics apply.

Configuration is validated before iteration/writes, including empty collections.
This intentionally differs from scalar/Arrow null-row parsing short circuits.
`json_get_bool` accepts exact keys, including empty strings, instead of paths.
Per-carrier budgets reuse the selector/Lance limits; they are not cumulative
collection budgets. Outer query checkpoints remain, without new mid-leaf
cancellation plumbing. No persisted format or sequence semantics change.

## Independent source outcomes

`tests/mojo/test_jsonb_condition.mojo` checks both direct evaluation and the
metadata bitmap path against the existing original-source expectations:

| Source operation | Outcomes | Source successes | Source errors/panics |
| --- | ---: | ---: | ---: |
| jsonb predicate_match | 64,850 | 61,575 | 3,275 errors |
| Lance boolean consumers | 46,250 | 39,316 | 6,933 errors, 1 panic |
| Total | 111,100 | 100,891 | 10,209 |

The Lance subset has 34,453 exists, 6,347 boolean-get and 5,450 contains results.
Successful results are checked after mapping nullable booleans to filter matches;
failures must raise on both paths. Error messages are not claimed identical:
the filter's eager configuration validation exposes native parser diagnostics.
The source panic is mapped to an error.

Only single stored body/single non-null argument cases apply to this filter
contract. Raw-byte parser rejection rows, Arrow empty/broadcast/null-mask shapes,
two previously documented over-depth input wrappers and null needles remain
covered by their original suites, rather than being counted as collection
filter inputs. No source outcomes were modified.

## Integration checks and discovered correction

The public suite covers exact/HNSW/IVF, sparse/hybrid/default/named searches,
batch filters, universal/formula queries, Arrow results, scans, nested/wildcard
payload paths, existing HTTP search/update routes, WAL/checkpoint reopen,
snapshot isolation, and set/overwrite/delete/clear payload operations.
Strict configuration and runtime-budget failures leave mutation sequences
unchanged; data-type errors also preserve WAL bytes and all point payloads.

A failing native regression demonstrated that independently evaluating bitmap
leaves visited invalid JSONB values which direct Boolean short circuiting had
masked. Expressions containing JSONB now use the existing metadata plain
checker for the entire expression. This preserves row-local all/any/not order
and the authoritative stored values. Dedicated JSONB indexes remain pending.
The native regression and a public search/scan/update regression cover both
masked errors and errors in a deliberately evaluated first branch.

Retained failures under `.build/jsonb-condition-validation/` include the missing
native/public feature, the bitmap short-circuit defect, and initial test-only
mistakes: copying non-Copyable document fields, using legacy vector `get` for
vectorless points, and expecting HTTP 422 instead of the existing 400 contract.

## Final verification

Final commands, hashes, source-fixture reuse checks, JUnit counts and retained
failure logs are recorded in `.build/jsonb-condition-validation/results.json`.

- `pixi run mojo run -I src tests/mojo/test_jsonb_condition.mojo`: **5 passed**.
- Eight native regression modules (AST, evaluator, expression, metadata index,
  payload/point predicates, scanner and persistent filters): **54 passed**.
- `pixi run build-python`: passed on the final runtime source.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python/test_jsonb_condition.py -q`:
  **23 passed**.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python -q`:
  **3,739 passed, 1 skipped**, zero failures/errors. The skip remains the
  optional pinned Qdrant benchmark dependency. Existing Python extension and
  Starlette deprecation warnings remain.

No durable codec, WAL publication or recovery implementation changed. Existing
crash-format evidence remains applicable; this slice additionally verifies
conditional-update error atomicity and WAL/checkpoint reopen through public APIs.

## Remaining work

Computed collection JSONB projections, dedicated JSONB indexes, SQL execution,
full C/distributed/protocol integration, arbitrary top-level keys and all other
master-ledger capabilities remain open. The full 49-package objective is not
complete. No benchmark tuning or optimization was performed; M5/M6 remain
unmet and native Linux acceptance remains deferred.
