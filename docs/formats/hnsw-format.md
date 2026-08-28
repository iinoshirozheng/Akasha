# HNSW sidecar format v1

Status: frozen. Multi-byte integers and `Float32` bit patterns are little
endian. A committed file is named `hnsw-<checkpoint-sequence>.bin`.

The sidecar is an immutable derived index. Dense segments, the WAL, collection
identity, and manifest remain authoritative. Version 1 stores the packed HNSW
graph exactly, including historical deleted and replaced slots, so reopening a
checkpoint does not itself force maintenance rebuilding.

## File layout

The file consists of a 160-byte header, four ordered sections, zero alignment
padding, and a four-byte checksum trailer:

| Region | Alignment | Contents |
|---|---:|---|
| Header | 8 | Fixed-width table below |
| Nodes | 8 | `slot_count` 40-byte node records |
| Vectors | 8 | Slot-major `Float32` graph vectors |
| Counts | 8 | Level-major-within-slot `UInt32` neighbor counts |
| Edges | 8 | `UInt32` neighbor slot ordinals |
| Checksum | 4 | CRC-32/ISO-HDLC |

Sections do not overlap or alias. Each section begins at the smallest
eight-byte-aligned offset after the preceding section. Alignment bytes must be
zero. The checksum immediately follows the edges section; there are no trailing
bytes.

## Header

| Offset | Width | Field | Required value or meaning |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `AKHG` |
| 4 | 2 | version | `1` |
| 6 | 2 | flags | `0` |
| 8 | 4 | header bytes | `160` |
| 12 | 4 | reserved | `0` |
| 16 | 8 | config fingerprint | `CollectionConfig.fingerprint()` |
| 24 | 8 | checkpoint sequence | Exact manifest checkpoint sequence |
| 32 | 4 | dimension | Vector dimension |
| 36 | 1 | metric tag | Durable `MetricKind` tag |
| 37 | 1 | scalar tag | `0`, the durable `ScalarKind.f32()` tag |
| 38 | 2 | `m` | Upper-level neighbor capacity |
| 40 | 2 | `m0` | Base-level neighbor capacity |
| 42 | 2 | maximum configured level | Collection `max_level` |
| 44 | 4 | reserved | `0` |
| 48 | 8 | slot count | All allocated slots, including history |
| 56 | 8 | live point count | Slots whose lifecycle flag is `current` |
| 64 | 8 | directed edge count | Number of ordinals in the edges section |
| 72 | 8 | entry slot | Slot ordinal, or `UInt64.MAX` when empty |
| 80 | 8 | entry level | Signed level, or `-1` when empty |
| 88 | 8 | nodes offset | Byte offset |
| 96 | 8 | nodes length | Byte length |
| 104 | 8 | vectors offset | Byte offset |
| 112 | 8 | vectors length | Byte length |
| 120 | 8 | counts offset | Byte offset |
| 128 | 8 | counts length | Byte length |
| 136 | 8 | edges offset | Byte offset |
| 144 | 8 | edges length | Byte length |
| 152 | 8 | reserved extension | `0` |

Version 1 is exclusively an F32 graph format. Encoding or decoding a BF16, F16,
or I8 collection is rejected even when the graph is empty. Task 26 must define a
new format version before persisting any compact or quantized vector width; it
must not reinterpret the v1 vector section.

The fingerprint covers the complete immutable collection identity, including
construction and search settings not repeated in the header. Repeated fields
make mismatch diagnostics precise and permit a mapped reader to select its
metric implementation without interpreting the fingerprint.

## Node records

Node records are stored in slot-ordinal order.

| Record offset | Width | Field | Meaning |
|---:|---:|---|---|
| 0 | 8 | public ID | Signed `Int64` document ID |
| 8 | 2 | level | Highest level owned by the slot |
| 10 | 1 | lifecycle | Exactly one of `1=current`, `2=deleted`, `4=replaced` |
| 11 | 1 | reserved | `0` |
| 12 | 4 | reserved | `0` |
| 16 | 8 | count base | Element index in the counts section |
| 24 | 8 | edge base | Element index in the edges section |
| 32 | 8 | node edge count | Sum of this node's per-level counts |

Count and edge bases are packed prefix sums, not byte offsets. Only current
slots participate in live ID lookup, and their public IDs must be unique.
Historical slots may repeat a public ID and remain graph traversal bridges.

## Vector, count, and edge sections

Vectors contain exactly `slot_count * dimension` `Float32` values in slot-major
order. These are prepared graph vectors. The shared metric dispatcher validator
checks every vector on encode and decode: dot/L2 components obey the safe F32
accumulation bound, and cosine vectors are finite, nonzero, and unit-normalized
within the dispatcher's frozen tolerance.

Counts contain one `UInt32` for level 0 through the node's highest level, in
slot order. A level-0 count is at most `m0`; every upper-level count is at most
`m`. The sum of all counts equals the header's directed edge count and each
node's local sum equals its node record.

Edges contain only used neighbors, in the same slot/level/count order. Every
ordinal must address an allocated slot, differ from its source, own the
referenced level, occur once within that adjacency, and have a reverse edge at
the same level.

## Checksum and validation

The trailer is CRC-32/ISO-HDLC over every byte from offset 0 through the final
edge byte, including headers and zero padding. The checksum field itself is not
included.

Readers validate in this order before exposing a graph:

1. bounded file read of at most 512 MiB plus one detection byte, followed by
   minimum/maximum length and whole-file checksum;
2. magic, version, flags, header width, and header reserved bytes;
3. expected sequence and complete collection identity (fingerprint and repeated
   dimension/metric/scalar/graph fields);
4. checked header counts and the conservative pre-staging allocation lower
   bound, then offset addition, exact section order, alignment, file bounds, and
   implementation limits;
5. node levels/lifecycle flags, packed bases, live count, unique current public
   IDs, and the exact post-node allocation budget;
6. prepared-vector invariants, bounded neighbor counts, and
   ordinal/level/self/duplicate rules;
7. owned materialization, entry-point invariants, packed-storage validation,
   and full bidirectional-link validation.

No allocation or indexing derived from an encoded count occurs until its
multiplication and range have been checked. Before materialization, the decoder
first applies a lower-bound peak check before allocating node lists or current-ID
maps, conservatively treating every untrusted slot as current. After scanning
node records it repeats the check with exact capacity-sized neighbor storage.
The estimate includes the input bytes, staging and final vector/count/edge
tapes, both current-ID maps, final packed capacity, and the bidirectional
validator's level/edge dictionaries and reverse-edge tape. Because Mojo 1.0 does
not expose stable `List`/`Dict` allocator overhead, v1 reserves conservative
per-entry peaks: 128 bytes per slot, 192 bytes per possible current-map entry,
104 bytes per owned level, and 108 bytes per directed edge. The resulting peak
may not exceed 512 MiB or 32 times the encoded file size (with a 4 KiB minimum
budget). This prevents sparse sections or hostile counts from causing allocation
amplification.

The current owned decoder also limits a file to 512 MiB and 10,000,000 slots;
slot ordinals must fit the reserved `UInt32` graph address space. The supported
`osx-arm64` and `linux-64` targets provide a 64-bit Mojo `Int`; v1 checks this at
runtime because durable public IDs are signed 64-bit values materialized as
`Int`. Invalid, stale, mismatched, or structurally corrupt bytes never produce a
partially usable ANN index.

## Publication and compatibility

Writing a sidecar synchronously writes the requested path. The checkpoint
publisher supplies a temporary filename, renames completed immutable files, and
commits their reference through manifest v3 in Task 22. The filename sequence,
header sequence, and manifest sequence must agree.

The legacy `hnsw.cache` envelope and payload remain readable and rebuildable
during the transition. This v1 codec never writes or replaces `hnsw.cache`, so
it cannot create a second independently authoritative graph. The sidecar
supersedes that optional derived cache only after the manifest v3 commit point.
Once a v3 manifest commits a compatible sidecar, recovery must not prefer a
stale legacy cache over it. Older manifests without a committed sidecar continue
to treat `hnsw.cache` as optional derived state and may rebuild from authoritative
records.
