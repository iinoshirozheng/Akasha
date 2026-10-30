# JSONB Python, HTTP and logical export boundaries — D01c3e

Base `459cfe9`; Mojo 1.0.0 (ed45d567), macOS ARM64. Features/correctness only.

## Delivered behavior and source boundary

The public Python `JsonbValue` is an immutable carrier for the original jsonb
0.5.6 databend body, matching the native value and Lance's separate binary-body /
nullable-slot representation. It does not reimplement the binary codec, parse
JSON text or run a Rust dependency. It requires bytes and bounds their length;
Mojo validates the complete source body before any database write.

The existing native Python payload converter accepts the carrier at field roots
and within arrays/objects, counts all internal JSONB nodes/container levels and
returns independently owned bytes. Point/document upsert, atomic point batches,
set/overwrite mutations, reads, WAL/segment reopen and physical backup/restore
use that one path. JSONB null remains a value; ordinary null retains the existing
source mutation semantics. Filter/formula configuration keeps its strict
ordinary-JSON converter and does not accept the carrier.

The Python/HTTP transport is explicitly selected with `encoding: "typed"`.
`PayloadField.to_wire()` uses it for fields containing JSONB; ordinary fields
keep their existing response shape. `typed=True` always selects it, and
`from_wire()` decodes it. Arrays and objects contain `{type, value}` children;
JSONB is hexadecimal source bytes. Payload update requests select typed encoding
beside `payload`. No dictionary becomes a JSONB marker because of its keys.

NDJSON new exports use v3 with typed encoding on every field. Frozen v1 scalar
and v2 ordinary-JSON readers remain. Earlier versions reject JSONB/new encoding
members; v3 requires its encoding marker. Complete imports still validate before
the existing single native batch commits. This does not add a compatibility
fallback, a new storage format or Qdrant/Lance file protocol equivalence.

Ordinary nested Python/JSON integers retain the existing numeric-value contract,
not an internal small-positive signedness label. The nested wire tag is therefore
`integer`; explicit int/uint tags are accepted only at field roots. Nested
int/uint declarations are rejected rather than silently changing their labels.
JSONB internals retain exact bytes, including signedness and old representations.
Explicit floating wire fields accept finite integer/float JSON input and convert
to Float64, retaining signed zero and the existing numeric-field behavior.

## Verification

- **46 new Python tests passed.** All **6,246 current-source and 85 legacy
  JSONB bodies** pass public batch writes, owned reads, NDJSON v3 export/import,
  checkpoint and reopened reads with exact body equality. Source fixtures and
  native codec come from the already verified D01c3c/d ports.
- Coverage includes storage null versus JSONB null, arbitrary marker-like keys,
  nested object order/signed zero, named/default collection paths, caller/result
  ownership, WAL-only versus checkpoint reopen, physical backup and payload edits.
- Invalid later batch bodies never publish a prefix or change WAL/sequence.
  Corrupt tags/lengths/UTF-8, invalid wire tags/hex/shapes, full-range integers,
  cycles and depth/node/byte exhaustion are rejected. Native internal JSONB
  limits count together with the outer payload. Python conversion that closes
  its owner is rechecked before mutation. JSONB is rejected in filter/formula
  configuration rather than widening those JSON contracts.
- HTTP upsert/get and set/overwrite round trips retain the same values; invalid
  binary or transport input returns 400 and preserves previous data. Independent
  frozen v2/v3 NDJSON files supplement the existing v1 fixture and verify the
  reader independently of the current exporter.
- **17 native tests passed** across rich payload, JSONB payload, payload updates
  and payload filters. **120 targeted Python tests passed**; these overlap the
  complete Python suite and are not added to its count.
- Python module build passed. Full Python passed **3,457 / 1 skip**, with three
  existing warnings. The final full Python rerun after the floating-wire conversion adjustment
  also passed: 3,457 / 1 skip.

Two new test calls initially omitted required public constructor arguments;
the tests were corrected without changing the product API. Accepted regression
commands, output and exit codes are retained in `.build/jsonb-boundary-validation`.
The prior `459cfe9` durable source and 130 native / 24 crash / C ABI acceptance
remain applicable: this change only touches Python/binding/HTTP transport,
not native durable codecs or publication protocols. No redundant crash/C rebuild
is claimed. Source/fixture/current-target hashes and final diff checks are
recorded in the port registry before commit.

## Remaining full scope

This completes binary JSONB transport through these existing public paths.
The source jsonb text parser, fast-float conversion, text serializer and complete
Arrow `arrow.json` / `lance.json` extensions remain next. JSONB traversal/indexes,
decimal operations, complete C/distributed/Qdrant protocol value APIs, arbitrary
top-level keys and the rest of D01 remain open. All other Qdrant/Lance/general DB/
UI/security/cluster/operations/platform/quality/performance rows remain open.
No optimization or performance gates ran; native Linux acceptance stays deferred.
