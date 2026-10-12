# F32 finiteness aggregation probe: not adopted

After maintenance fix `be3be53`, inspect the real selective exact-scan hot
loop. Mojo's SIMD Boolean finiteness accumulator emits per-iteration packing
instructions. An isolated prototype retains unsigned lane maxima of shifted
F32 bits instead: shifting discards the sign, and any infinity or NaN reaches
`0xFF000000`. The final unsigned maximum classifies the same inputs. Scoring,
accumulator order, scalar-tail checks and zero-norm behavior stay unchanged.
No validation is skipped; legacy record readers may still admit raw NaN bits.

The prototype passed all nine existing SIMD tests and a new test comparing
both signs, all 256 exponents, four mantissa patterns and SIMD/tail positions
against the standard scalar `isfinite` predicate. Assembly contains no Boolean
packing instructions in `_search_candidates`, but fewer instructions did not
produce a substantial consistent public-query improvement.

Three alternating fresh-process pairs per corpus used the fixed workloads and
selective filter. Before/after IDs, Float32 score bits and statistics matched.
Each worker also ran 32 repeated passes strictly for diagnostics; those passes
do not add recall or acceptance samples. Median repeated-pass ratios are:

| Corpus | QPS probe/baseline | p95 probe/baseline |
|---|---:|---:|
| uniform-128 | 1.029 | 0.959 |
| uniform-1536 | 1.002 | 0.994 |
| real-1536 | 1.023 | 0.961 |

Uniform-1536 included a slower pair (QPS .954, p95 1.114). The original
single-pass results were noisier and are preserved as well. Keep the simpler
existing implementation; this prototype was not promoted into production and
did not run a complete Qdrant parity matrix.

[Full pairs, raw timings, prototype diff, source/binary hashes and test logs](results/2026-10-12-finite-probe.json.gz).
SHA-256: `cb525985bda924ca51784b6ec8466a518c125789fda26e24e8f48178e4799f96`.
