# Payload binary formats v1 and v2

Payload bytes are independently length-framed by the existing WAL, segment and
point-record envelopes. All integers and floating bit patterns are little-endian.
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

New writers emit v2, including scalar-only and empty payloads; empty v2 is 12
bytes. Readers dispatch from the inner marker, so mixed v1/v2 WAL records and
segments are supported. An old record migrates when rewritten by a mutation or
checkpoint/compaction. No in-place file edit, new user sequence, fabricated
mutation or schema/catalog revision is needed. WAL fsync and manifest-last
publication remain the durable boundaries. Reader-held old segments remain
valid until their existing leases retire them.

The outer WAL/segment layout and version do not change: their payload is already
independently length-framed and checksummed. References to "payload-v1" in the
older envelope documents describe the historical payload, superseded by this
inner format version for new writes. Old binaries reject v2's impossible v1
field count; backward execution after a v2 write requires a compatible reader
or restoring a pre-upgrade backup. V1 encoding is retained only for explicit
format fixtures, not as a public-writer fallback.
