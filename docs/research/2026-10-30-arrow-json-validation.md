# D01c3j Arrow JSON / JSONB interchange validation

Base: `d5b7775`. Mojo `1.0.0 (ed45d567)`, PyArrow `21.0.0`, macOS arm64.
This completes the JSON extension boundary in ordered steps 5–6 of the
[JSON interop plan](../plans/2026-10-30-json-interop-source-port.md), building on
D01c3a–i. D01, A03, the full product ledger and performance gates remain open.

## Implementation and source

The existing native typed Arrow traversal now recognizes canonical `arrow.json`
(Utf8, LargeUtf8, Utf8View) and `lance.json` (LargeBinary). Both ingress APIs use
the previously verified source JSONB parser/checked binary constructor. Scanner
output uses the source RawJsonb writer or exact original binary bytes. Python
supplies type descriptors and borrowed buffers; no row JSON parser, formatter or
materialization replaces the native path. Plain strings retain their own type.

Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`,
`rust/lance-arrow/src/json.rs`, supplies recognition, nullable slots, recursive
Struct/List/LargeList/FixedSizeList/Map conversion and metadata rules. Arrow
58.4.0 canonical JSON additionally permits Utf8View; the pinned Lance adapter
itself recognizes only Utf8/LargeUtf8. Existing StringView physical-layout
source tests remain in the targeted suite. Map storage uses the Arrow entries
struct and offsets, preserving duplicate/non-string keys and declaration order.

A source-text `null` is a valid JSONB value, distinct from a storage-null slot
at every depth. Internal JSONB nodes/bytes count against the enclosing document
budget; parent container construction checks the combined depth. All accepted
values pass existing atomic batch publication and payload v3 persistence.

Output owns its C Data buffers. Binary copies keep original bytes, including
legacy/noncanonical representations. Text retains the source's lossy rules for
nonfinite numbers, decimals and extension values. Rendering is bounded by the
scanner's available output budget, with cancellation/deadline checks during text
and binary-to-hex expansion. Standalone formatting keeps its previous default
output contract; its new native limit/control parameters serve the scanner.

## Explicit boundary adaptations

- PyArrow 21 C Data normalizes Map child names to entries/key/value. The canonical
  MapType is retained and checked against its physical child schema, preserving
  entries metadata that the `pa.map_` constructor cannot express.
- Registered `arrow.json` consumes reserved extension metadata. User metadata,
  nested nullability and binary Lance metadata survive requested projections.
  Recognition does not impose extra serialized-parameter rules; pinned Lance
  and installed PyArrow ignore those parameters.
- Akasha's existing null-parent masking skips semantic parsing of inactive child
  cells. Lance recursively converts its full physical child arrays. Arrow
  structural/UTF-8 validation still precedes Akasha ingestion.
- Empty ingestion retains the existing rejection contract; empty scanners expose
  their requested schema. Unknown extensions/unmarked binary stay unsupported.
- Native checked-body errors and invalid-calendar errors replace unchecked raw
  fallback or Rust unwrap panics. Read errors do not alter stored binary values.
- Producer table/schema metadata is not persisted. A scanner projection supplies
  its own schema. This is not table schema evolution or Lance file support.

## Independent evidence

`scripts/arrow_json_reference.py` compiles the **complete unchanged** pinned
Lance `json.rs`, invokes both public batch conversion functions, and writes 36
actual IPC files for 12 UTF-8/Large-UTF-8 cases. Scalars and every supported
container are included, with sliced leaves, nulls, JSON null, extended syntax,
Unicode, nonfinite numbers, duplicate/non-string map keys and metadata on
fields/entries/schema. Public tests import both text and binary fixtures through
both ingress APIs and compare binary/text projections against actual source
outputs at the same C Data boundary. Source archives, Rust files and the lock are
verified before execution; provenance and licenses remain recorded.

The public Arrow route also exercises all 20,757 existing source reader cases:
16,353 accepted bodies and their output text match; 4,404 are rejected atomically.
Of the latter, 1,264 malformed UTF-8 cases are rejected by Arrow structural
validation; valid UTF-8 grammar reaches Mojo. Another 28,901 checked writer body
cases match exact binary projection and source text, covering all existing JSONB
types and legacy encodings. Source panic-to-error behavior remains in the writer
suite, with a calendar-error case verified through the scanner.

## Executed checks

| Check | Result |
| --- | --- |
| `pixi run python scripts/arrow_json_reference.py` and repeat | 12 cases / 36 IPC; all 40 fixture/provenance/lock/readme files byte-identical |
| `pixi run build-python` | passed |
| `pixi run mojo run -I src tests/mojo/test_jsonb_writer.mojo` | 4 passed |
| `PYTHONPATH=python:. pixi run mojo run -I src tests/mojo/test_arrow_payload.mojo` | 4 passed |
| same command, `test_arrow_string_view.mojo` | 3 passed |
| same command, `test_arrow_export.mojo` | 10 passed |
| same command, `test_arrow_c_data.mojo` | 3 passed |
| targeted Arrow JSON/StringView/JSONB writer Python suites | 183 passed, including 144 new tests |
| `PYTHONPATH=python:. pixi run python -m pytest tests/python -q` | 3,629 passed, 1 skipped; 97.37 seconds |

The skip is the existing optional pinned Qdrant benchmark dependency. Three
existing warnings concern Mojo type module attributes and Starlette/httpx.
Tests cover both ingestion routes, nested/sliced/required values, JSONB aggregate
nodes/depth, malformed batches leaving WAL/sequence unchanged, WAL-only and
checkpoint reopen, snapshots, last-child ownership after close, empty schema,
byte limits, expansion, source conversions and source formatting errors.

Logs, JUnit, native command statuses, fixture reproduction and current source/
module hashes are in `.build/arrow-json-validation/`. Retained unsuccessful
attempts include an explicit-copy compile correction, test expectations corrected
to existing C Data/empty-batch/scanner contracts, and an initial native Arrow
command missing `PYTHONPATH`; all corresponding final checks pass.

No durable format or commit/recovery path changed. The previous D01c3d crash
suite (9 modules / 24 checks) and C ABI results remain applicable and were not
rerun. Native Linux x86_64 remains deferred by the user. No optimization or
performance acceptance is claimed.

## Remaining work

Continue native JSONB path traversal/query/index exposure, arbitrary top-level
payload keys, remaining C/distributed value contracts, and every open item in
D01–D05/A01–A03 and the full product ledger. Full Qdrant/LanceDB/general DB,
UI, security, cluster, operations and M5/M6 are not completed by this boundary.
