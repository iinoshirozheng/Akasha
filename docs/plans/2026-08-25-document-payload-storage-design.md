# Document Payload Storage Design

## Goal

Phase 4.1 extends Akasha's durable vector records with flat typed payload
fields and point lookup. Payload and vector state must commit atomically through
the existing WAL, MemTable, snapshot segment, and manifest recovery protocol.

## Scope

The public API keeps the Phase 3 vector-only path and adds document operations:

```text
upsert(id, vector)
upsert_document(id, vector, fields)
get(id) -> Optional[DocumentRecord]
```

Search continues to return lightweight `SearchResult` values. Callers use the
result ID with `get` when they need chunk text, image URI, MIME type, or other
payload fields. Partial updates, arrays, nested objects, payload projection,
and metadata filtering remain out of scope.

## Document model

Payload v1 is schemaless and flat. `PayloadValue` is an explicit tagged struct
with four supported variants: `String`, `Int64`, `Float64`, and `Bool`. The
explicit representation is preferred over Mojo `Variant` so ownership,
validation, and binary encoding remain stable and transparent on Mojo 1.x.

`DocumentField` owns a UTF-8 name and a `PayloadValue`. `DocumentRecord` owns a
point ID, latest sequence, vector, and ordered list of fields. Field insertion
order is preserved and lookup is linear in Phase 4.1. Field names must be
non-empty, contain no NUL byte, and be unique within a record.

MemTable entries gain an owned field list. Vector-only `upsert` is a complete
replacement with empty fields, so it clears any older payload. Delete retains
its existing tombstone semantics. `get` returns an owned record copy for a live
ID and `None` for a missing or deleted ID.

## Payload binary codec

The payload begins with a little-endian `u32` field count. Each field contains
a `u16` UTF-8 key length, key bytes, a one-byte type tag, and a typed body:

| Tag | Type | Body |
| ---: | --- | --- |
| 1 | String | `u32` byte length followed by valid UTF-8 bytes |
| 2 | Int64 | Eight little-endian bytes |
| 3 | Float64 | Eight-byte little-endian IEEE-754 value |
| 4 | Bool | One byte, exactly `0` or `1` |

Inputs and decoders enforce at most 1,024 fields, 65,535 bytes per field name,
16 MiB total encoded payload, finite Float64 values, valid UTF-8, unique field
names, known tags, exact lengths, and valid Boolean encodings.

## Persisted format compatibility

WAL and segment formats become version 2 while retaining v1 decoders. New WAL
upserts append `u32 payload_length` and encoded payload after the vector. New
deletes carry an empty payload. A WAL may contain interleaved historical v1 and
new v2 records because decoding is selected per record version. A v1 upsert
recovers with empty fields.

Each segment v2 live record adds `u32 payload_length` and encoded payload after
its vector. Segment v1 snapshots recover with empty fields. Every new flush
publishes a v2 segment, which transparently upgrades restored v1 state. The
manifest format remains unchanged because it already commits a segment by
filename, sequence, and checksum.

The write path remains validate, sequence, encode v2 WAL, append and fsync, then
apply vector and fields to MemTable. Vector and payload therefore share one
checksummed mutation and cannot commit independently.

## Error and recovery model

All API validation happens before sequence allocation and WAL append. Invalid
payload input neither consumes a sequence nor changes durable or in-memory
state. A complete WAL or segment with malformed payload is corruption and
fails open. The only tolerated corruption remains an incomplete final WAL
record; recovery removes that torn tail before accepting another append.

## Testing

Tests cover document constructors and lookup, all four codec types, field and
size validation, invalid UTF-8, duplicate keys, unknown tags, truncation, and
non-finite floats. Persistence tests cover mixed v1/v2 WAL replay, v1 and v2
segments, immediate get, WAL-only reopen, flush/reopen, vector-only replacement
clearing fields, delete, search-to-get flow, invalid-input sequence stability,
and v2 torn-tail repair. All Phase 3 tests remain regression requirements.

