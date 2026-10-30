# Typed Arrow ingress reference

`values.arrow` is an Arrow IPC stream produced by the actual Arrow Rust crates,
not by the Mojo implementation or by Python expected-value conversion.
`expected.json` comes from Arrow JSON's writer with explicit nulls enabled.
The fixture has four rows and 22 columns (88 cells), including all signed and
unsigned integer widths, F32/F64, bool, null, UTF-8/large UTF-8, struct,
list/large-list/fixed-size-list, nesting, empty containers, masked NaN/Infinity
and required children masked by null parents. F16 and additional independently
sliced input/validity buffers are covered by public adapter tests separately.

The oracle compiles the unchanged Lance `list.rs` and `struct.rs` sources at
`ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e`. It checks null garbage removal,
trimmed offsets/values, struct null pushdown and normalization, plus Arrow's
required-child validation. Arrow array/schema/buffer/data/IPC/select are 58.4.0;
JSON is 58.3.0, exactly as pinned in Lance's Cargo.lock. Registry checksums and
198 Rust source-file hashes are retained in `sources.json`. These Apache crates
do not include `.cargo_vcs_info.json`; no unverified Git revision is invented.

Regenerate with `pixi run python scripts/rich_arrow_reference.py`. Cargo is a
reference-generation dependency only; the database uses native Mojo traversal
and its existing PyArrow 21 boundary. `Cargo.lock` records the executable's full
dependency graph. The generator verifies source files against the crate archive
and Lance's pinned Git objects. Source licenses/notices live in
`docs/upstream/licenses/{arrow-Apache-2.0,arrow-NOTICE,lance-Apache-2.0}.txt`.

This is typed JSON-compatible Arrow ingress, not Lance storage, rich typed
export, schema evolution or a lossless schemaless JSON representation.
