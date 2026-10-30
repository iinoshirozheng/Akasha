# Payload filtering source port

Continue D03/Q04 from Qdrant v1.19.0
`74f3e85b9473c62560006c043e13737ce6b48412`. Preserve the full product plan;
this slice implements payload predicates, scoped nested conditions and minimum
matches before any optimization. Existing `condition.name` remains a literal
top-level name. New `field.key` and `nested.key` use the source JSON-path grammar.

Source contracts: `payload_storage/condition_checker.rs`,
`payload_storage/query_checker.rs`, `types.rs` and `json_path/mod.rs`.
Reuse the verified chrono date parser and geo Haversine port. Plain text predicates
follow the source plain payload checker; tokenizer/BM25/indexed text semantics
remain separate work. Polygon geometry and dedicated typed indexes remain open.

Deliverables:

- Native validated match/value/set/text, numeric/datetime ranges, value counts,
  empty/null, bounding-box and radius conditions with source precedence.
- Bounded nested object scopes and at-least-N Boolean conditions; retain literal
  predicates and indexed Boolean behavior for existing callers.
- Shared evaluation in direct reads and metadata candidate selection, reached by
  Python, Arrow queries/scans and existing HTTP search/payload mutations.
- Original Rust source oracle covering positive, negative, missing, malformed,
  Unicode, date precision, geographic boundaries and nested-scope cases.
- Native and boundary regressions, restart/mutation coverage, build and full
  Python suite; update API, provenance and the full product ledger.

No persisted format changes. New predicates initially use the authoritative
payload evaluator, as Qdrant does without a specialized index. This is a valid
execution path; it does not complete the dedicated index work package.
