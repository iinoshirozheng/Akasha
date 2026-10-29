# Stored-point query: native lookup and candidate exclusion

Date: 2026-10-30. Base: `08b1122`, main. macOS ARM64,
Mojo `1.0.0 (ed45d567)`. Functional Q02 prerequisite; no performance work.

## Implemented

`search_field_by_id` now exists on native `ReadSnapshot`/`PersistentCollection`
and Python `Collection`; Arrow adds `search_field_by_id_record_batch`. Native
lookup resolves a retained PointField owner. Default/explicit self lookup uses
the search's one captured root. External collection lookup captures a separate
source root; native callers can provide a retained source snapshot.

Qdrant's same-collection referenced-ID exclusion is applied before dense/sparse
Top-K, HNSW admission and IVF scoring. Excluded graph vertices remain traversable.
Payload filters apply to candidates rather than preventing source-vector lookup.
Explicit source fields and cross-collection colliding IDs work. Shared registry
identity or canonical directory paths distinguish same-collection snapshots even
across reopen through a symbolic-link path.

Missing/deleted points and missing vector fields raise errors. Empty sparse
queries return no hits and empty multivector queries fail validation, matching
existing native query contracts. No persistent format, mutation or storage
publication path changed.

## Source evidence and boundaries

`scripts/qdrant_point_lookup_reference.py` compiles seven unedited lookup and
reference-selection functions from three pinned Qdrant source files. The fixture
contains **52 cases**, with original source/extracted/harness SHA256 hashes.
All three source hashes were checked against `git show` at revision
`74f3e85b9473c62560006c043e13737ce6b48412`. Representation-only shims and functions
are documented in `tests/fixtures/qdrant-point-lookup/README.md`.

The independent oracle proves lookup-vector selection and exclusion decisions.
Actual collection/Arrow tests use those decisions with the unchanged native
scoring path; this is not presented as independent validation of an entire
Qdrant query engine or all metric preprocessing.

The API deliberately retains the existing native typed-query contract: kind,
scalar and dimension must match. Qdrant cross-datatype conversion and canonical
stored-vector preprocessing remain explicit Q02/Q06 acceptance requirements.
Raw Akasha vector storage is not silently changed here. HTTP/gRPC/C ABI, mixed
ID/vector recommendation examples and universal query wiring remain unfinished.

## Verification

`rtk proxy pixi run build-python` passed. The previously verified native worker
was reused: its C source and build inputs did not change. Compiler imports and
use of the installed stdlib `realpath` compiled successfully; API documentation
was checked against the 1.0.0 stdlib index rather than assuming current 1.2 syntax.

Native tests ran serially with
`rtk proxy pixi run mojo run -I src tests/mojo/<module>.mojo`:

| Module | Passed cases |
| --- | ---: |
| test_point_query | 2 |
| test_named_hnsw | 7 |
| test_field_ivf | 3 |
| test_named_sparse | 3 |
| test_generation_fields | 3 |

**18 cases passed.** New snapshot tests cover changed query values, collection
close, source-owner lifetime, external ID collisions, explicit closed snapshots,
and a retained source across reopen through a symlink. The reopened source-ID
candidate is made the highest-scoring point so a missing exclusion cannot pass.
Regression logs are retained in `.build/point-query-validation/`.

Python integration and regression:

```sh
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_point_query.py tests/python/test_weighted_rrf.py \
  tests/python/test_score_fusion.py tests/python/test_named_vectors.py \
  tests/python/test_field_ivf.py tests/python/test_field_rerank.py \
  tests/python/test_binding_conversion_close.py -q
```

Result: **409 passed**. Subsequently added the targeted HNSW selective-filter
fallback/empty-admission test and ran:

```sh
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_point_query.py::test_hnsw_selective_filter_fallback_keeps_exclusion -q
```

Result: **1 passed**, for **410 distinct passing Python cases**. The unchanged
409 successful cases were reused. Two existing `__module__` deprecation warnings
remain. The original 90 point-query cases also passed in isolation before adding
the empty/deleted and selective-filter cases.

Coverage includes every native dense/multivector scalar and metric, sparse and
binary metrics, source filtering, owned Arrow buffers after close, reopen,
ANN/IVF exclusion without losing k slots, shadowed runs, empty/deleted/removed
values, invalid lookup/type/ID inputs, resource/deadline/cancellation controls,
and conversion callbacks closing the target or source collection.

Python AST parsing and `git diff --check` passed. Review traced query ownership,
both HNSW exact fallbacks, pre-Top-K filtering and close checks. No new crash-format
suite was needed because no durable writer/codec/format changed. Native Linux
remains deferred by the user's existing instruction, not reported as passed.

## Next required work

Q02 remains open. [Recommendation implementation plan](../plans/2026-10-30-recommendation-source-port.md)
preserves average-vector, best-score and sum-score strategies, raw/ID/mixed
examples, query preprocessing and custom ANN scorers. Q01 protocol exposure and
the rest of the full product ledger remain open. No optimization gate resumed.
