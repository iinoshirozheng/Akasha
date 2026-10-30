# Original JSONB path parser ASTs

Run `pixi run python scripts/jsonb_path_reference.py` from the repository root.
The executable calls jsonb 0.5.6 `jsonpath::parse_json_path` with its pinned nom
8.0.0 dependency. No parser implementation is rewritten for the oracle. Accepted
results serialize the complete original AST into tagged arrays; numbers retain
the exact source Int64/UInt64/Float64 variant and raw 64-bit representation.
Source errors and caught panics are separate outcomes. Display output is not used
as a proxy for AST equality, nor claimed as an implemented native operation.

8,525 distinct byte inputs produce 4,238 accepted ASTs, 4,275 parse errors and
12 source panics. Coverage includes all 18 AST node kinds, all 14 binary and both
unary operators, all six literal categories, recursive levels, index lists and
inclusive/last-relative ranges, filters/exists, source parser test inputs,
Unicode/escapes/control bytes, UTF-8 errors, numeric boundaries from the existing
independent fast-float corpus, every truncation of nested expressions and seeded
compositions. Source out-of-bounds quoted-string panics become native errors.

A node is `[kind, a, b, text, bits-as-decimal-string, children]`. Path kinds 0–10
follow the upstream enum. Expression kinds 11–15 are paths, literal, binary,
unary and exists; 16 is an index and 17 a slice. `a` stores the enum/operator or
literal type (null/bool/i64/u64/f64/string = 0–5). Index `a` is 0 absolute or 1
last-relative and `b` is its i32 offset. Recursive level `a=-1` means absent;
otherwise `b=-1` means single-level and `b=256` means last. Other fields are zero
or empty. This transport is test instrumentation, not a new query protocol.

`sources.json` records verified crate/source/test/license hashes, generator,
scaffold, numeric input, output and lock. Dependencies use databend with no
arbitrary_precision. JSONB/nom licenses are retained under docs/upstream/licenses.
The native parser has independent 65,536-byte/node, 64-level and 1,000,000 parse-
step limits. Selection, numeric execution, source Display helpers and public
query boundaries remain in the complete JSONB path plan.
