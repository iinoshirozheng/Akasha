# Weighted RRF: source port and functional validation

Date: 2026-10-30. Base: `7d9e2c2`, main. Platform: macOS ARM64,
Mojo `1.0.0 (ed45d567)`. No performance experiment or durable-format change.

## Implemented behavior

The pinned Qdrant `position_score` and `rrf_scoring` semantics now apply to
optional branch weights in Mojo collection/snapshot field fusion, Python
`Collection.search_fields`, and Arrow `search_fields_record_batch`. The existing
two-ranking native RRF helper also accepts weights. Python only validates and
transports options; scoring runs in Mojo.

- F32 rank compression/stretching: `1 / ((rank + 1) / weight + k - 1)`.
- Omitted weights are unit weights; explicit lists must match branch count.
- Nonpositive weights contribute zero and retain IDs. Retrieval, resource
  accounting and optional final reranking still include these branches.
- Preserve input branch/rank accumulation order and ascending-ID tie behavior.
- Filters, exact/HNSW/IVF retrieval, immutable read views, reranking and reopen
  use the same native path. Arrow results remain owned after collection close.
- Reject nonfinite F32 weights/results and weights passed to DBSF. Validation
  occurs natively as well as in the public Python boundary; private binding calls
  cannot bypass length/finiteness/mode checks. Reentrant conversions that close
  the collection are rejected before borrowing the collection again.

The finite-value restriction and deterministic ties are documented Akasha
adaptations. The upstream huge-weight/k=1 infinity case is retained as evidence
and tested as a rejection, rather than silently returning a different score.

## Independent reference

`scripts/qdrant_rrf_reference.py` compiles both unedited functions from Qdrant
`74f3e85b9473c62560006c043e13737ce6b48412`. Container/point/iterator/error shims,
source hashes and output tie canonicalization are recorded in
`tests/fixtures/qdrant-rrf/weighted.json` and its README.

- 300 position-score cases, compared bit-for-bit in Mojo.
- 50 fusion/error cases: 23 two-ranking cases exercised by the native helper;
  47 eligible field-query cases exercised by actual collection retrieval and
  Arrow (overlap between these sets is intentional).
- Covers fractional/unit/negative/zero weights, omitted weights, empty branches,
  overlap/disjoint IDs, repeated IDs in the low-level helper, one to eight
  branches, large k, F32 subnormal/rounding boundaries and mismatched lengths.

The first integration run found two erroneous test expectations: a 3:1 weight
does not guarantee the first source's top ID wins after overlapping rankings
are accumulated, and approximate retrieval must not be assumed exhaustive.
Those tests now use the frozen Rust ranking and the actual independently
retrieved ANN branch candidates, respectively. Engine code needed no correction.

## Commands and results

Builds passed serially:

```sh
rtk proxy pixi run build-native-worker
rtk proxy pixi run build-python
```

Native tests passed, **19 cases across 7 modules**. Each was run with
`rtk proxy pixi run mojo run -I src tests/mojo/<name>.mojo`:

| Module | Cases |
| --- | ---: |
| test_weighted_rrf | 3 |
| test_field_weighted_rrf | 1 |
| test_rank_fusion | 7 |
| test_score_fusion | 3 |
| test_named_sparse | 3 |
| test_field_rerank | 1 |
| test_field_dbsf | 1 |

Five regression-module logs are in `.build/weighted-rrf-validation/`.
New test modules were also executed directly to terminal success.

Python initial integration command:

```sh
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_weighted_rrf.py tests/python/test_score_fusion.py \
  tests/python/test_named_vectors.py tests/python/test_field_ivf.py \
  tests/python/test_field_rerank.py tests/python/test_binding_conversion_close.py -q
```

It produced 313 passed / 2 failed (the two test-expectation issues above).
After correcting only those tests, reran the affected module:

```sh
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_weighted_rrf.py -q
```

Result: **59 passed**. Together with the unchanged 256 regression cases from
the initial run, all **315 distinct Python cases passed**. Two existing
`__module__` deprecation warnings remain. No failing test is counted as accepted.

Python AST parsing and `git diff --check` passed. Review checked option forwarding,
native validation, F32 operation order, conversion-close boundaries and source
attribution. No storage format or mutation path changed, so no new crash-format
suite was needed.

## Remaining scope

This is Q01b core/Python/Arrow acceptance, not full product acceptance. Universal
REST/gRPC query exposure and C ABI coverage remain in Q01/A01/A02/A03. Legacy
hybrid entry points still use unit weights; named field queries expose weighted
fusion. Q02 next includes query by ID and all three upstream recommendation
strategies: average vector, best score, sum scores. The full feature ledger,
native Linux deferral and unfinished M5/M6 performance gates remain unchanged.
