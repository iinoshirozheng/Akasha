# Lance JSON contract evidence and native StringView — D01c3b

Base `4d00180`; Mojo 1.0.0, PyArrow 21.0.0. No optimization or gate changes.

## Source findings that change the implementation

The exact pinned Lance module was compiled unchanged with jsonb 0.5.6, default
features disabled and databend enabled. Actual execution confirms that the
existing serde_json reader cannot substitute for Lance's JSON input:

- 5,641 inputs: extended mode accepts 3,426/rejects 2,215; standard mode accepts
  3,397/rejects 2,244; no panic in either on this corpus. The function's standard
  name alone is not evidence of RFC-equivalent acceptance.
- Across the common 5,630 serde_json fixture inputs, jsonb extended accepts 384
  that serde rejects, rejects 31 that serde accepts, and produces 695 different
  accepted trees after normalizing small unsigned integers and object order.
  Complete raw typed results are retained; normalization is only this comparison.
- Example: `-0` is serde_json negative floating zero but jsonb unsigned zero.
  `18446744073709551615000e-308` differs by one F64 bit step between the profiles.
  jsonb sorts object keys and rejects duplicates; it also accepts extended
  syntax and nonfinite values. These are not silently applied to existing APIs.
- Original Lance conversion preserves storage null separately from valid JSON
  text `null`, `[null]` and `{"x":null}`. The separate logical JSONB body and Arrow
  validity are the appropriate representation boundary. Existing plain payload
  null cannot encode both states inside list elements without a logical type.
- The pinned Lance recognizer handles UTF-8/large UTF-8 but not StringView;
  installed PyArrow supports all three `arrow.json` storage types. The current
  [canonical specification](https://arrow.apache.org/docs/format/CanonicalExtensions.html#json)
  also permits StringView, so this remains required despite the older adapter.

The updated [interop plan](../plans/2026-10-30-json-interop-source-port.md) calls
for a native JSONB logical value/codec and durable migration before extension
integration. The ordinary JSON reader stays on its existing source profile.

## Implemented StringView dependency

Both Arrow upsert APIs now decode StringView payloads in Mojo, recursively in
struct/list/large/fixed lists. The adapter only passes borrowed buffers and type
descriptors. Active views check the original Arrow `byte_view.rs` rules: 16-byte
records, inline content through 12 bytes, zero padding, external indices/ranges,
four-byte prefix equality and valid UTF-8. Existing null-parent masking remains.

Typed scanner projections accept `pa.string_view()`, preserve nested field
metadata and empty schemas, and write final owned C Data buffers directly.
External data uses the original `ffi.rs` variadic buffer-size trailer. View,
validity, external data and size buffers share the aligned output cap. The
existing recursive release owner is unchanged. No Python row staging, runtime
dependency, persisted schema or durable format is introduced.

## Verification

- Python module build passed.
- **26 new Python tests passed**, including the actual Arrow IPC fixture, both
  ingestion APIs, slices/nesting/Unicode/NUL, layout boundaries, WAL/checkpoint
  reopen, snapshots/close, retained last child, stable schemas and budget errors.
- **17 related native tests passed**: three new view-buffer validation tests,
  four shared payload tests and ten export/ownership tests. Mutated descriptors
  verify bounds, padding, UTF-8, prefixes, multiple buffers, external offsets,
  nullable masks and rejection of required nulls.
- **212 targeted Python tests passed** across StringView, rich ingress/export and
  C Data; rebuilt full Python regression: **3,411 passed / 1 skipped**, three
  existing warnings, 85.88 seconds.
- The contracts, source metadata, Cargo.lock and IPC fixture regenerate
  byte-for-byte. The actual Cargo feature tree confirms jsonb `databend` with
  neither `arbitrary_precision` nor `float_roundtrip` enabled in this executable.
  Fifteen pinned dependencies and 411 Rust source files were verified against
  their checksum-verified crate archives.

The initial budget tests used the default 1,024-row batch against a deliberately
tiny cap and were rejected by the existing selection guard before export. They
now request one row and reach the intended view/trailer allocation checks. This
was a test setup correction, not removal of the guard. Logs are retained in
`.build/lance-json-validation`.

StringView is a completed typed physical boundary dependency. Native JSONB,
dynamic `arrow.json`, durable schema/history/Lance files and the rest of the
Qdrant/Lance/general DB/UI/security/cluster/operations/platform/quality/performance
ledger remain open. The source contract corpus is not an Akasha conformance pass.
