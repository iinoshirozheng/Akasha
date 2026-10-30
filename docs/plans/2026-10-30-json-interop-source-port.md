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
2. Pin and execute Lance/jsonb reference cases for grammar, numbers and null
   distinctions. Preserve actual results from both jsonb entry points; do not
   assume its function named standard mode matches serde_json or strict RFC input.
3. Add a distinct native JSONB logical value, following Lance's JSONB body plus
   independent nullable slot. A valid body containing JSON null must remain
   distinct from an absent/invalid Arrow slot, including list elements. Port
   the upstream binary value/validation/codec and source conversion rules; do
   not add an undefined value to plain JSON arrays or silently store JSON text.
   Migrate durable codecs and validate old data, corruption, torn writes,
   snapshots and restart before exposing the new type. Preserve arbitrary JSON
   keys inside values; top-level field keys remain an explicit D01 item.
4. Port the required jsonb numeric/grammar/serialization profile and its
   fast-float dependency; keep the existing serde_json API's contract. Record
   extended syntax, nonfinite values and duplicate-key behavior explicitly.
5. Add standard extension metadata/types, native byte parsing/serialization,
   slices/parent masks and ownership through both ingestion APIs and scanners.
   Cover UTF-8/large UTF-8/StringView, nested extensions, storage null vs JSON
   null, mixed values, empty batches, required fields and malformed inputs.
6. Complete public differential, lifecycle, recovery and full regression gates;
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

Step 2 now has actual Lance/jsonb evidence: 5,641 inputs through both entry
points, with the original Lance module compiled unchanged. The selected profile
is jsonb 0.5.6, default features off, databend enabled, matching Lance's declared
dependency. Extended mode accepts 3,426/rejects 2,215; standard mode accepts
3,397/rejects 2,244; neither panics on this corpus. On the common 5,630 inputs,
384 are accepted only by extended jsonb, 31 only by serde_json, and 695 accepted
trees differ even after normalizing small unsigned integers and object order.

Lance round-trips `[storage null, JSON null, [null], {"x":null}]` as distinct
storage/text states and recognizes UTF-8/large UTF-8 but not StringView JSON
storage. PyArrow 21 supports all three. The StringView physical dependency is
now implemented through native typed input/output, including the source's
inline/external view layout and C Data trailer. This is not JSONB or extension
completion. Next is the distinct native JSONB logical type and durable codec in
step 3, then its source numeric/grammar/serialization path and public extension
integration. Full D01c3 and the product ledger remain in progress.
