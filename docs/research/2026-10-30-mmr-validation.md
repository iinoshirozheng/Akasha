# MMR source-port validation

Date: 2026-10-30. Starts after `8da22e8`, Mojo 1.0.0, macOS ARM64.
Status: native nearest MMR implementation and scoped validation complete. The
complete Q03 and product plan remain open.

## Source and native integration

Pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` selection and
lazy-matrix implementation, universal-query conversion and REST options are the
reference. `scripts/qdrant_mmr_reference.py` compiles the unedited
`maximal_marginal_relevance` function with documented IndexSet/OrderedFloat/matrix
adapters and the existing verbatim portable metric functions. It verifies the
historical recommendation fixture remains unchanged. The oracle covers the
portable scalar path; it is not a full server, SIMD, datatype or ANN oracle.

The current fixture contains 192 reducer cases and 112 vector cases, including
signed zeros, NaNs/infinities, ties, zero/one/oversized limits, fractional F32
values and directional MaxSim. The actual source matrix caches ordered cells
despite its symmetric wording; native code preserves that direction and uses a
dictionary of computed cells instead of a full n*n Option allocation.

`mmr.mojo` owns the source selection; `field_mmr.mojo` adapts root-owned native
values and original candidate scores. `field_nearest.mojo` shares exact/HNSW/IVF
dispatch for raw and ID nearest queries, then MMR uses the same captured target
root. Native snapshot/collection, Python and Arrow expose MmrOptions. Existing
candidate retrieval scores/ordering and native typed-input contracts are retained.

## Correctness fixes found during validation

Extending vector fixtures from 56 to 112 revealed a cosine-score bit mismatch
in case 40 (bits 1033737752 vs source 1033737756). The same suite passed when
compiled with `--fp-mode=contract=off`, isolating compiler contraction. The shared
portable scorer now uses `compute/f32.mojo::rounded_f32_product` for dot/L2 and
cosine normalization; sparse and MMR products use that same rounding boundary.
The old sparse-only helper was moved, not retained as a second implementation.
All 304 source cases then passed under the normal compiler settings. This also
corrects recommendation's shared portable scoring; native optimized nearest
metric kernels and global compiler flags are unchanged.

A final review found that zero MMR candidates bypassed native index-option
validation. Five new Python cases reproduced the error. HNSW/IVF option
validation now has one shared implementation used by ordinary search and the
empty-MMR return; valid zero-candidate requests still build/score no index.

## Verification

26 native cases across seven modules passed: MMR (5), sparse index (7), sparse
nearest (3), recommendation (5), sparse recommendation (3), recommendation ANN
(1) and point query (2). The MMR tests check all 304 source fixtures, F32 score
bits, original output-score bits, directional cells, duplicate/missing candidates,
snapshot isolation and reads after writer close.

Before the last zero-candidate validation correction, the complete Python suite
passed **1735 cases with one optional Qdrant Edge skip**, including 42 new MMR
cases, and the C ABI build/test passed. Final bindings rebuilt successfully; **50 MMR cases and 521 index/query
regression cases passed** after that correction. The 50 include eight new
zero-candidate cases, giving **1743 distinct passing Python cases** when combined
with the applicable earlier results (not 1743 in one final invocation). The C
ABI result predates only the named-index validation extraction; C routes and
the underlying storage/metric implementation did not change in that extraction.
Existing Python __module__ and Starlette/httpx warnings remain.

Logs: `.build/mmr-validation/`. No performance experiment, durable-format change,
new crash protocol or GPU change was introduced. Discovery/context, nested
prefetch/fusion MMR, universal REST/gRPC, multivector ANN and full datatype/storage
parity remain separate full-plan gates. Native Linux is still user-deferred.


Reproduction commands (heavy checks run serially):

```sh
rtk proxy python3 scripts/qdrant_mmr_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_mmr.mojo
rtk proxy pixi run build-python
rtk proxy pixi run env PYTHONPATH=python:. python -m pytest tests/python -q
rtk proxy pixi run test-c
rtk proxy git diff --check
```

The six additional native module names are `test_sparse_index`,
`test_sparse_nearest`, `test_recommendation`, `test_sparse_recommendation`,
`test_recommendation_ann` and `test_point_query`. Final Python regressions covered
`test_named_vectors`, `test_point_query`, `test_field_ivf`, `test_sparse_nearest`,
`test_named_arrow` and `test_recommendation_ann`. All source pins and final
implementation/fixture hashes were verified; no code changed after its
applicable passing validation.
