# Numeric formula reference

Regenerate with `rtk proxy python scripts/qdrant_formula_reference.py`.
Pinned Qdrant: `74f3e85b9473c62560006c043e13737ce6b48412` (Apache-2.0).

The generator extracts unedited `score`, `eval_expression`, payload/default
retrieval and three decay functions from `formula_scorer.rs`, plus
`decay_params_to_lambda` from `parsed_formula.rs`. A Rust release build evaluates
309 cases, including 57 expected errors. Function/source/scaffold hashes and
compiler flags are recorded in `formula.json`. Results are exact final F32 bits
or `null` for an upstream error; Python does not compute expected scores.

Adapters provide expression/value/container types, direct flat payload values,
ordered score maps and constant boolean condition checkers. Geo/date branches
remain in the copied match but their dependency adapters deliberately cannot
execute; no fixture uses them. This oracle does not test JSON-path parsing,
condition evaluation, segment visibility, Top-K, transport or a complete server.
Those native integration boundaries have separate tests and documented limits.

The release profile matters: nonfinite decay intermediates can trigger upstream
`debug_assert` in a debug build. With debug assertions disabled, the unchanged
production scorer reaches its final finite-F32 check. The fixture retains both
error cases and cases where later short-circuit/default operations rescue an
intermediate nonfinite value.
