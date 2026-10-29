# DBSF source port: functional validation

The native named-field API now accepts `fusion="dbsf"`, alongside default RRF.
The option flows through `PersistentCollection`, captured `ReadSnapshot`, the
compiled Python binding, Python `Collection.search_fields` and Arrow output.
HTTP/gRPC universal query exposure and weighted fusion are still pending Q01 work.
This is a functional port, with no performance optimization or acceptance claim.

## Source evidence

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`,
`lib/segment/src/common/score_fusion.rs`, SHA-256
`c33a0685920f9f18787cd19eeecf07c95b13567661913caaffbb1adaa28c89fd`.
`scripts/qdrant_dbsf_reference.py` compiles the three original normalization
functions without rewriting them. Its record shim and extraction hashes are in
`tests/fixtures/qdrant-dbsf/normalization.json` and `docs/upstream/ports.json`.

The fixture has 114 rankings and 3,706 input/output scores, stored as F32 bits and
readable numbers. Direct Mojo normalization checks all rankings; the real Python
collection path checks the 66 rankings already in descending score order.
The absolute comparison tolerance is `1e-5`, matching upstream's absolute test
tolerance; this is not a claim of bitwise agreement across every compiler/input.

Ported behavior includes singleton/constant score 0.5, sample variance (`n-1`),
three-standard-deviation bounds, unclamped outliers and F32 branch-order summation.
Explicit Akasha adaptations are finite-range rejection, conversion from native
F64 field scores to F32 at the fusion boundary, and ascending ID ties. Raw distance
scores are not inverted. Optional final-field reranking retains its native score
contract and reads the same root.

## Validation on Mojo 1.0.0 (ed45d567)

- Before implementation, the new native test failed because `score_fusion` did
  not exist. Test syntax/API mistakes (`case`, `inf`, constructor names) were
  corrected during compilation; no failed run is treated as passing evidence.
- `rtk proxy pixi run build-native-worker`: passed.
- `rtk proxy pixi run build-python`: passed.
- `rtk proxy pixi run mojo run -I src tests/mojo/test_score_fusion.mojo`: 3 passed,
  including all 114 frozen rankings and finite/overflow/no-clamp boundaries.
- Same native command for `test_rank_fusion.mojo`: 7 passed;
  `test_named_sparse.mojo`: 3 passed; `test_field_rerank.mojo`: 1 passed;
  `test_field_dbsf.mojo`: 1 passed. Total **15 native cases in 5 modules**.
- `rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest
  tests/python/test_score_fusion.py tests/python/test_named_vectors.py
  tests/python/test_field_ivf.py tests/python/test_field_rerank.py
  tests/python/test_binding_conversion_close.py -q`: **254 passed** in 13.34s.
  Two existing extension-type `__module__` deprecation warnings remain.
- Changed Python files parse; `git diff --check` passes.

Public-path tests cover source-oracle scores, overlapping/disjoint IDs, stable
ties, filtering before normalization, rerank, Arrow ownership after close, reopen,
empty fields, rejected mode, cancellation, candidate budgets and F64-to-F32 overflow.
The direct native snapshot test preserves its old result after deletion and
collection close. Existing RRF, named field, IVF, rerank and callback-close cases
remain green. No durable format or mutation implementation changed.

This evidence completes Q01a's core/Python/Arrow slice only. F00 still needs
protobuf/Lance/general DB/UI inventories and the historical attribution audit.
Q01 and the overall product plan remain open, as do M5/M6 and deferred native Linux.
