# HNSW sidecar formats

## Version 1 (frozen F32)

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
or I8 collection is rejected even when the graph is empty. Version 2, defined
below, is the only compact-vector representation; it does not reinterpret the
v1 vector section.

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

## Version 2 (compact graph vectors)

Version 2 stores BF16, F16, or symmetric I8 graph vectors. It retains the v1
node, count, and edge encodings, but has a distinct 192-byte header, a
scalar-width-aware vector section, and an optional scale section. F32 is not a
valid v2 scalar. All multi-byte values and native BF16/F16 bit patterns are
little endian.

### File layout

| Region | Alignment | Contents |
|---|---:|---|
| Header | 8 | 192-byte fixed-width v2 table below |
| Nodes | 8 | `slot_count` 40-byte node records, exactly as in v1 |
| Vectors | 8 | Slot-major compact scalar bytes |
| Scales | 8 | I8-dot per-slot F32 scales, or empty |
| Counts | 8 | Per-slot/per-level `UInt32` neighbor counts |
| Edges | 8 | `UInt32` neighbor slot ordinals |
| Checksum | 4 | CRC-32/ISO-HDLC |

Every section begins at the smallest eight-byte-aligned offset after the
preceding section. Empty sections still have that canonical offset. Sections
cannot overlap or alias, alignment bytes are zero, the checksum immediately
follows the edge section, and no trailing bytes are allowed.

### Header

| Offset | Width | Field | Required value or meaning |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `AKHG` |
| 4 | 2 | version | `2` |
| 6 | 2 | flags | `0` |
| 8 | 4 | header bytes | `192` |
| 12 | 4 | reserved | `0` |
| 16 | 8 | config fingerprint | `CollectionConfig.fingerprint()` |
| 24 | 8 | checkpoint sequence | Exact manifest checkpoint sequence |
| 32 | 4 | dimension | Vector dimension |
| 36 | 1 | metric tag | Durable `MetricKind` tag |
| 37 | 1 | scalar tag | Exactly `1=BF16`, `2=F16`, or `3=I8` |
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
| 152 | 1 | vector scalar width | `2` for BF16/F16; `1` for I8 |
| 153 | 1 | scale width | `4` for I8 dot; otherwise `0` |
| 154 | 6 | reserved | All zero |
| 160 | 8 | scales offset | Byte offset |
| 168 | 8 | scales length | Byte length |
| 176 | 8 | reserved extension | `0` |
| 184 | 8 | reserved extension | `0` |

Lengths are exact, not capacities:

- `nodes_length = slot_count * 40`;
- `vectors_length = slot_count * dimension * vector_scalar_width`;
- `scales_length = slot_count * scale_width`;
- `counts_length = sum(level + 1) * 4`;
- `edges_length = directed_edge_count * 4`.

All additions and multiplications are checked before allocation or indexing.
A wrong scalar tag, width, length, offset, alignment, or overlap is corruption,
even when another interpretation could fit inside the file.

### Compact scalar rules

| Scalar | Metrics | Vector encoding | Scale section | F32 vector bytes saved |
|---|---|---|---|---:|
| BF16 | dot, squared L2, cosine | Native Mojo BF16 bits, 2 bytes/component | Empty | 2x |
| F16 | dot, squared L2, cosine | IEEE binary16/native Mojo F16 bits, 2 bytes/component | Empty | 2x |
| I8 | dot | Signed symmetric codes `[-127,127]`, 1 byte/component | One F32 `max(abs(v))/127` per slot | 4x vector tape |
| I8 | cosine | Normalize first, then signed symmetric codes with fixed scale `1/127` | Empty | 4x |

All distance accumulations finish in F32. I8 products accumulate in Int32 and
are multiplied by the query and member scales exactly once. The configured I8
dimension is at most 133,144, proving `dimension * 127 * 127 <= Int32.MAX`.
I8 with squared L2 is invalid. Code `-128`, non-finite scales, negative scales,
non-finite decoded half values, and zero-norm cosine input are rejected. An I8
dot scale of zero is valid only when every code is zero. I8 cosine uses exactly
the fixed `1/127` scale and requires at least one non-zero code.

The in-memory prepared I8 value `[code_0, ..., code_(dimension-1), scale]` is an
internal dispatcher/storage contract, not a durable scalar array or public
vector shape. Raw MemTable, WAL, segment, exact-search, and rerank vectors remain
dimension-wide F32. Query preparation happens once per graph search;
member-to-member construction reads stored codes and stored scales directly and
does not requantize either vector.

The size gate applies to the vector section itself. At dimension 16, an F32
vector occupies 64 bytes, BF16/F16 each occupy 32 bytes, and the I8 vector tape
occupies 16 bytes. I8 dot additionally stores a four-byte scale per point, so
its actual compact vector-plus-scale payload is 20 bytes/point: 3.2x smaller
than 64 bytes, not exactly 4x. I8 cosine has no per-vector scale section and is
16 bytes/point.

### Checksum, limits, and validation order

V2 uses the same CRC-32/ISO-HDLC definition as v1: the trailer covers every
preceding byte, including the complete header and zero padding, and excludes
only itself. Owned and mapped readers apply the same validation before any
distance access:

1. enforce the 12-byte minimum, 512 MiB maximum, and validate the whole-file
   checksum;
2. validate common magic and dispatch on the exact version;
3. validate that version's fixed header width, flags, reserved bytes, expected
   sequence, fingerprint, and repeated configuration identity;
4. require a compact v2 scalar tag and its exact vector/scale widths;
5. checked-derive all exact lengths and canonical aligned offsets, reject
   overflow, overlap, aliasing, nonzero padding, out-of-file ranges, or trailing
   bytes, then apply the conservative allocation budget;
6. validate nodes, decoded scalar/code/scale invariants, counts, edges, entry
   point, packed storage, and bidirectional links.

The implementation limits remain 512 MiB, 10,000,000 slots, the reserved
UInt32 graph address space, a 64-bit host `Int`, and the v1 conservative decode
allocation bounds. Unsupported versions and tags are rejected; readers never
guess widths from section lengths.

### Writer policy and compatibility

| Requested collection scalar | V1 reader/writer | V2 reader/writer |
|---|---|---|
| F32 | Read and write | Reject |
| BF16 | Reject | Read and write |
| F16 | Reject | Read and write |
| I8 dot/cosine | Reject | Read and write |
| I8 squared L2 | Configuration error | Configuration error |
| Unknown scalar or future version | Reject | Reject |

The writer selects v1 only for F32 and v2 only for compact graph scalars,
including empty graphs. Owned and mapped readers require the header tag to
match the expected collection configuration. The checked-in v1 fixtures
`tests/fixtures/hnsw-v1-empty.bin` and
`tests/fixtures/hnsw-v1-edges-tombstones.bin` remain byte-for-byte frozen.
Future format evolution adds a new version and a new immutable table; it does
not reinterpret or edit either v1 or v2 in place.

## Publication and compatibility

Writing a sidecar synchronously writes the requested path. The checkpoint
publisher supplies a temporary filename, fsyncs dense, sparse, and HNSW files,
renames all three, syncs the directory, and then commits their reference through
manifest v3. The filename sequence, header sequence, and manifest sequence must
agree. WAL rotation follows the manifest commit; cleanup removes only a prior
valid manifest's explicitly named, superseded sidecar.

The legacy `hnsw.cache` envelope and payload remain readable and rebuildable for
older manifests without a sidecar. Once a v3 manifest commits a sidecar,
recovery does not open or prefer the legacy cache. Missing files and stale
identity/checksum/count metadata rebuild from authoritative records. A sidecar
whose committed identity matches but whose internal CRC or layout is corrupt is
a storage error. Newer WAL mutations replay incrementally into the owned graph.
