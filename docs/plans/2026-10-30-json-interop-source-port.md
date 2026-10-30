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

Step 3 now has a verified native binary-value dependency:
`JsonbValue` owns checked databend JSONB bytes and implements original scalar,
number, extension and container codecs/builders. Actual-source fixtures cover
6,246 current and 85 old-format cases; 24 related native tests, module rebuild
and full Python 3,411 passed / 1 skip. Fixtures/metadata/lock reproduce exactly.
Storage null stays an independent outer slot. This does not yet modify payload v1/v2 or expose JSONB through collection
APIs; those durable integration/migration and recovery steps remain next, before
text parsing/rendering and Arrow extension completion.


Step 3 durable integration now has the native implementation and focused proof:
`PayloadValue.jsonb` and payload v3 preserve complete source bodies at roots and
inside ordinary containers. Readers retain v1/v2, and existing rewrite paths
migrate without catalog/sequence changes. Twenty-one native modules / 130 tests
pass, including all 6,331 current/legacy source bodies through the payload codec,
mixed-version recovery, snapshots, compaction, physical backup, atomic rejection
and corrupt/torn WAL handling. Full Python (3,411 passed / 1 skip), nine crash modules / 24 tests, module and
worker builds, and C ABI also pass; see the
[storage report](../research/2026-10-30-jsonb-storage-validation.md).
Public value boundaries, the jsonb textual profile and Arrow JSON remain open.

### Next boundary requirements

- Preserve a distinct Python value for native JSONB bytes at any nesting level;
  use an explicit value type, not a reserved ordinary-dict key that can collide
  with valid JSON. Validate the binary body and aggregate limits in Mojo.
- Keep strict ordinary JSON configuration/filter conversion distinct from the
  payload conversion that will permit JSONB. Preserve explicit scalar conversion
  protocols and existing callback/re-entry validation.
- Define explicit typed wire representations for JSONB in HTTP and logical
  export/import, including nested values and storage-null versus JSONB-null.
  Retain legacy import formats with versioned decoding; do not serialize a
  Python bytes object implicitly or silently stringify extended values.
- Complete the source text parser/numeric/serializer before Arrow JSON text
  conversion. Cover native `lance.json` binary cells and `arrow.json` textual
  cells, slices/masks and UTF-8/large UTF-8/StringView storage as specified above.


D01c3e completes the Python/HTTP/NDJSON binary-value boundary requirements above:
explicit immutable bytes carrier, native validation and combined resource
budgets, distinct ordinary JSON configuration, typed nested wire encoding and
v3 logical export with frozen v1/v2 reads. All 6,331 source bodies pass public
writes/reads and logical round trips; 46 new Python tests, 17 related native
and 120 targeted Python pass. Final full Python is 3,457 passed / 1 skip.
[Evidence](../research/2026-10-30-jsonb-boundary-validation.md).

Step 4 is now next: port actual jsonb text grammar/numerical parsing and source
serialization (including the fast-float dependency), preserving extended and
standard profiles rather than substituting the serde_json reader. Then complete
step 5's native Arrow binary/text extension integration and step 6's full public
acceptance. Full C/distributed/protocol value boundaries and the complete
product ledger remain required; this binary transport slice does not close them.
