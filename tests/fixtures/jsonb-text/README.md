# jsonb 0.5.6 text profiles

Run `pixi run python scripts/jsonb_text_reference.py` to reproduce the fixture.
The Rust adapter calls original `parse_owned_jsonb` and
`parse_owned_jsonb_standard_mode`, cross-checks each accepted body against the
source `parse_value` encoder, and records errors/panics separately. The generator
verifies pinned crate checksums and all registered source files against their
archives. Expected values never come from Python or Mojo parsing.

Each row contains hexadecimal input bytes and a result for each mode. Accepted
results contain the exact databend body in `hex`, the `RawJsonb::to_string`
rendering used by Lance in `text`, and the distinct `Value::Display` rendering
in `display_text`. The native reader tests compare bodies and rejection; text
writer implementation remains pending. These two renderings must not be
confused when implementing the writer.

The input set extends the fast-float/Lance corpus with mixed-case literals,
all-byte strings and keys, surrogate/braced escapes, truncations, whitespace,
hexadecimal integer/fraction bounds, decimal precision boundaries, nested
generated extended values and valid depths through 64.

20,757 inputs: standard accepts 11,074/rejects 9,683; extended accepts
16,353/rejects 4,404; neither source profile panics. Akasha resource limits are
tested separately. See the [validation report](../../../docs/research/2026-10-30-jsonb-reader-validation.md).
