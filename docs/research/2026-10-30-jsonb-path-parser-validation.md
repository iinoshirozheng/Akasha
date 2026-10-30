# D01c4a native JSONB path grammar validation

Base `a96ed47`; Mojo `1.0.0 (ed45d567)`, macOS arm64. This completes the
parser/owned-AST dependency in the [JSONB query plan](../plans/2026-10-30-jsonb-path-source-port.md).
It does **not** complete JSONB selection, numeric execution, source Display,
collection filters/projections/indexes or public Python/C/distributed queries.
The full product goal and performance gates remain active.

## Source and implementation

The port follows jsonb 0.5.6 `jsonpath/parser.rs` alternative/sequence order and
`path.rs` AST/is_predicate, with nom 8.0.0's byte-slice whitespace, signed/unsigned
prefix parsers, float recognizer and cut semantics. The original crate is built
with databend and without arbitrary precision. The existing Qdrant path grammar
is unchanged. Previously ported jsonb string decoding and fast-float2 F64
conversion are reused; literal type/bit results are compared to the actual Rust
AST, rather than assumed equivalent from rendered text.

The Mojo representation uses an owned flat node arena and child indices. It
covers all path forms (root/current, dot/colon/object fields, wildcards,
recursive levels, index lists/inclusive/last-relative ranges, filters) and all
expression forms (paths/literals, 14 binary operators, both unary operators and
exists). Numbers retain source Int64/UInt64/Float64 variants and raw bits.
`JsonbPath.parse`, `parse_bytes` and `is_predicate` are native package exports.

Native cursors reproduce nom backtracking; recoverable failures restore both
cursor and arena, while a float exponent cut cannot fall back into a field path.
Source parser panics become Error. Input byte/node/nesting/parse-step limits are
explicit adaptations: 65,536 / 65,536 / 64 / 1,000,000. Strings own their bytes;
parser buffers do not outlive the call. Native tests include ownership, byte
boundary, syntax nesting, AST depth and source grammar distinctions.

Source details retained include valid empty paths; rejection of quoted empty
strings/keys; tab/newline/ampersand inside raw fields; case-sensitive operators
versus case-insensitive last/to; saturated last-relative index negation; prefix
integer alternatives ahead of double; restricted arithmetic atoms; and both
operands/nesting represented in the source left-associated and/or tree.

## Actual-source differential evidence

`scripts/jsonb_path_reference.py` builds an executable calling the original
`jsonb::jsonpath::parse_json_path`. The scaffold only traverses the returned
original AST into a tagged JSON fixture. It does not rewrite the parser or use
Display as an equality proxy. Source parse errors and catch_unwind panics are
recorded separately. Archive checksums and original Rust files are verified;
source test inputs and the new nom MIT license are also checked against archives.

8,525 distinct byte inputs yield:

- 4,238 accepted ASTs, containing 23,609 normalized nodes;
- 4,275 parse errors and 12 source panics, all rejected natively;
- all 18 node kinds, all 14 binary operators, both unary operators and all six
  literal categories; 594 distinct Float64 literal bit patterns.

Inputs include original source parser cases, Unicode/surrogates/escaped keys,
all byte values, malformed UTF-8, i32/u8/i64/u64 boundaries, numeric cases from
the independent fast-float corpus, recursion/range/last forms, every truncation
of nested expressions and seeded combinations. Every accepted tree and
is_predicate result matches; every rejected/panic case raises in Mojo.

## Executed checks

- `pixi run mojo run -I src tests/mojo/test_jsonb_path.mojo`: 3 passed, including
  the complete 8,525-case corpus and native ownership/resource checks.
- `pixi run mojo run -I src tests/mojo/test_json_path.mojo`: 4 passed, including
  existing Qdrant parser/operations and exhaustive pinned Unicode classification.
- Original source fixture/provenance/lock/license generation and reproduction
  passed byte-for-byte; evidence is recorded in `.build/jsonb-path-validation/` together with commands, logs,
  exit codes and current file hashes.

Initial compilation required an explicit List type for a mutable literal and
restoring the parser's moved-out arena field before destruction; those failed
logs are retained. The final native checks pass. No source semantic mismatch
was hidden or filtered from the fixture.

This standalone native parser is not yet called from the Python kernel. Python,
WAL/crash/C ABI and performance suites were not rerun for this dependency;
`a96ed47`'s full Python 3,629 passed / 1 optional skip remains the latest relevant
application validation. No persistence/protocol format or existing execution
path changed, and no optimization was performed. Native Linux remains deferred.

Next: source Number comparison/arithmetic (including all decimal widths), full
selector/output modes and source consumer semantics, then public queries and
indexes. Remaining requirements are preserved in the complete plan and ledger.
