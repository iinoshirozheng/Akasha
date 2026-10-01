# Collection field catalog: collection.bin v2

This is the reader-first catalog contract for the named/typed vector work. The
live collection writer still emits v1. Reading catalog metadata is not evidence
that the corresponding field data, query or migration path is implemented.

All integers are little-endian. `collection.bin` remains the collection identity
and the guard against old writers. V1 stays exactly as specified in
[collection-config-format.md](collection-config-format.md). A v1 identity maps to
the two legacy fields below, revision zero, cutover sequence zero; re-encoding it
must preserve v1 bytes rather than implicitly enabling field-aware writes.

## V2 header and descriptors

| Offset | Bytes | Value |
| ---: | ---: | --- |
| 0 | 4 | `AKCF` |
| 4 | 2 | version `2` |
| 6 | 2 | flags `0` |
| 8 | 4 | total file length, including trailing CRC |
| 12 | 4 | field count, `2..1024` |
| 16 | 8 | schema revision, greater than zero |
| 24 | 8 | last accepted legacy sequence at migration; zero for a new collection |
| 32 | variable | descriptors in strictly increasing field-ID order |
| final 4 | 4 | CRC-32/ISO-HDLC over `[4, final 4)` |

Each descriptor has this fixed prefix, followed by name and index configuration:

| Relative offset | Bytes | Value |
| ---: | ---: | --- |
| 0 | 4 | stable field ID |
| 4 | 1 | field kind |
| 5 | 1 | authoritative scalar type |
| 6 | 1 | metric |
| 7 | 1 | index kind |
| 8 | 4 | coordinate dimension; binary uses logical bits; sparse uses zero |
| 12 | 2 | UTF-8 name byte length |
| 14 | 2 | index-configuration byte length, zero or 60 |
| 16 | 4 | flags `0` |
| 20 | 4 | reserved `0` |
| 24 | variable | UTF-8 name followed by index-configuration bytes |

Names for IDs >= 2 are nonempty, unique, NUL-free UTF-8, at most 65,535 bytes.
Names are case-sensitive and byte-exact, with no Unicode normalization. They are
lookup keys, never filesystem paths. Descriptor order depends on IDs, not names;
names and IDs are immutable within a published catalog. No contiguous-ID rule is
imposed, so readers must not use an untrusted field ID as a List index.

ID 0 is the legacy default dense field: empty name, F32 authority, positive
dimension, HNSW index, and the legacy metric/configuration. ID 1 is the legacy
default sparse field: empty name, F32 weights, Dot, dimension zero and inverted
index. These two empty names are internal legacy identities, not ambiguous named
lookups. An empty name passed to named lookup is invalid. The two descriptors
must always exist, but a point need not contain either vector field.

## Closed tag matrix

- Kind: `0` dense, `1` sparse, `2` multivector with MaxSim, `3` packed binary.
- Authority scalar: `0` F32, `1` BF16, `2` F16, `3` I8, `4` U8, `5` packed bits.
- Metric: `0` Dot, `1` squared L2, `2` cosine, `3` Hamming, `4` Jaccard.
- Index: `0` exact, `1` HNSW, `2` sparse inverted.

| Kind | Authority scalar | Metric | Dimension | Index |
| --- | --- | --- | --- | --- |
| Dense | F32/BF16/F16/I8/U8 | Dot/L2/cosine | `1..UInt32.MAX` | exact or HNSW |
| Sparse | F32 | Dot | 0 | inverted |
| Multivector | F32/BF16/F16/I8/U8 | Dot/L2/cosine | component dimension, `1..UInt32.MAX` | exact |
| Binary | packed bits | Hamming/Jaccard | bit dimension, `1..UInt32.MAX` | exact |

HNSW descriptors contain one complete 60-byte v1 configuration, including its
magic/version/CRC and all existing tuning constraints. Its dimension and metric
must equal the descriptor; its scalar tag is the *graph encoding*, independently
of authority dtype. Every other index kind has zero configuration bytes. Unknown
tags, invalid combinations and unused/reserved data are errors, not fallback
requests. These metadata tags reserve a concrete representation for every agreed
field kind; data decoders and writers must separately reject kinds they cannot
yet process. No new field kind becomes writable merely because its catalog parses.

## Bounds, ownership and migration

The maximum representable file length is
`36 + 1024 * (24 + 65535 + 60)` bytes. Check the file bound, count, declared total
length, CRC, descriptor bounds, UTF-8 and all semantic constraints before returning
a catalog. Truncation anywhere, trailing bytes, duplicate IDs/names, missing legacy
descriptors or a mismatched nested HNSW identity are corruption. Return owned
names/configurations; no descriptor may retain a view of a decoder input buffer.

An explicit migration records the fully validated legacy accepted sequence in
the cutover field before accepting any field-aware mutation. All retained legacy
dense/sparse mutations must be at or below this boundary; all new field-aware
mutations must be above it. The boundary never substitutes for replaying all
accepted legacy state. Migration performs full preflight before publishing this
identity and before repairing any WAL tail. Publish via write/fsync of a temporary
file, atomic rename and directory fsync. A failure after rename may have committed
the new identity; retry must validate the exact identity and finish the barrier.

The catalog reader alone performs no publication, WAL repair or schema upgrade.
The WAL/segment record contract and migration integration are separate required
slices. Independent Python fixtures live under `tests/fixtures/field-catalog/`;
their generator imports no production encoder.
