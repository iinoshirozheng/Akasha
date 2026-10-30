# fast-float2 0.2.3 F64 oracle

Regenerate from the pinned crate with:

```sh
pixi run python scripts/fast_float_reference.py
```

`cases.json` contains raw input bytes as hexadecimal, complete and prefix F64
bit patterns as decimal strings (`-` means rejection), consumed prefix length,
the original numeric dispatch category and forced long-mantissa output.
`sources.json` pins the source archive/files, generator, Rust adapter, tables,
fixture and lock hashes. Each copied module is checked against the archive;
public crate and unchanged internal module outputs must agree before output.
The fixture is generated exclusively by actual Rust source execution.

The generator also extracts literal tables into
`src/akasha/document/fast_float_tables.mojo` and preserves the MIT license.
The native dependency uses no Rust or Python at runtime. See the
[validation report](../../../docs/research/2026-10-30-fast-float-validation.md)
for coverage and limits; the complete jsonb text/Arrow feature is still open.
