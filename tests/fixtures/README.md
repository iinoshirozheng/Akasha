# Test fixtures

Keep fixtures deterministic, minimal, and checked in when licensing permits.

## Field catalog v2

`field-catalog/generate.py` independently produces three binary fixtures using
Python `struct` and `zlib`, without importing a production encoder. Run it from
any directory to reproduce the files; `field-catalog/manifest.json` records sizes,
SHA-256 and CRC32. `legacy-v1.bin` has F32 authority and an F16 graph; the named-F32
fixture includes different dimensions/metrics, noncontiguous field IDs and a
Unicode sparse name. The type-matrix fixture covers agreed native, binary and
multivector metadata only; it does not claim their data paths are implemented.

`test_field_catalog.mojo` checks exact re-encoding, legacy preservation, input
ownership, count/name/numeric limits, every truncation and single-byte corruption,
CRC-valid malformed metadata and no-side-effect file reads. See the
[format contract](../../docs/formats/field-catalog-format.md).

## Manifest v4

`manifest-v4-hnsw.bin` is an independent Python `struct.pack` / `zlib.crc32`
fixture (124 bytes): dimension 3, generation 7, sequence 5, one level-1
`segment-base-5.bin` descriptor (sequence 0..5, CRC `0x11223344`), and
`hnsw-5-6-2.bin` (CRC `0xA1B2C3D4`, config `0x1122334455667788`, 2 live points).
The creation generation is deliberately older than the manifest generation to
cover compaction carrying forward an unchanged sidecar. The manifest CRC covers
all bytes after magic and before the checksum, as specified in
`docs/formats/manifest-format.md`; production Mojo encoders did not generate it.

## Field-aware complete point records

`point-records/generate.py` independently creates six complete point-record
fixtures using Python `struct` and explicit IEEE bit patterns. Its manifest
identifies the matching field catalog and SHA-256 for each file. These are
record bodies, not standalone checksummed WALs or segments; their durable outer
envelopes remain a separate implementation. Fixtures cover default/named fields,
payload-only and named-only points, tombstones, all five numeric authority dtypes,
packed-bit padding, variable-row matrices and empty multivectors. See
[`point-record-format.md`](../../docs/formats/point-record-format.md).
# Retained HNSW base manifest

`manifest-v5-hnsw-base.bin` was generated independently with Python `struct.pack`
and `zlib.crc32`, without calling the Mojo encoder. It contains dimension 3,
generation 7, checkpoint sequence 5, one `segment-base-5.bin` descriptor with CRC
`0x11223344`, and `hnsw-3-6-2.bin` with CRC `0xA1B2C3D4`, configuration fingerprint
`0x1122334455667788`, and base point count 2. The base sequence 3 intentionally
precedes checkpoint sequence 5. `test_manifest_v5.mojo` verifies the exact bytes,
older-version rejection, future base rejection, torn prefixes and corruption.
