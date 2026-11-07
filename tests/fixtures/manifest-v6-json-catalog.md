# Manifest v6 JSON catalog fixture

Independently assembled with Python struct.pack (little endian) and zlib.crc32,
not the Mojo encoder. Dimension 1, generation 2, sequence 1; one level-0 segment
`segment-1.bin`, sequence interval [1,1], checksum 11. No HNSW descriptor.
Catalog section v1, revision 1, one bitmap definition: name `v`, column `data`,
path `$.v`, learned Int64 target 2. The CRC covers all bytes after AKMF and
before the CRC itself. This is a codec fixture, not a complete database.

SHA-256: `c54b4f94ef12548d2271983a3bf659e5ce8d6493a6599504bb1f64c567c98529`
