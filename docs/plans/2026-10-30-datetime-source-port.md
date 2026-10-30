# Q04f / D03c: native datetime parsing and formula queries

Continue the full [feature ledger](2026-10-30-feature-completion.md), with
functionality before optimization. Parent: `51b1253`.

## Source and contract

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` uses DateTimeWrapper in
`lib/segment/src/types.rs`, chrono 0.4.45 (crate SHA256
`1aa79e62e7697b8e29b513a68abacf485adcd1fe8284a4316c5ae868e6633327`,
revision `170338250e836976a211e64728ec956e45e78a39`). Preserve its ordered
RFC3339, relaxed chrono, offset and naive/date-only parser attempts, UTC
conversion, leap-second/nanosecond representation and microsecond timestamps.
Port the reachable chrono scanners, date validation/ordinal tables and epoch
arithmetic into Mojo; do not use Python datetime or invent calendar algorithms.

Formula `datetime` parses a constant eagerly; `datetime_key` resolves a JSON
payload path/default lazily. Convert timestamp microseconds to F64, divide by
1,000,000, then use the existing final F32 score rules. Payloads remain strings.
This does not require a durable-format migration.

## Work and acceptance

1. Pin/check chrono archive/source/license and compile Qdrant's original wrapper
   and scorer against the actual locked chrono dependency. Generate date/error,
   microsecond roundtrip and formula fixtures; expected values are Rust-only.
2. Add the native shared datetime type/parser, source-generated calendar and
   Unicode-whitespace tables, and integrate both formulas through native,
   Python and Arrow query APIs. Keep validation, ownership and work bounds.
3. Compare broad signed-year/calendar, invalid dates, UTC offsets, whitespace,
   fractions/leap seconds, min/max/negative timestamps and payload/default cases.
   Exercise real writes, updates, retained snapshots, reopen and Arrow ownership.
4. Run narrow native tests, build bindings and targeted/full Python checks
   serially; save evidence, source registry, API docs and task progress, then
   commit locally. Keep datetime/geo/nested indexes and the full product scope
   open until their separate end-to-end acceptance is satisfied.
