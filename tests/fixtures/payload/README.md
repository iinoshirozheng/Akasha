# Frozen payload format fixtures

These bytes were assembled independently with Python `struct.pack` from
`docs/formats/payload-format.md`, not produced by Akasha's encoder.

- `v1.bin`: one field `x`, tag 2, signed integer 3.
- `v2.bin`: one field `x`, object `{"a":[null,-0.0,true,18446744073709551615]}`.
  The final element uses tag 8 / UInt64. The floating element retains negative
  zero's sign bit. Both fixtures are compared byte-for-byte with encoding and
  strictly decoded in `test_rich_payload.mojo`.
