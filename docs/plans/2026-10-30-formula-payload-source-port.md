# Q04d: rich payload formula retrieval

Part of the full [feature plan](2026-10-30-feature-completion.md); not a reduced
product goal. Functional correctness only; all remaining ledger rows stay open.

## Source and contract

Use Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`:
`json_path/{mod,parse}.rs`, `rescore_formula/{formula_scorer,parsed_formula}.rs`
and `struct_payload_index/read_view/value_retriever/helpers.rs`.

The authoritative-payload retriever traverses the full JSON path. Unless the
path ends in `[]`, it flattens each retrieved array by exactly one level. Zero
values trigger the exact normalized-path default; one value is used directly;
multiple values are an array and fail numeric conversion. Null/wrong types do
not trigger defaults. Defaults are JSON values, without array flattening.
Score defaults use JSON numbers (including UInt64); other types yield zero.

Reuse the ported owned JSON traversal with the DocumentField root adapter;
do not wrap the root and accidentally reduce the per-field depth limit. Retain
existing numeric evaluation and short circuits. Accept bounded rich defaults
through native/Python/Arrow query paths, with aggregate value-node/byte limits.
No durable format or protocol changes.

## Execution and acceptance

1. Compile the original path parser, traversal, payload retriever and scorer
   bodies together with real serde_json values. Preserve the older scalar oracle.
   Freeze source/function/scaffold/lock hashes and publish source-derived cases.
2. Port the retriever and remove obsolete flat-value rejection. Use the shared
   native JSON converter for Python defaults; keep Python serialization-only.
3. Test source numeric bits/errors, wildcard suffix vs middle, empty/null/multiple
   values, normalized defaults, UInt64, short circuits and bounded resources.
   Verify native snapshots, actual public writes/reopen, nested query trees and
   owned Arrow results. Update prior explicit-gap tests to the new contract.
4. Run targeted native modules, rebuild Python and run targeted then full Python
   tests serially. Record failures and fixes; update provenance/docs/ledger and
   commit locally, without pushing.

## Remaining dependencies

This is the payload-backed retrieval path, not Qdrant's typed-index retriever
selection. Dedicated nested/geo/datetime indexes and their coercions remain D03.
The source's geo formulas deserialize GeoPoint and call geo::Haversine;
datetime formulas call DateTimePayloadType parsing and convert microseconds to
seconds. Those require their own source-backed shared type ports, not Python
datetime or an invented spherical/date algorithm. Full formula conditions,
date/geo expressions, sampling/feedback and REST/gRPC keep Q04 open. Rich Arrow
payload columns and every Lance/SQL/UI/security/cluster item remain open.
