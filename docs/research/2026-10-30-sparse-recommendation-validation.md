# Q02d sparse recommendation source validation

Date: 2026-10-30. Starts at `2432335`; Mojo `1.0.0 (ed45d567)`, macOS ARM64.
Sparse recommendation now has source-backed indexed/plain dispatch through
Mojo, Python and Arrow. Q02 and the full feature-completion goal remain open.

## Upstream findings and implemented behavior

Qdrant `74f3e85b9473c62560006c043e13737ce6b48412`,
`lib/segment/src/index/sparse_index/sparse_vector_index/read_view/search.rs`:

- Nearest queries, including average-vector recommendations, use sparse search.
  Empty queries return no results. With a filter below the configured threshold,
  the source selects plain postings search; the default threshold is 5000.
- Best-score/sum-score use `search_scored`, which iterates eligible vectors with
  a custom scorer. Sparse custom recommendation is not HNSW ANN.
- `sparse_vector_index/vector_index_impl.rs::search` ignores `SearchParams`,
  so the `exact` flag does not change sparse query dispatch.

`src/akasha/index/sparse_search.mojo` ports plain, batched and final-posting
execution over the existing immutable `FieldSparseIndex`. Source batches span
`start..=min(start+10000,last)`, including both endpoints. Exhausted lists are
removed after each batch; if one list remains, its products go directly to Top-K.
Plain search reuses the existing ordered-posting lower-bound helper. The retained
index owns posting data and root-local row identities. Existing native Top-K
keeps ascending public-ID ties; reliable suffix-max weights are not available,
so this follows the source's non-pruning branch. No new pruning algorithm or
performance tuning was introduced.

`field_recommendation.mojo` dispatches sparse fields independently of the
exact/approx flag, and `recommendation_execution.mojo` runs that path.
Average-vector uses the prepared source
transform and postings. Filters/source exclusions determine admission and the
5000-vector default dispatch, using native exact eligible counts rather than
Qdrant's cardinality estimator. Best/sum reuse the existing full composite scorer.
Stats report `recommendation_sparse_indexed`, `recommendation_sparse_plain`,
`recommendation_sparse_empty`, or `recommendation_sparse_scored`; these are not
misreported as dense ANN or an exhausted-graph fallback. HNSW-only `ef_search`
is rejected for sparse fields.

## Correction to the earlier sparse-zero generalization

The source's `advance_batch` rejects zero scores. Its `plain_search` and
`process_last_posting_list` instead submit overlapping candidates to Top-K,
which can accept zero, including cancellation and signed-zero products.
No-overlap rows are still omitted by nearest search. Custom best/sum scoring
includes zero/nonoverlap rows as before.

Therefore "sparse nearest never returns zero" is not a complete upstream rule.
The earlier exact recommendation oracle deliberately filtered zero in its
storage/selection scaffold. Its 14 unedited numeric functions remain valid
evidence, but that scaffold was not proof of all sparse index execution paths.
The original fixture and failure history are retained, with scope annotations.

This new source execution preserves the distinctions. For example, a filtered
average query `[1:1, 2:1]` against an overlapping vector `[1:1, 2:-1]` returns
score zero in the plain path at 4999 eligible vectors; at 5000, batched indexed
search omits it. Another fixture proves that a zero after the first 10001-ID
batch can be returned by the remaining-posting path. Recommendation exact and
approx modes now agree on these source paths; the obsolete sparse-average flat
selection and its blanket zero predicate were removed. Ordinary native nearest
APIs still retain their older contract; their full migration remains explicit
work, not a claim of complete product equivalence.

## Independent reference and verification

`scripts/qdrant_sparse_recommendation_reference.py` compiles **eight unedited
upstream methods/functions** and the original `TopK` implementation. Posting
containers/iterators, counters, stopping flag and score ordering are small
representation shims. Ordering adds native ascending-ID ties and treats signed
zero scores as equal, matching the source's numeric equality. The source's
`use_pruning=false` path executes; compiled pruning helpers are not exercised.

`tests/fixtures/qdrant-recommendation/sparse-search.json` contains **138 cases**:
plain/indexed empty and nonoverlap queries, zero/cancellation/negative/signed-zero
scores, filters, multiple batch boundaries, deterministic random data, and the
existing source-produced sparse `average_bits` passed into actual sparse search.
It records source, extracted-function, original Top-K, scaffold and input-fixture
hashes. Native comparisons check IDs and exact F32 bits. Public recommendation
tests compose these results with the prior transform/reducer fixtures for mixed
raw/ID examples; this does not run the complete Qdrant server or IDF planner.

```sh
rtk proxy python3 scripts/qdrant_sparse_recommendation_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_sparse_recommendation.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_named_sparse.mojo
rtk proxy pixi run build-python
rtk proxy env PYTHONPATH=python:. .pixi/envs/default/bin/python -m pytest \
  tests/python/test_recommendation.py tests/python/test_recommendation_ann.py \
  tests/python/test_sparse_recommendation.py tests/python/test_point_query.py \
  tests/python/test_weighted_rrf.py tests/python/test_score_fusion.py \
  tests/python/test_named_vectors.py tests/python/test_field_ivf.py \
  tests/python/test_field_rerank.py tests/python/test_binding_conversion_close.py \
  tests/python/test_operations.py -q
rtk proxy git diff --check
```

Results: **6 native cases across 2 modules**, **1094 distinct Python cases**
passed, including 142 new sparse recommendation cases. Bindings rebuilt
successfully; final native fixture validation includes all 138 source cases.
Coverage includes retained snapshots after writer close, artifact reuse,
shadowed/deleted points, flush/reopen, external lookup with colliding IDs,
owned Arrow output, exact/approx equivalence, 4999/5000 dispatch, max-candidate limits, cancellation,
deadlines and nonfinite admitted/rejected scores. The native counter metadata
does not claim equivalence to Qdrant hardware counters.

Initial compile checks caught a reserved test variable, omitted QueryControl
arguments and an invalid test owner-copy expression; these were corrected before
the passing runs. Two existing Python `__module__` warnings and one Rust scaffold
unused-import warning remain. Targeted logs are in
`.build/sparse-recommendation-validation/`; the broader Python command above
also passed. No storage format/publication code changed, so crash tests were not
rerun. GPU paths did not change. Native Linux acceptance remains deferred.

## Remaining work

- Multivector HNSW needs actual ragged-vector storage/build scoring. No averaged
  or first-row surrogate graph is substituted.
- Full sparse threshold configuration, IDF and input/planner/service parity;
  migration of older native nearest contracts to the complete source behavior.
- Independent F16/U8/SIMD/large-dimension coverage and canonical low-precision
  storage/source semantics; universal queries, C ABI and REST/gRPC exposure.
- The default dense graph's repeated-vector recall diagnostic and all M5/M6
  failures remain open. All functional work precedes optimization.

Follow-up: the ordinary nearest migration and additional rounding/overflow
coverage are tracked in [shared nearest validation](2026-10-30-sparse-nearest-validation.md).
The results above describe the Q02d commit and remain historical evidence.
