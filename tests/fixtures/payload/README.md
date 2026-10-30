# Frozen payload format fixtures

These bytes were assembled independently with Python `struct.pack` from
`docs/formats/payload-format.md`, not produced by Akasha's encoder.

- `v1.bin`: one field `x`, tag 2, signed integer 3.
- `v2.bin`: one field `x`, object `{"a":[null,-0.0,true,18446744073709551615]}`.
  The final element uses tag 8 / UInt64. The floating element retains negative
  zero's sign bit. Both fixtures are compared byte-for-byte with encoding and
  strictly decoded in `test_rich_payload.mojo`.
- `v3.bin`: one field `x`, array `[storage null, JSONB null,
  {"jsonb": JSONB timestamp-with-timezone(-1, 28800), "plain": -0.0}]`.
  The two complete source bodies are `2000000000000000` and
  `200000006000000d30ffffffffffffffff00007080`. Outer lengths/header were
  assembled with Python `struct.pack` (little-endian); the JSONB body is
  big-endian. `test_jsonb_payload.mojo` verifies exact bytes, frozen v1/v2
  migration, version gates and every truncated v3 prefix.

Reproduce v3 with `python tests/fixtures/payload/generate_v3.py --output /tmp/payload-v3.bin`.
The script selects bodies from the actual-source JSONB oracle; only the Akasha
envelope is assembled with `struct`. It neither loads nor calls Akasha.
