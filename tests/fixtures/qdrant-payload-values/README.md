# Qdrant rich payload source oracle

Regenerate with `rtk proxy python scripts/qdrant_payload_reference.py`.
The fixture pins Qdrant v1.19.0 at `74f3e85b9473c62560006c043e13737ce6b48412`.
It compiles the original get/set/remove/map-merge bodies and JSON-path parser
with `serde_json`'s **preserve_order**, as configured by Qdrant. `MultiValue`
is a Vec adapter; unrelated derives/annotations are omitted. Algorithms are
unchanged. Cargo.lock fixes the reference-only dependency graph.

The 2,088 cases cover nested arrays/objects, scalar/null/missing values, empty
containers, literal/Unicode/empty/NUL keys, wide indexes, no array growth,
idempotent index deletion, wildcard emptying, shallow merge and swap-remove order.
Python generates inputs and records Rust output; it does not calculate answers.
Native tests compare ordered typed representations and signed-zero bits, then
round-trip each result through payload v2 and the Python transport.

An additional 110 filter cases execute the original `ValueChecker` trait and
`Match` implementation. HashSet replaces Qdrant's IndexSet in this transport
scaffold; only single-literal membership is exercised. These cases cover one-level
array evaluation, nested arrays, null exclusion, object MatchExcept and UInt64
values, with native direct/indexed/update/cache-restore/delete comparisons.

These are source-function differentials, not full Qdrant server/protocol tests.
Akasha bounds and binary corruption tests are separate native contracts. Array
and object mutation is a Mojo value operation; public collection path-update
API integration remains in the master ledger.
