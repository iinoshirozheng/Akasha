# Actual jsonb binary codec reference

Run `pixi run python scripts/jsonb_codec_reference.py` to reproduce.

The executable links the original jsonb 0.5.6 databend backend with defaults
disabled, matching Lance's declared profile. `cases.json` records 6,246 typed
construction/encoding/decoding cases, 85 old decimal/timezone representations
and ObjectBuilder's duplicate-key rejection. Encoded bytes come from the actual
crate, independently compared with its raw array/object builders.

`sources.json` records the checksum-verified dependencies/source files, input
Lance contract fixture and generator/scaffold/output/lock hashes. Cargo.lock
pins the complete executable dependency resolution. Rust is reference-only at
runtime; the ported native codec is `src/akasha/document/jsonb.mojo`.

These are binary-codec tests, not claims of textual jsonb, durable payload,
Arrow extension or complete LanceDB compatibility. See
[validation](../../../docs/research/2026-10-30-jsonb-codec-validation.md).
