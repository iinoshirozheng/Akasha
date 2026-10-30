# Qdrant plain payload filters

Regenerate with `rtk proxy python3 scripts/qdrant_payload_filter_reference.py`.
The generator checks out source text from Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412` without mutating the checkout.
It compiles the original FieldCondition/Match/Range/ValuesCount/geo checks,
JSON-path parser/traversal and Boolean combinators. Nested object traversal is
extracted from `check_payload`; storage/index plumbing and recursive call
arguments are adapted to the standalone in-memory object transport.

Python only generates input JSON and stores Rust outcomes. The fixture records
six source-file hashes, 68 original source-unit hashes, the complete scaffold hash
and its pinned Cargo.lock hash. It uses real chrono 0.4.45 and geo 0.33.1, as in
the existing datetime/geographic source ports, plus real ordered-float/serde
number semantics. No expected filter result is computed in Python.

There are 10,781 cases: 10,771 Boolean outcomes and 10 query parsing errors.
They cover scalar/array/null/missing values, wrong types, integer precision,
plain text/phrase/prefix and Unicode whitespace, combined-property precedence,
numeric/datetime/count ranges, leap seconds/nanoseconds, strict geographic
borders, antimeridian/unchecked stored coordinates, nested same-object scope,
empty Boolean groups, minimum counts, nested recursion and quoted object keys.

Akasha's `kind` dictionaries are transport adapters, not Qdrant REST schemas.
Unknown properties/ambiguous match objects are rejected by the native API.
The original polygon implementation is compiled as a dependency of the full
FieldCondition checker, but no polygon cases are included: native polygon and
dedicated typed-index semantics remain open tasks. This oracle exercises the
source's plain payload checks without field indexes or ID/vector conditions.
