# D03d payload filter validation

Date: 2026-10-30. Parent `7215862`; Mojo `1.0.0 (ed45d567)` on macOS ARM64.
Plan: [payload filter source port](../plans/2026-10-30-payload-filter-source-port.md).

## Implemented behavior

Native `PayloadCondition` parses query JSON values into owned typed match,
range/count, null/empty and geographic conditions. It ports Qdrant's plain
`FieldCondition` checker, including one-level arrays, cross-type MatchExcept,
Float64 numeric ranges, nanosecond datetime ordering, missing-path rules and
the count > empty > null override order. Other match/range/geo properties are
alternatives inside one field node. Date parsing and spherical distance reuse
the verified chrono/GeoRust ports; no runtime Python or Rust evaluator is used.

`field.key` uses JSON paths. Existing `condition.name` retains literal-name
semantics. `nested` selects object elements using source `array_key` traversal
and evaluates the entire child expression against each single object. It does
not flatten objects into validated top-level DocumentFields, so quoted empty/NUL
keys remain usable. Root traversal does not add a container around the payload,
preserving the existing 64-container per-field depth limit. `at_least` counts
matching children, including zero and counts larger than the child population.

The existing bounded arena owns new field/path/minimum nodes; cloning copies
the current parsed state and paths. The direct evaluator uses bounded recursive
scope traversal. Metadata evaluation retains scalar indexes and Boolean bitmap
composition; new field/nested/minimum nodes scan live authoritative payloads.
Nested children are never evaluated against the wrong root scope. No storage
format, schema migration or write protocol changed.

Shared binding conversion exposes the nodes through search/batches, named and
universal queries, formula conditions, Arrow query/scanner paths, existing HTTP
search and payload mutation routes. Query validation precedes mutations. Source
geographic filters validate query points but inspect unchecked numeric stored
coordinates; bounding-box/radius borders are strict. Text/phrase are source
plain substring checks, prefix is case-sensitive and text-any splits with the
verified Rust Unicode whitespace classification.

## Original-source evidence

The Rust oracle compiles Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412` FieldCondition/Match/Range/ValuesCount,
geographic checks, JSON-path parser/traversal and Boolean combinators. Nested
object traversal is extracted from `check_payload`; storage/index scaffolding
and recursive arguments are adapted to standalone in-memory maps. Expression
dictionaries are input transport adapters. Original geo polygon code is compiled
as a dependency of FieldCondition but is not exercised or claimed as a native port.
Real pinned chrono 0.4.45, geo 0.33.1, ordered-float and serde supply reference
date, distance and JSON number behavior. Existing chrono/geo/Rust notices apply.

Six upstream source files, 68 original units, scaffold and Cargo.lock hashes
were independently checked against the fixed source revision. Python generates
inputs only; expected booleans/errors come from Rust. The 10,781 source cases
contain **1,967 matches, 8,804 nonmatches and 10 parsing errors**. Coverage includes
missing/null/arrays, nested arrays, wrong types, signed/unsigned/numeric precision,
plain text/phrase/prefix, Unicode whitespace, simultaneous property precedence,
all range operators, dates/invalid dates/nanoseconds/leap seconds, geographic
borders and antimeridian crossing, invalid/unchecked coordinates, nested object
scope and recursion, empty Boolean groups and minimum-count extremes.

## Validation

Heavy builds/tests ran serially. Regression logs are in
`.build/payload-filter-validation/`; initial targeted runs are also recorded in
the task's tool output.

| Command (prefixed with `rtk proxy`) | Result |
| --- | --- |
| `python3 scripts/qdrant_payload_filter_reference.py` | 10,781 original-source cases generated |
| `pixi run mojo run -I src tests/mojo/test_payload_filter.mojo` | 3 passed, including every source case through direct and metadata paths |
| `pixi run mojo run -I src tests/mojo/test_filter_expression.mojo` | 5 passed |
| 14 native filter/metadata/query/persistence/formula modules | 93 passed; commands and per-module results in `native.json` |
| `pixi run build-python` | Passed; rebuilt after the final native cloning change |
| `pixi run python -m pytest tests/python/test_payload_filter.py -q` | 16 passed, 3 existing warnings before final clone-only correction |
| `pixi run env PYTHONPATH=python:. pytest tests/python -q --tb=short` | **3,188 passed, 1 skipped, 3 existing warnings**; 73.63 seconds |

The **101 native tests across 16 modules** include original date/geographic
formula regressions after factoring raw-coordinate distance. Final field cloning
was rechecked by all new native source cases and a mutable-key clone regression.
The 16 new Python cases cover all source fixtures through both Python and Arrow,
condition-selected atomic mutations, retained scan snapshots/results, WAL-only
and checkpoint reopen, named HNSW, universal prefetch/formulas, literal/path
distinction, full-depth payloads, parallel batches, invalid requests before writes,
depth/node budgets, successful conversion closing its owner and real HTTP routes.

During implementation, nested codepoint-slice iteration stalled Mojo elaboration;
isolated import/helper/match-method probes localized it to text-token construction.
Direct codepoint iteration, already used by the JSON-path parser, compiled normally
and retained the same Rust whitespace behavior. A strict-JSON test originally used
a rejected dict subclass for the field itself; the owner-close test now uses a valid
nested outer mapping and asserts `CollectionClosedError`. Validation was not relaxed.

## Remaining full-scope work

D03/Q04 remain open: polygon geometry, dedicated typed/array/nested/date/geo/text
indexes, indexed tokenizer/BM25/phrase behavior, remaining condition types and
typed-index retrieval, full query/protocol coverage and C ABI exposure. Rich Arrow,
Lance/version/schema/object-store/Blob features, SQL/transactions/constraints,
UI/security/cluster/operations and the full product inventory remain pending.
M5/M6 and recommendation recall failures are retained; no optimization or new
performance acceptance was performed. Native Linux acceptance remains deferred.
