# Native JSON reader foundation — D01c3a

Base: `54d702b`, Mojo `1.0.0 (ed45d567)`.
The [interop plan](../plans/2026-10-30-json-interop-source-port.md) retains the
complete Arrow/Lance/null/numeric work and the full product ledger. This slice
adds a real native JSON value reader; public Arrow JSON remains **in progress**.

## Source and behavior

The Mojo reader ports serde_json 1.0.151's byte grammar, recursive sequence/map
rules, escapes and validated surrogate/UTF-8 handling. Numbers follow the
explicit default profile without float_roundtrip: UInt64 accumulation, overflow
to F64, decimal overflow truncation, saturating exponents and the original
309-literal POW10 table. It preserves negative zero and finite-value checks.
Existing PayloadValue handles owned storage and duplicate-key replacement.

The crate matches the checksum pinned by Qdrant and Lance. The independent Rust
executable enables std/preserve_order and links no Akasha implementation.
Thirty-seven source files are checked against the verified crate archive.
This profile does not establish the feature union of a complete server build.

`akasha.document.parse_json` / `parse_json_bytes` return owned native values
usable in existing document writes and payload operations. No Python parser,
temporary JSON string payload or new durable type/format is introduced. Native
source/content/node/depth limits are documented in [the API](../native-json.md).
Errors preserve acceptance/rejection, not upstream error wording/positions.

## Evidence

- Original-source corpus: **5,630** byte inputs, **3,063 accepted / 2,567 rejected**.
  All accepted typed trees, member order, integers and F64 bits match. Every
  accepted value also matches after the existing payload codec round trip.
- **18 related native tests passed**: seven reader/ownership/resource/persistence
  tests, five rich payload/path/codec tests and six document codec tests.
- Native lifecycle checks cover borrowed input reuse, 64-level depth, source
  byte cap, parsed-node accounting including discarded duplicates, WAL-only
  reopen, immutable snapshot, checkpoint/reopen and malformed JSON leaving
  WAL bytes and sequence unchanged.
- Python module build passed; full Python regression: **3,385 passed, 1 existing
  skip, 3 warnings** in 81.49 seconds.
- The source fixture, metadata, Cargo.lock and generated numeric table regenerate
  byte-for-byte. The resolved reference feature tree is retained in
  `.build/json-value-validation/cargo-features.txt`; it enables no float_roundtrip.

Logs are retained in `.build/json-value-validation`. The initial compile rejected
StringLiteral.bytes and an implicit Array copy; these were corrected to an owned
String and explicit move before any successful comparison was reported.

## Remaining interop requirements

Lance's `lance-arrow/src/json.rs` preserves storage-null cells while parsing
valid JSON text (including `null`) through jsonb 0.5.6. Current PayloadValue can
represent absent object members and explicit null, but has no separate absent
array-element state. Lossless nested extension interop needs that representation
decision and its durability tests first. The current Arrow canonical type also
allows StringView beyond the pinned Lance adapter's UTF-8/large UTF-8 detection.

Lance/jsonb numerical source comparison, native JSON serialization, standard
extension metadata/storage/null semantics, arbitrary top-level keys and complete
public Arrow integration remain open. No full D01, Lance, SQL, protocol, UI,
security, cluster, platform or performance gate is marked complete. No tuning.
