# Payload binary formats v1, v2 and v3

Payload bytes are independently length-framed by the existing WAL, segment and
point-record envelopes. Outer integers and floating bit patterns are little-endian;
the v3 JSONB body keeps its source big-endian layout.
The enclosing envelope retains its own version, checksum and commit protocol.
This is an Akasha durable representation, not a Qdrant storage-format import.

## Frozen v1 reader

V1 starts with `field_count:u32`, at most 1,024. Each field is
`name_length:u16, name:utf8, value_tag:u8, value_body`. Names are nonempty, contain
no NUL and are unique in insertion order. Tags 1..4 use the scalar bodies below.
An empty v1 payload is four zero bytes. Existing v1 fixtures remain unchanged.

## V2 writer and reader

V2 starts with `marker:u32=0xffffffff, version:u16=2, reserved:u16=0,
field_count:u32`. The marker cannot collide with a valid v1 field count.
Top-level fields retain the v1 name framing and name rules. Values are recursive:

| Tag | Value | Body |
| --- | --- | --- |
| 1 | String | `byte_length:u32, utf8:bytes` |
| 2 | Signed integer | `i64` |
| 3 | Floating number | finite `f64`, preserving signed zero |
| 4 | Boolean | `u8`, exactly 0 or 1 |
| 5 | Null | no bytes |
| 6 | Array | `count:u32`, followed by that many tagged values |
| 7 | Object | `count:u32`, then `key_length:u32, key:utf8, tagged_value` per member |
| 8 | Unsigned integer | `u64` |

Nested object keys may be empty, contain NUL, punctuation and Unicode. Keys are
unique and stored in insertion order; array order is significant. A decoder
rejects duplicate keys instead of silently discarding persisted data. Public
in-memory map construction follows Qdrant/serde_json insertion: later duplicates
replace the original slot. Null, a missing key and an empty array/object differ.

Limits: 16 MiB including the entire payload header/framing, 1,024 top-level
fields, 65,536 value nodes summed across all fields, and 64 container levels
within a field value (a scalar has depth zero). Counts are checked against the
remaining input and node budget before allocation. Invalid UTF-8, unknown tags,
unknown versions, nonzero reserved bits, invalid bools, nonfinite numbers,
truncated content and trailing bytes fail closed. The complete enclosing CRC
must be checked by recovery before accepting its payload.

## Migration and downgrade

New writers emit v3, including scalar-only and empty payloads; empty v2/v3 is 12
bytes. Readers dispatch from the inner marker, so mixed v1/v2/v3 WAL records and
segments are supported. An old record migrates when rewritten by a mutation or
checkpoint/compaction. No in-place file edit, new user sequence, fabricated
mutation or schema/catalog revision is needed. WAL fsync and manifest-last
publication remain the durable boundaries. Reader-held old segments remain
valid until their existing leases retire them.

The outer WAL/segment layout and version do not change: their payload is already
independently length-framed and checksummed. References to "payload-v1" in the
older envelope documents describe the historical payload, superseded by this
inner format version for new writes. V1 binaries reject the impossible field
count; v2 binaries reject version 3 even for scalar-only payloads. Backward
execution after a v3 write requires a compatible reader or restoring a
pre-upgrade backup. V1/v2 encoding is retained only for explicit format fixtures,
not as a public-writer fallback. They reject JSONB at any nesting level.

## V3 JSONB values

V3 has the same header with `version:u16=3`, preserves tags 1..8 and adds:

| Tag | Value | Body |
| --- | --- | --- |
| 9 | JSONB | `byte_length:u32, checked_jsonb:bytes` |

`checked_jsonb` is the complete jsonb 0.5.6 databend body documented in
[native JSONB](../native-jsonb.md). Its headers, compact numeric and extension
fields retain their source endianness and exact bytes. Legacy decimal precision
and timezone representations are read and preserved, not silently canonicalized.
The framing is Akasha's; this does not make an Akasha segment a Lance file.

Tag 9 can appear at the field root or inside ordinary payload arrays/objects.
It remains a distinct logical value. Plain payload null (tag 5), a JSONB body
containing JSON null (tag 9), and a missing field differ. Plain payload paths
treat JSONB as a leaf; JSONB query/index semantics require their own source port.

All source JSONB values are preserved, including NaN/infinities, Decimal,
Binary and temporal extensions. Tags 1..8 retain their finite-float contract.
The complete JSONB body must validate before it can enter a payload: strict
consumption, lengths, tags, UTF-8, unique object keys and resource bounds apply.
The inner format has no separate checksum; the enclosing WAL/segment CRC still
detects accidental byte corruption before recovery.

The 16 MiB payload limit includes the v3 header, field names, tag/length framing
and all JSONB bodies. All JSONB value nodes count toward the same 65,536-node
budget; the wrapper adds no extra logical node. Its internal container levels
add to the enclosing payload's levels for the same depth-64 limit. Extracting
and reinserting an owned subtree preserves those budgets.
