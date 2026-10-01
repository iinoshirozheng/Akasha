# Stream the authoritative index fingerprint

After block CRC, an 8192-row 1536D fingerprint still takes about 42 ms and builds
a whole-dataset encoded byte list. The current fingerprint format and its frozen
Python struct/zlib test vectors must remain identical.

Use the existing incremental CRC and BinaryWriter encoding. Drain small encoded
headers into the register, clearing the writer while retaining its allocation.
On little-endian targets, synchronously checksum the immutable F32 row bytes;
other endianness still encodes each row in little-endian order. Encode payloads
with the existing codec and feed their length and bytes into the same register.
Auxiliary encoded storage is bounded by one row/payload, not all collection rows.
No new hash, durable format, retained cache or configuration is introduced.

The first prototype allocated a fresh header for each drain: high dimensions
improved, but 128D regressed. Reusing the header allocation removes that regression
in three alternating pairs: 128D materialized/streamed is about 5.4/3.9 ms;
1536D about 41/24 ms. All checksum values match. Preserve both prototype reports,
including the rejected short-vector regression; no RSS claim follows from timing.

Verify the writer's empty/drain/reuse behavior against the standard CRC check
value, existing independently encoded fingerprint fixtures, persisted index
cache and HNSW recovery/publication tests, rebuilt bindings and lifecycle timings
against the saved post-block-CRC package. Keep the earlier complete CPU gate as
an identified checkpoint and report affected checks for this later change.
