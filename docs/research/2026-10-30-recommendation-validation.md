# Q02b exact recommendation source-port validation

Date: 2026-10-30. Implementation starts at `600cb2e`; Mojo
`1.0.0 (ed45d567)`, macOS ARM64. The full feature-completion goal and Q02 remain
in progress. This evidence covers the exact query path, not ANN/protocol parity.

## Behavior and executable path

`recommendation.mojo` translates Qdrant's dense/sparse averages, positive/negative
merge, multivector concatenation, best-score signed sigmoid and separate F32
positive/negative sums. Missing sparse terms contribute zero to the merge.
Best-score maxima use Rust total ordering, with the source's negative-side tie
rule. Repeated examples are not deduplicated from the arithmetic.

`recommendation_metrics.mojo` prepares each query row before target scalar
conversion and evaluates higher-is-better internal similarities. L2 enters
custom reducers as negative squared distance. Only average-vector output uses
Qdrant's Euclid square-root postprocessing. Sparse custom scores include
nonoverlap zeros, unlike nearest sparse queries. Multivector scoring uses the
source's sum of per-query-row maximum similarities.

`field_recommendation.mojo` captures target/source read generations, resolves
mixed point IDs and raw vectors, and excludes same-collection IDs before
selection. Cross-collection colliding IDs remain eligible. Payload filters apply
to candidates, not to lookup resolution. Native snapshot/collection methods,
Python `recommend_field` and Arrow `recommend_field_record_batch` execute this
Mojo path. Owned Arrow output survives close. Callback-driven close during
argument conversion fails before a native collection borrow is used.

The APIs bound example count, k and candidates and check cancellation/deadlines.
Stats identify the exact implementation. The existing nearest-vector APIs and
durable formats are unchanged. Recommendations are included in query telemetry.

## Independent reference

`scripts/qdrant_recommendation_reference.py` extracts **14 unedited functions**
from pinned Qdrant `74f3e85b9473c62560006c043e13737ce6b48412` and compiles a Rust
oracle. The fixture records each source/function hash and the harness hash.
Representation shims replace containers, errors, trait plumbing and storage;
the actual transforms, reducers, scalar F32 metrics, sparse merge/score and
MaxSim bodies come from the upstream source. Integration-source hashes and
license notices are in `docs/upstream/ports.json` and `THIRD_PARTY_NOTICES.md`.

- **336 F32 query cases**: dense/sparse/multivector, Dot/L2/cosine where applicable,
  positive-only/negative-only/mixed sets, empty-positive average errors, ragged
  multivectors, sparse term unions/zero values, and mixtures of raw and stored
  point examples. Source cosine preprocessing occurs before the transform for
  ID-tagged examples; source and target metrics can differ.
- **24 reduction cases**: best-score/sum-score, positive/negative ties, signed
  zero, ordered accumulation, tiny/large magnitudes and sum overflow.
- Native tests compare raw average transforms and reducers by **exact F32 bits**.
  Public pipeline tests compare IDs and scores to Rust with 2e-6 absolute/relative
  tolerance for independent compiler normalization; Arrow output equals the
  native query result. No benchmark or latency claim is derived from these tests.

## Verification performed

```sh
rtk proxy python3 scripts/qdrant_recommendation_reference.py
rtk proxy pixi run build-python
rtk proxy pixi run mojo run -I src tests/mojo/test_recommendation.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_point_query.mojo
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_recommendation.py tests/python/test_point_query.py \
  tests/python/test_weighted_rrf.py tests/python/test_score_fusion.py \
  tests/python/test_named_vectors.py tests/python/test_field_ivf.py \
  tests/python/test_field_rerank.py tests/python/test_binding_conversion_close.py \
  tests/python/test_operations.py -q
rtk proxy git diff --check
```

Results: Rust fixture generation and Python shared-library build passed;
**7 native cases across 2 modules**, **803 distinct Python cases** passed.
The Python total includes 390 recommendation cases and the affected lookup,
fusion, native-vector, IVF/rerank, conversion-close and operations regressions.
Native logs: `.build/recommendation-validation/`. Existing Python `__module__`
deprecation warnings remain. Rust scaffold visibility warnings do not change
reference behavior. Initial implementation checks found and corrected Mojo
movable-list iteration/Top-K argument errors and a test stats attribute typo;
the final commands above all passed.

No durable schema, WAL or publication code changed, so the crash suite was not
rerun. Existing native worker is reused; Python bindings were rebuilt after the
final query-code edits. Native Linux remains deferred by the user's instruction.

## Scope that is explicitly still open

1. **Custom ANN integration** for best-score/sum-score and average-vector query
   preprocessing. Current public recommendation mode accepts exact only; it
   never substitutes an averaged nearest query for a custom scorer.
2. **Complete F16/U8 independent source oracle**, high-dimension/SIMD and integer
   overflow behavior. This port follows source conversion order and has native
   dtype regression cases, but its independent pipeline oracle is F32. Integer
   accumulation is widened to Int64; BF16/I8 are Akasha extensions.
3. **Canonical storage/source semantics**: Akasha stores raw native values and
   reconstructs cosine's normalized representation at query time. F32 source
   behavior is covered by fixtures. Low-precision native authority has already
   rounded its original input, so the pre-ingestion F32 value cannot be recovered
   this way. Q02/Q06 must audit and migrate storage where required; this is not
   a claim of complete Qdrant storage equivalence.
4. **Universal queries/prefetch, C ABI and Qdrant REST/gRPC**, plus official-client
   service/error/limit acceptance. Existing native contracts keep positive k,
   finite-result rejection and ascending ID ties. Missing Manhattan/quantization
   modes remain in Q06.

All remaining rows in the master ledger stay open. Functional implementation
continues before any M5/M6 performance work.
