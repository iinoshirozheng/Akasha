# JSONB path/query source port

Continue from `a96ed47`; keep the full product ledger and feature-before-tuning
order. Existing Qdrant `JsonPath` stays a separate grammar/contract.

Source: jsonb 0.5.6 (`databend`, no arbitrary precision), `jsonpath/{parser,path,
selector}.rs`, `number.rs`, nom 8.0.0 numeric/string combinators; Lance's
`lance-arrow/src/json.rs` and `lance-datafusion/src/udf/json.rs` consumers.

1. Port the **complete** path/expression grammar into an owned bounded Mojo AST:
   root/current, dot/colon/quoted fields, both wildcards, recursive levels,
   index lists and inclusive ranges, last-relative signed indices, filters,
   unary/binary arithmetic, comparison/starts-with, and/or/exists. Preserve
   alternative order, whitespace/escape behavior and literal numeric types.
   Differential tests compare complete ASTs against the actual crate, including
   every truncation, malformed UTF-8 and upstream parser panics. Native parser
   completion is a dependency, not public query completion.
2. Port the source Number arithmetic and comparison contracts for Int64/UInt64/
   Float64/Decimal64/128/256, including checked/wrapping edge cases, ordered NaN,
   scale adjustment and the actual source float fallback. Use existing numeric
   conversion code where equivalent; port required ethnum operations from source.
3. Port the full selector queue/recursion/expression behavior, including all six
   output modes: values, array, first, value, exists and predicate_match.
   Include source path/number Display helpers separately from JSON serialization. Preserve
   first-vs-value cardinality (value wraps multiple matches), ordering/duplicates, lax wildcard behavior,
   unknown comparison, missing/null, extension values and complete errors.
   Add finite candidate/output/depth limits and cooperative query control.
4. Expose native/Python JSONB selection and the Lance consumer contracts, then
   integrate native document/query/filter/projection boundaries. Cover WAL and
   checkpoint reopen, snapshot ownership, failures without writes and full
   regression. Keep first-text Lance Arrow helper distinct from DataFusion's
   select_value semantics (one match or an array of multiple matches); do not silently conflate them.
5. Complete JSONB indexing and remaining C/distributed boundaries as tracked in
   D01/D03/A03. Full SQL UDF integration follows the real SQL execution layer.

Observed source details to retain: empty paths are valid; quoted empty keys are
rejected by this parser; unterminated nonempty quoted strings can panic; raw
field delimiters omit ampersand and ASCII tab/newline; integer alternatives
precede float parsing and may consume prefixes; arithmetic atoms do not implement
a general precedence parser; duplicate index groups can return duplicates.
Source panic becomes an Akasha error, never a process crash. Resource limits are
explicit adaptations. No partial grammar may stand in for full JSONPath.

Additional selector/numeric findings to preserve in the subsequent ports:
`eval_compare` returns unknown immediately on the first incomparable pair;
and/or evaluate both operands and propagate unknown. A scalar/object bracket
wildcard is lax, while named-object wildcard is object-only. Array index groups
are processed independently, so overlapping groups duplicate results in order.
The source `ArrayIndex::to_indices` casts a negative range end to usize and may
attempt an enormous set; bound actual selection work and isolate such source
oracle cases rather than exhausting the host. Decimal scale adjustment uses the
pinned release integer-power/wrapping behavior before checked multiplication.


## Grammar dependency checkpoint: D01c4a

Step 1's complete parser/owned AST is native and verified: 8,525 actual-source
cases, 4,238 accepted ASTs, 4,275 parse errors and 12 mapped source panics; seven
native tests pass and fixture/metadata/lock/license reproduce byte-for-byte.
All 18 AST node kinds, all operators and literal categories are exercised,
including 594 distinct literal Float64 bit patterns. This is not step 2–5 or
public query completion. Continue Number semantics and the complete selector;
do not substitute a restricted path-only executor for the documented scope.

## Arithmetic/comparison dependency checkpoint: D01c4b

Step 2's six Number variants are native and verified, including original
negation/arithmetic/errors, exact scale comparison and source float fallback.
Fixed-size words use ethnum's multiplication/power and Arrow's checked i256
multiply, independently checked against original ethnum. Rust float remainder
uses the equivalent native libm primitive rather than Mojo's floor modulo.
8,495 unary inputs, 94,213 pairs, 2,404 wide products, every scale power and
4,709 numeric codec/legacy bodies pass; 17 native tests and source reproduction
pass. See [evidence](../research/2026-10-30-jsonb-number-validation.md).
Continue steps 3–5 without reducing the selector or public-query scope.

## Selector and Python value-query checkpoint: D01c4c

Step 3's complete parsed selector semantics and all six output modes are native;
step 4's standalone Python value query is exposed through `JsonbValue.query`.
64,856 source cases / 389,100 mode outcomes match source successes/errors,
except one retained source success rejected by the existing codec depth bound.
Twenty-two native tests, 52 new Python tests and full Python **3,681 passed /
1 skip** pass; fixtures/metadata/lock reproduce byte-for-byte. WAL/checkpoint
reopen and ownership/read-only failures are verified. See
[evidence](../research/2026-10-30-jsonb-selector-validation.md).

Continue source AST/Number Display, Lance consumers, collection query/filter/
projection integration and step 5 indexes/protocol boundaries. This checkpoint
does not complete steps 3–5, D01 or any full-product acceptance gate.

## Source Display checkpoint: D01c4d

Native Number and the complete existing parsed-AST Display now match original
jsonb: 88,716 typed Number inputs, 4,238 parsed path texts from 8,525 parser
cases, and 11,692 ethnum 256/128 division results. Source panics are errors;
source successful quirks (including unescaped paths and decimal edge outputs)
remain exact. Twenty-one native tests, rebuilt Python kernel and full Python
**3,681 passed / 1 skip** pass; source verification and fixture/metadata/lock reproduction pass.
See [evidence](../research/2026-10-30-jsonb-display-validation.md).

Continue step 4's actual Lance consumers and collection integration. Lance
Arrow `JsonArray::json_path` returns the first match rendered through RawJsonb;
DataFusion `json_extract` uses select_value and wraps multiple matches. Its
typed extraction, key lookup and scalar conversions have additional contracts
in `lance-datafusion/src/udf/json.rs`; port them with source execution evidence
instead of conflating the two consumers. Complete step 5 indexes/protocols and
remaining Number conversions without declaring D01 or the full product finished.

## Source conversion checkpoint: D01c4e

Number exact i64/u64 and rounded i128/i64/u64 conversions, full unsigned wide
division and RawJsonb bool/integer/float/string casts are now native. Python
`JsonbValue.cast` exposes the scalar operations. Original-source matrices,
25 native tests, 17 new Python tests and full Python **3,698 passed / 1 skip**
pass; fixtures reproduce. Continue the
[Lance consumer integration plan](2026-10-30-lance-json-functions-source-port.md),
then collection/filter/projection/index and remaining protocol/SQL boundaries.

## Lance consumer checkpoint: D01c4f

All eleven actual Lance JSON consumer operations and nullable Arrow/Python
boundaries are now source-verified; exact key/index access and type tags are
native. See [consumer evidence](../research/2026-10-30-lance-json-functions-validation.md)
and [continued integration plan](2026-10-30-lance-json-functions-source-port.md).
Collection planner filtering/projection, indexes, SQL and complete C/distributed
contracts remain open; all full-product/platform/performance gates stay open.
