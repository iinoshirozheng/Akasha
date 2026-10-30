# D01c4c: source JSONB selector and Python value queries

Base: `62dfb33`; Mojo `1.0.0 (ed45d567)`. This continues steps 3–4 of the
[JSONB query plan](../plans/2026-10-30-jsonb-path-source-port.md). All remaining
49-package product requirements and performance gates remain open; no tuning.

## Sources and behavior

The pinned jsonb 0.5.6 `jsonpath/selector.rs` supplies selection, recursion,
filter/expression evaluation and all six public output modes. `jsonpath/path.rs`
supplies index/recursive-level and PathValue comparison behavior. Number serde
serialization, owned values, databend builders/iterators and object lookup retain
the existing `databend`, no-arbitrary-precision profile.

The Mojo `JsonbSelector` owns its root and uses fresh bounded stage lists on each
call. It executes the complete parsed grammar: fields, wildcards, recursive
levels, grouped/ranged indices, scoped filters, exists, arithmetic and predicates.
It preserves ordering and duplicates, one-level expression array flattening,
extension skipping, unary sequence validation and binary numeric cardinality.
Comparisons stop at the first true or unknown pair; and/or evaluate both operands
and propagate unknown. Arithmetic uses the previously verified native Number
port. Decimal expression results serialize to F64 as source serde requires;
ordinary selection retains the original body, including legacy encodings.

Public Python `JsonbValue.query` delegates parsing and execution to Mojo. Its six
modes are values, array, first, value, exists and predicate. `value` returns
absence, one match, or an array of multiple matches. JSON null is a present
carrier, distinct from absence. First/exists execute full selection, preserving
later errors. Python handles UTF-8/bytes, option validation and result wrapping.
See [API and limits](../native-jsonb.md#jsonb-value-queries).

This implements the complete parsed grammar, not every manually constructible
Rust enum literal. Source AST/Number Display remains separate work.

## Independent evidence

The Rust harness invokes each original selector method separately, rather than
inferring one mode from another. Crate archives, source files and original tests
are verified before execution. Fixtures, metadata and Cargo.lock reproduce
byte-for-byte in locked offline release mode.

| Corpus/result | Count |
| --- | ---: |
| Documents / paths | 5,859 / 4,445 |
| Document/path cases | 64,856 |
| Cases executing all six modes | 64,850 |
| Executed mode outcomes | 389,100 |
| Exact successful outputs | 368,799 |
| Original success rejected by existing codec depth limit | 1 |
| Original executor errors / panics | 20,300 / 0 |
| Parse errors / mapped parser panics | 5 / 1 |

Errors comprise 17,948 InvalidJsonPath, 36 division-by-zero, 2,226 Int64,
12 UInt64 and 78 Decimal256 overflows. Original success bytes are retained even
for the one depth-limited output; the fixture annotates the existing bound.

- `pixi run build-python`: passed.
- `PYTHONPATH=python:. pixi run python -m pytest tests/python/test_jsonb_selector.py -q`:
  **52 passed**, including all six full oracle modes, transport validation,
  resource/deadline/cancellation cases, missing/null and ownership.
- Full `tests/python`: **3,681 passed, 1 skipped**, 103.85 seconds; three
  dependency/binding deprecation warnings. No skip is counted as acceptance.
- Native selector (5), path (3), Number (4), codec (6) and writer (4):
  **22 related tests passed** through the project compiler.
- WAL-only and checkpoint reopen tests query restored values, assert failed
  queries leave WAL/sequence/data unchanged, and retain results after close.

`.build/jsonb-selector-validation/` retains build, targeted/full Python, native,
reproduction and hash records. This rebuild changes the Python kernel; the new
full regression supersedes the prior unchanged-kernel result for this scope.

## Corrections and bounded execution

The first native run caught an Optional boolean conversion: Mojo promoted the
right side of `result and result.value()` to Optional, so a present false result
was treated as true. Explicit `Bool(result)` fixes it; the complete oracle passes.
The second run reached a source result wrapping a 64-level value at level 65.
Akasha correctly rejects that existing codec violation; the original output is
retained and annotated. Both failed logs remain available.

Owned stage lists replace source queue/swap storage. Work, result counts and
cumulative owned bytes are bounded; final arrays also retain codec byte/node/
depth limits. Source negative-ended ranges can cast to an enormous usize set;
Akasha rejects before allocation, including an empty array's `[0 to last]`.
Such dangerous ranges are not executed by the reference harness. Native tests
also validate mutated AST ordering, types, cycles, sizes and nesting.

Native QueryControl supports cooperative cancellation/deadlines. Python samples
its existing cancellation token before the synchronous call and checks deadlines
during native execution; live Python-thread cancellation is not promised.

## Remaining scope

This is a read-only value query API, with no persistence format change. Collection
JSONB filtering/projection, dedicated indexes, Lance consumer integrations,
Arrow transforms, C/distributed query operations and SQL UDFs remain open.
Source Display and remaining Number conversion APIs are still pending. Full
D01/D03/A03, all other product packages, M5/M6 and deferred native Linux acceptance
are not completed by these tests.
