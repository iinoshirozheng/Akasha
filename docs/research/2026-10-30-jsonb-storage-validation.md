# Native JSONB payload and durable migration — D01c3d

Base `a64fd8f`; Mojo 1.0.0 (ed45d567), macOS ARM64. Features/correctness only.

## Source and implementation

The existing native jsonb 0.5.6 databend port now participates in
`PayloadValue` through a distinct JSONB kind. Lance's pinned
`rust/lance-arrow/src/json.rs` stores complete JSONB bodies separately from
Arrow validity; this change retains that distinction inside Akasha's owned
payload representation. It does not implement a new JSONB algorithm or import
Lance segment files. The source codec, numeric fields, extensions, old encodings
and sorted object builder remain the existing source-backed implementation.

`PayloadValue.jsonb(value)`, `is_jsonb()` and `as_jsonb()` support field roots
and values nested inside ordinary payload arrays/objects. Copying, cloning and
subtree extraction preserve owned bytes. Plain null, valid JSONB null and a
missing field remain separate. JSONB is a leaf for plain payload paths; its own
source query/index behavior remains open.

The flat payload arena now distinguishes physical arena entries from logical
value-node counts: one JSONB entry can contain many internal values. Internal
JSONB nodes and container depth contribute to the existing aggregate limits.
Subtree extraction retains internal JSONB depth, preventing a reinsertion from
bypassing the 64-level cap. The complete encoded payload remains bounded at
16 MiB and 65,536 logical values across all fields.

## Durable contract

[Payload v3](../formats/payload-format.md) adds tag 9, framed as a little-endian
u32 byte length followed by the complete original big-endian JSONB body. New
writes always use v3, including scalar-only and empty payloads. V1/v2 readers
remain; explicit historical encoders reject JSONB at every nesting level.
Earlier binaries reject version 3 rather than silently dropping the value.

WAL, point-record and segment outer formats are unchanged. Their existing
length/CRC protection and WAL-fsync / manifest-last protocol contain the new
payload. A mutation or checkpoint/compaction that rewrites an old record emits
v3. Unrewritten old segments remain readable. No synthetic mutation, sequence,
catalog/schema revision or in-place file edit performs the migration.

An independent 92-byte v3 fixture combines storage null, JSONB null, timezone
timestamp and a plain negative-zero float in nested values. Its generator reads
the original Rust oracle bodies and uses Python `struct` solely for the Akasha
envelope. It reproduces SHA-256
`1dae485e8d78910a42c4c8965bc237999a2636bda9a5caa49b3ae729fa300d66`.
Frozen v1/v2 files are unchanged and re-encode exactly with explicit versions.

## Verification

- **21 native modules / 130 tests passed**, including 12 new payload/storage
  tests. Logs and commands are in `.build/jsonb-storage-validation`.
- All **6,246 current source bodies and 85 old decimal/timezone bodies** survive
  payload v3 with exact byte/typed representation and node/depth accounting.
  Values that fit the aggregate depth cap are also checked inside mixed payload
  arrays and objects, with a following sibling to verify arena traversal.
- Independent v1/v2/v3 fixtures, old-version rejection, every truncated v3
  prefix, invalid tags/lengths/UTF-8, exact 16 MiB boundary, excess aggregate
  nodes/depth and extracted-subtree reinsertion are exercised.
- A WAL containing v1/v2/v3 batches reopens and checkpoints to v3 without
  changing collection identity or point sequences. WAL-only reopen, owned
  reads after close, mapped segments after inode removal, snapshot isolation,
  compaction and physical backup/restore retain JSONB values.
- An invalid later mutation leaves the entire batch, sequence and WAL unchanged.
  Complete bad WALs fail without repair, including valid outer CRCs over an
  invalid inner version or JSONB header. Torn multi-point batches expose no
  prefix; recovery retains the baseline and accepts subsequent writes.
- Native maintenance worker and Python module builds passed. Full Python:
  **3,411 passed / 1 skipped**, three existing warnings, 92.60 seconds. The skip
  is the optional Qdrant Edge integration. This is regression coverage for the
  existing public APIs; it is not a JSONB Python API claim.
- **9 crash modules / 24 tests passed**. JSONB null and timezone values now
  participate in the existing ten-stage migration/checkpoint publication test,
  from old identity through accepted WAL, durable output, temporary/committed
  manifest, WAL rotations and retired-source removal. Recovery verifies both
  value bits and storage-null distinction, then writes and reopens again.
  The first suite stopped at a test-only Array/List inference error after six
  passing modules. Those results were retained; the corrected module and the
  remaining two modules passed separately. The lease-fence helper rebuilds its
  current fault probe even though its wrapper prints a historical source label.
- `rtk proxy pixi run test-c` passed after rebuilding the native worker and C
  shared library. This preserves the existing C API; full JSONB C values remain
  pending.
- Original source, license, fixture and current port target hashes verified;
  the independent v3 fixture reproduces exactly and `git diff --check` passes.
  Commands, raw logs, the initial failure and resumed results are retained in
  `.build/jsonb-storage-validation`, with `accepted-results.json` recording the
  accepted union. No product source changed after these successful runs.

Initial test compilation exposed Optional.take() on a temporary and an
inferred fixed Array inside Optional. The tests now explicitly clone the
borrowed child and declare List[DocumentField] before transfer. No product compatibility fallback
was added. Existing rich-payload and point-fixture tests now select the frozen
v2 writer explicitly or independently expect the current v3 header.

## Remaining work

Native collection storage is implemented; public Python/HTTP/NDJSON and Arrow
JSONB boundary representations still need implementation. Existing ordinary
JSON boundaries retain their strict JSON contract, so these clients cannot yet
read/write native JSONB values. Logical export is separate from the physical
backup/restore verified here. Complete C and distributed value APIs also remain.

The jsonb textual parser, fast-float numeric conversion and serializer still
need their source ports before complete `arrow.json` ingestion/export. Decimal
operations, JSONB queries/indexes and all other D01/Qdrant/Lance/general DB/UI/
security/cluster/operations/platform/quality/performance requirements remain.
No optimization or performance gate ran; native Linux acceptance stays deferred.
