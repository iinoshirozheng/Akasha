# Source-backed JSON-path and formula variable validation

Date: 2026-10-30. Mojo 1.0.0 (ed45d567), macOS ARM64.
Qdrant revision: `74f3e85b9473c62560006c043e13737ce6b48412`.

## Implementation and source boundaries

`document/json_path.mojo` ports the grammar from Qdrant's
`lib/segment/src/json_path/parse.rs`, structural operations/display from
`json_path/mod.rs`, and formula `VariableId::from_str` from
`index/query_optimization/rescore_formula/parsed_formula.rs`.
Native bounded codepoint cursors replace nom combinators. There is no Python
parser/evaluator or runtime Rust dependency.

The parser consumes the complete input. Raw keys use Unicode alphanumeric plus
underscore/hyphen. Quoted keys permit literal punctuation, controls and empty
names, but no backslash or quote escapes, matching the actual source grammar.
Array indexes are UInt64 (the pinned 64-bit source usize), with leading zeros,
overflow rejection, repeated indexes and wildcard `[]`. Display canonicalizes
quotes and index digits. Prefix, wildcard, inclusion/exclusion and compatibility
operations retain source behavior. In particular, exclusion follows the source
code's prefix direction even though its nearby prose describes the reverse.
The native parser limits paths to 65,536 bytes and 1024 parts; composition checks
its output bounds. These resource limits are native adaptations.

Formula variables and defaults now use this shared parser, replacing the
provisional literal-name/signed-index parser. `$"score"`, `$score[000]` and
`$score` normalize to the first score slot. An index greater than Int.MAX is
checked against the source count as UInt64 before any signed conversion.
Quoted literal payload names are usable through Mojo/Python/Arrow. Nested and
array paths parse, but formula evaluation explicitly rejects them until rich
payload traversal exists; they cannot accidentally read a literal dotted key.

Native `FormulaDefault` owns a parsed variable and a scalar value. It replaces
the provisional use of `DocumentField`, whose persistent-name constraints do
not apply to query-only path defaults. Quoted empty/NUL-containing default keys
therefore work without permitting those keys in existing stored documents.
Duplicate normalized defaults remain deterministically rejected. The Python
`Formula` wrapper shape is unchanged. No durable format or GPU behavior changed.

## Unicode and independent reference

The pinned Qdrant Dockerfile selects Rust 1.97.1. Mojo's available Codepoint
classification helpers are ASCII-only, so generated native Unicode ranges use
Rust 1.97.1's original Unicode 17.0.0 Alphabetic/N data and lookup methods.
The source `char::is_alphanumeric` body is compiled in a trait adapter (only the
method's public visibility marker is removed). A checked assertion stands in
for compiler `intrinsics::assume`. All Unicode scalars are checked against the
host Rust 1.92.0 classifier before the original nom parser runs; equality is
verified rather than assumed from version numbers. The emitted 844 inclusive
ranges have a native lookup and an exhaustive native codepoint-range test.
The Rust source URLs, SHA256s and MIT license are retained.

The reference compiles Qdrant's complete parser file unchanged with nom 8.0.0,
plus original path/display and formula-variable bodies. Container/derive
adapters are documented in the fixture README. `Cargo.lock` pins reference-only
dependencies. Fixtures contain 548 inputs (141 valid paths, 147 valid formula
variables), 81 path-operation pairs, Unicode ranges and source/scaffold hashes.
No expected path, variable or operation result is computed by Python.

## Verification

- `rtk proxy python scripts/qdrant_json_path_reference.py`: 548 inputs, 81 pairs,
  844 Unicode ranges; all valid Unicode scalars match the pinned Rust source.
- Native `test_json_path.mojo`: 4 tests cover every fixture, canonical round trips,
  path operations, the full codepoint range and byte/part/composition bounds.
- Native `test_formula.mojo`: 4 passed, including all 309 prior numerical source
  cases after replacing the variable/default model.
- Targeted Python formula/path/universal modules: **1029 passed**, including
  **573 new path cases**. Coverage includes literal punctuation/Unicode keys,
  reserved-name aliases, UInt64 indexes, normalized defaults, empty/NUL defaults,
  rejection of unsupported value traversal and resource bounds.
- `rtk proxy pixi run test-python`: **3034 passed, 1 skipped**, after rebuilding
  the extension and maintenance worker. The skip is the existing optional
  Qdrant Edge integration; three existing binding/FastAPI deprecation warnings
  remain. Eight relevant native tests passed across the two modules above.
- `rtk proxy git diff --check`: passed.

The first native path fixture test exposed a test-adapter limitation:
`UInt64(py=...)` converts through signed Py_ssize_t in this Mojo version. The
fixture comparison now compares exact decimal text for large expected unsigned
values; production parsing performs checked UInt64 arithmetic and is independently
tested through public formulas with full-range default indexes.

## Remaining goal

D01 remains open for rich payload objects/arrays/null, typed value traversal and
mutation, durable versioned codecs/migrations, corruption/torn-write/restart
tests and every public boundary. D03 rich filters/indexes, Q04 date/geo/formula
values, sampling/feedback and the entire remaining product ledger stay open.
This change is a shared parser and usable flat-key formula extension, not proof
of rich document support. Complete CPU/C ABI/crash/GPU and native Linux gates
were not rerun. Existing M5/M6 and recall failures, native Linux deferral and
the requirement to finish functionality before optimization remain unchanged.
