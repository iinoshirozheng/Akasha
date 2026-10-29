# Qdrant JSON-path source fixtures

Regenerate with `rtk proxy python scripts/qdrant_json_path_reference.py`.
Qdrant revision: `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).

The original `segment/src/json_path/parse.rs` is compiled unchanged with nom
8.0.0. Original display/prefix/wildcard/pattern methods and formula
`VariableId::from_str` are extracted unchanged. Transport structs replace
unneeded derives; the `anonymize` enum-field annotation is removed because that
derive dependency is not part of this standalone reference program. These
adapters do not parse or compute expected path operations.

548 input cases cover raw/quoted Unicode names, malformed/suffixed paths,
whitespace, literal controls, forbidden escapes, empty keys, all index forms,
UInt64 boundaries, formula reserved names, and seeded combinations. There are
81 path-operation pairs. `paths.json` records original source/unit/scaffold and
Cargo lock hashes. `Cargo.lock` fixes the reference-only dependency graph; no
Rust or nom runtime dependency is added to Akasha.

Qdrant's pinned Dockerfile selects Rust 1.97.1. Its original Unicode 17.0.0
Alphabetic/N tables, lookup and offset-header methods are compiled unchanged.
The original `char::is_alphanumeric` body runs in a trait adapter, removing only
the `pub` marker required for the original inherent-method declaration.
A checked assertion replaces the unavailable compiler `intrinsics::assume`.
The program compares this classifier with the host compiler's `char` classifier
for every valid Unicode scalar before nom uses it. The host here is Rust 1.92.0;
all comparisons pass, rather than assuming compiler versions have equal data.

The resulting 844 inclusive ranges generate the native Mojo classification
table. Native tests compare lookup for the entire codepoint range, including
surrogates and an out-of-range sentinel, and compare every path/variable result
and path operation to the independent source results. Rust source URL/SHA,
Unicode version, host compiler and generated table SHA are recorded. The Rust
MIT license is retained in `docs/upstream/licenses/rust-MIT.txt`.

This reference does not implement JSON value traversal/mutation, persistent
rich payloads, indexes, filters or a Qdrant server. Those remain separate gates.
