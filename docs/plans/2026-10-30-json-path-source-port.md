# D01a / Q04c source-backed JSON paths

Status: shared grammar and flat-key formula integration implemented; rich data remains open. Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412`.

Port the grammar and path operations from `segment/src/json_path/{parse,mod}.rs`
and formula `VariableId::from_str`. Preserve full consumption, Unicode raw keys,
literal quoted keys without backslash escapes, UInt64 indexes, wildcard indexes,
canonical display and prefix/compatibility semantics. Use an independent Rust
oracle compiling the original parser with its pinned nom dependency.

Mojo's available character helpers are ASCII-only. Use the source Rust Unicode
classification data, verify it against the pinned upstream compiler's tables,
and generate a native lookup representation. No Python Unicode classification
or formula evaluation may substitute for the native implementation.

Wire the shared parser into formula variables/defaults now, supporting quoted
flat keys and full score index syntax while removing the provisional ad hoc
name parser. Preserve structural resource bounds. Nested/array syntax is parsed
but actual value traversal waits for D01's rich values/codec migration; do not
silently treat nested paths as literal flat fields. That remaining work retains
all data, filtering, projection/mutation, persistence, corruption/recovery and
public boundary acceptance requirements from the master ledger.

The standalone reference compiles the unchanged Qdrant parser with nom 8.0.0
and original path/variable operations. Rust 1.97.1's Unicode 17 classifier is
checked against the host for every valid scalar and generates native tables.
548 path/variable inputs, 81 operation pairs, exhaustive native Unicode and
573 public formula/path cases have coverage. Native `FormulaDefault` replaces
the provisional reuse of persistent document-field names. See the
[validation record](../research/2026-10-30-json-path-validation.md).

Verify source path cases and operations, Unicode classification, formula key/
default normalization, UInt64 score indexes, bad syntax/resource limits, native
and Python/Arrow behavior. Record upstream/license/provenance evidence, update
the report and task ledger, and commit the verified change. No optimization.
