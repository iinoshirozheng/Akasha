# Lance JSON index reference matching validation

Date: 2026-11-07. Baseline: `152e092`. Mojo `1.0.0 (ed45d567)`.

The native JSON bitmap wrapper can now recognize and execute a covered typed
function predicate through `try_search`. A separate equivalence check prevents
the original matcher's path-only recognition from substituting a different value.
An unhandled predicate returns `None` and must remain in ordinary evaluation.
This is a native leaf API, not complete expression planning or a public collection
index. No application runtime, persisted format or performance setting changes.

## Original-source findings

Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` provides
`scalar/json.rs::JsonQueryParser::is_valid_reference`, the actual JSON UDFs,
and the index inference/converter. The original reference rule requires an exact
Utf8 path literal, recognizes typed getter names and `json_extract`, and returns
their declared type. It does not establish that the trained value has that type
or the same meaning. Although `json_get` is in the name list, it returns no
recognized type.

The oracle executes those original methods rather than constructing expected
values from Akasha's implementation. Concrete results demonstrate why recognition
alone cannot authorize index execution:

| Input / stored path / function argument | Indexed value | Actual function result |
| --- | --- | --- |
| `{"v":true,"$.v":false}`, `$.v`, `json_get_bool(..., '$.v')` | `true` | `false` |
| `{"v":"abc"}`, `v`, `json_extract(..., 'v')` | string `abc` | string containing `"abc"`, including quotes |
| `{"v":1.5}`, `v`, `json_get_int(..., 'v')` | Float64 `1.5` | Int64 `2` |
| `[true,false]`, `0`, `json_get_string(..., '0')` | null, default Utf8 | string `true` |
| `v` contains JSONB `date(0)`, `v`, `json_get_string(..., 'v')` | string `1970-01-01` | error `Failed to convert to string: InvalidCast` |

Typed getters use an exact object key, or parse a Rust `usize` array index.
Index training uses JSONPath. `json_extract` returns serialized JSON text;
the Utf8 target contains the extracted string without its JSON quoting. Getter
coercion also differs from strict index conversion. In addition, Serde accepts
JSONB extension values as strings while the typed getter rejects them. These are demonstrated
limitations of the pinned source reference rule, not claims about every newer
Lance version or all upstream planner execution.

## Native adaptation

`source_json_reference_type` preserves the original typed, two-argument
`function(Column, Utf8 literal)` recognition rule. Its caller must already have
bound the column and argument; it is not a general expression parser.
`json_bitmap_reference_supported` separately requires:

- The declared function type equals the index's learned target type.
- A typed getter, excluding JSON-text `json_extract` and untyped `json_get`.
- A JSONPath containing exactly one bare field whose decoded name equals the
  literal argument byte-for-byte.
- A name that does not parse as an unsigned array index. The existing source
  getter's Rust `usize` parser is reused, including its overflow behavior.
- For Utf8, training must establish that nonnull values were actual strings,
  rather than extensions converted to strings. An owned provenance flag records
  this before conversion loses the original type. Updates combine the old and
  new flags; filtering/remap conservatively retain a false flag, even when the
  offending row disappears. Only a complete rebuild can establish it anew.

Invalid or unsupported paths remain unhandled. This guard intentionally accepts
less than the original recognition helper; rejected conditions must still be
evaluated. General function-aware index definitions and safe expression rewrites
remain work, rather than being simulated by dropping a predicate.

The typed leaf rules follow `scalar/expression.rs::SargableQueryParser` and the
bitmap plugin's disabled prefix support: nullable equality/IN/range literals,
wrong target types, full-text and prefix queries remain unhandled. Empty IN,
nonnull typed comparisons/ranges and IS NULL delegate to the actual bitmap.
Optional negation uses the source-ported allow/block mask and retains unknown
rows; it does not turn SQL unknown into true. Callers must apply masks within
the index's matching live-row snapshot. `try_search` checks cancellation before
matching and passes the same control into target search.

This API does not bind or coerce SQL literals, select an index snapshot, combine
residual expressions, or replace the current Qdrant-style JSONB filter contract.
Whole-expression integration must preserve error order and branches suppressed
by per-row short circuiting. In particular, an unhandled result is not an empty
row set, and a standalone negated mask is not a snapshot universe.

## Validation

The Rust fixture uses actual Arrow 58.4.0, DataFusion common 54.1.0 ScalarValue,
and jsonb 0.5.6. Function names/arguments and unadorned error carriers replace
framework transport. Original reference recognition, extraction, typed consumers,
inference and conversion execute unchanged. Sargable leaf methods and bitmap
parser setup were inspected, not executed by this oracle; their source hashes
are recorded separately. A complete DataFusion SQL planner is not claimed.

**1,344 source scenarios** include the five-path/six-function/sixteen-input
matrix and all 144 Decimal/extension scalars from the existing codec fixture,
wrapped in an object by original jsonb and evaluated with all six functions.
They cover null/missing values, objects/arrays, coercion, quoted strings,
NaN/Infinity, signed zero, Int64 maximum, Unicode and extension formatting.
Original recognition accepts 1,120 references. The guard executes 79 native
single-row index queries; each indexed value equals the actual function result.
These counts describe this corpus, not a percentage of supported user queries.

| Original outcomes | Success | Error | Panic |
| --- | ---: | ---: | ---: |
| Index conversion | 1,116 | 156 | 72 |
| Function consumer | 955 | 347 | 42 |

Original panics from extreme Decimal scale/date formatting are caught only by
the oracle transport and retained explicitly. Native code rejects those cases
with existing bounded errors; it does not crash. Exact values and nonpanic error
messages match. All failed native builds discard staging and return no index.

The native test compares all source recognition results, learned types, indexed
values and consumer values/errors. It also exercises concrete incorrect-match
counterexamples, nullable query restrictions, NOT preserving unknowns, wrong
types, unsupported queries and cancellation of both covered and uncovered calls.
String provenance is tested across mixed updates, old-index ownership, remap,
further updates and a complete rebuild. The extension regression failed before
the flag was added, demonstrating that merely matching the Utf8 target was unsafe.
The first guard admitted numeric path `0`; its failing differential test exposed
the root-array mismatch, and reusing the existing integer parser fixed it.

Validation commands:

```text
rtk proxy pixi run python scripts/lance_json_matcher_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_matcher.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_stream.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_bitmap.mojo
```

Four new matcher tests and ten existing stream/bitmap tests pass (**14 total**).
The four fixture/provenance files reproduce byte-for-byte; the cases are identical
to those used by the final native tests. Stream tests were rerun after adding
provenance; the unchanged bitmap's successful run is reused. Results and hashes
are recorded in the port registry and local
`.build/lance-json-matcher-validation/results.json`. The existing application
runtime is unchanged, so the earlier full Python **3,752 passed / 1 skip** is
historical evidence, not a new test run.

## Remaining work

Complete expression binding/coercion and residual planning, snapshot-aware
selection, wider function-aware index coverage, then authoritative index catalog
migration and public durable create/list/drop/update/rebuild/recovery. External
sort/spill, shard/file/cache support and other scalar targets remain in the
existing index plan. None of the 49 full product packages closes from this
leaf dependency; M5/M6 and deferred native Linux acceptance remain open.
