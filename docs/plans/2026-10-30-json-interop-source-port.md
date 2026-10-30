# Native JSON and Arrow extension interop

Continue D01/A03 from `54d702b`; keep the complete product ledger active.
Use executing-plans and mojo-syntax; sequential builds, no subagents, no tuning.

## Source findings

- Lance's pinned `lance-arrow/src/json.rs` recognizes `arrow.json` on UTF-8 /
  large UTF-8, skips storage-null cells and parses every valid cell through
  jsonb 0.5.6. JSON text `null` remains a valid JSON value. Nested fields recurse.
- Arrow's current canonical specification also permits StringView storage.
  The installed PyArrow version and actual producer behavior must be checked;
  the older Lance adapter's type list does not remove the full requirement.
- Native `PayloadValue` already preserves object keys (including empty/NUL),
  signed/unsigned integers, finite floats and explicit null. Object absence is
  distinct from null. Array elements currently have no separate missing tag.
  Thus nested extension storage-null and JSON-null cannot both be represented
  losslessly by silently mapping them to the existing null tag.
- Qdrant and Lance pin serde_json 1.0.151, but Lance's JSONB input uses its own
  parser. serde_json's default float conversion and jsonb's fast-float parser
  must not be assumed bit-identical. Retain separate source profiles/evidence.

## Ordered work

1. Port the pinned serde_json byte reader, escapes/surrogates, recursive value
   grammar and default numeric conversion to Mojo's existing PayloadValue.
   Preserve source overflow, signed zero, duplicate-key order and UTF-8 checks.
   Bound source bytes, parsed nodes/content/depth before accepting a value.
   Verify against an actual independent Rust executable, including malformed
   bytes, every truncation and numeric rounding. This is a native dependency,
   not completion of public Arrow JSON support.
2. Pin and execute Lance/jsonb reference cases for numeric and null distinctions.
   Implement the required source conversion profile rather than concealing
   differences behind Python json or an opaque string payload.
3. Resolve representation of nested storage-null before adding extension input
   and output. If durable types change, migrate versioned codecs and validate
   old data, corruption, torn writes, snapshots and restart. Preserve arbitrary
   JSON keys inside values; top-level field keys remain an explicit D01 item.
4. Add standard extension metadata/types, native byte parsing/serialization,
   slices/parent masks and ownership through both ingestion APIs and scanners.
   Cover UTF-8/large UTF-8/StringView, nested extensions, storage null vs JSON
   null, mixed values, empty batches, required fields and malformed inputs.
5. Complete public differential, lifecycle, recovery and full regression gates;
   update provenance, licenses and product ledgers before marking this capability.

No complete JSON/Lance/SQL/product claim follows from the parser alone. Typed
Arrow behavior from D01c1/c2 remains available throughout this work.

## Checkpoint

D01c3a completes the native reader dependency in step 1: 5,630 actual-source
cases, 3,063 accepted trees/F64 bits and codec round trips, 2,567 rejected byte
inputs. Eighteen related native tests and full Python 3,385 passed / 1 skip;
module build and exact fixture/table reproduction passed. The public native
functions are documented in [native JSON](../native-json.md), with the fixed
numeric profile and resource limits. [Evidence](../research/2026-10-30-json-reader-validation.md).

Step 2 is next: actual Lance/jsonb conversion evidence, followed by the durable
null representation and complete extension path. Full D01c3 remains in progress.
