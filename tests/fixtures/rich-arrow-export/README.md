# Arrow numeric export reference

`casts.json` records 2,126 finite Float64 bit patterns converted by the actual
Arrow 58.4.0 `cast_with_options` (safe=false) to Float16 and Float32. Cases include
both signed zeros, smallest subnormals, normal/subnormal transitions, exact
midpoints and their adjacent Float64 values, maximum finite values, overflows
and deterministic fixture-only random bit patterns.

- F16: 1,128 finite expected outputs; 998 nonfinite outputs.
- F32: 1,256 finite expected outputs; 870 nonfinite outputs.
- Akasha compares every finite output bit and rejects every nonfinite narrowing
  under its finite numeric contract. Arrow itself permits these infinities.

The source chain is Arrow `cast_numeric_arrays` → `try_numeric_cast` → `num_cast`
→ num-traits `NumCast`. `half` 2.7.1's `NumCast for f16` calls `to_f32` before
`from_f32`; it is different from directly rounding F64 to F16. The fixture
exposed four midpoint differences and the Mojo port preserves this source path.

Regenerate with `pixi run python scripts/rich_arrow_export_reference.py`.
The generator pins all seven Arrow crates to Lance's 58.4.0 dependencies,
checks half 2.7.1 / num-traits 0.2.19 against the same Lance lock, verifies crate
archives and 198 Rust source-file hashes, and preserves the executable Cargo.lock.
The reference executable links no Akasha implementation. Rust is not a runtime
dependency. Sources/provenance are in `sources.json`; Arrow/half/num-traits
licenses and notices are retained under `docs/upstream/licenses/`.

Nested array/schema/null/ownership behavior also uses the independent Arrow IPC
and JSON fixture in `../rich-arrow`, not a second native-generated expectation.
