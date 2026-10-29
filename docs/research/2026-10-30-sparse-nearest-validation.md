# Shared sparse nearest source validation

Date: 2026-10-30. Starts at `f463e22`; Mojo 1.0.0 (ed45d567), macOS ARM64.
Status: shared sparse nearest implementation and scoped validation complete. Q02 and the full product
feature plan remain open; performance gates have not resumed.

## Source-backed behavior and integration

The same pinned Qdrant source as Q02d now serves named/default sparse nearest,
exact/approx point lookup, legacy hybrid retrieval, PointStore search and the
standalone mutable SparseIndex. Sparse candidate reranking follows
`collection/src/shards/local_shard/query.rs::rescore` / `filter_with_sources_ids`:
restrict normal search by the candidate IDs. It retains the existing native
candidate budget and cannot admit another point.

`query/field_search.mojo::search_sparse_field` owns visibility/filter/exclusion/
candidate admission and source default-threshold selection. Ordinary nearest
and average-vector recommendations share that path. The latter keeps its
finite-score contract. Native exact eligible counts replace upstream estimates;
complete configurable sparse settings, IDF, input and service parity remain open.
Default/named APIs share immutable-root artifact lifetimes; old per-run sparse
copies, dictionary accumulation and blanket zero-admission paths are removed.
The standalone mutable index captures a postings view for search; persistent
queries use the existing shared root artifact cache.

Sparse value ownership and unchanged frozen input/format validation moved to
`sparse_values.mojo` to avoid a dependency cycle between mutable and immutable
index implementations and their shared search. Existing `akasha.index.sparse`
public value imports remain available; there is one implementation of each type.
No durable format or publication protocol changed.

## Floating-point correctness defect found and fixed

Mojo 1.0 enables `contract=fast` by default, including fusion across statements.
A source `product = x*y; score += product` therefore need not round the product
before addition. A minimal compiled reproduction returned two positive-infinity
hits where the Rust source returns only one: a cancellation became infinity
instead of NaN. Running the same Mojo reproduction with `--fp-mode=contract=off`
returned the source result. A second finite-input reproduction changed exact
zero into `1.4210854715202004e-14` and incorrectly admitted a point.

The existing overflow test and a new cancellation test failed before the fix.
A small `@no_inline` Float32 product establishes the required rounding boundary
without changing compiler settings for unrelated kernels. The postings kernel,
raw sparse scorer and custom recommendation scorer use it. The raw scorer test
also failed before that integration. This corrects numeric semantics; it is not
a performance tuning experiment.

Official compiler documentation checked against the installed version:
<https://mojolang.static.modular.com/1.0.0/docs/cli/run/>.

## Independent oracle

`rtk proxy python3 scripts/qdrant_sparse_recommendation_reference.py --nearest`
compiles the eight original search/scoring functions and original TopK, with the
same non-pruning representation shims as Q02d. The new fixture has 214 cases:
the previous 138, 12 overflow/threshold/rounding/bounded-TopK cases and 64
fractional-score cases. Source, extracted functions, scaffold and input-fixture
hashes are retained. The Q02d fixture is unchanged.

The source uses Float32 `score > threshold`: NaN, negative infinity and
`f32::MIN` are omitted, positive infinity can remain. Plain/final-posting paths
can include overlapping zeros; indexed batches omit them. Native deterministic
public-ID tie ordering is retained, not claimed as a full Qdrant server oracle.

## Verification

The 214-case native oracle passes exact IDs/F32 bits for the shared kernel,
with unfiltered indexed cases also checked through mutable SparseIndex. The
PointStore adapter matches all applicable small plain/indexed fixtures, including
missing fields and tombstones. The scalar/raw/custom rounding regression passes.
The 168 new Python cases pass, covering named/default exact/approx, Arrow output
after close, candidate rerank, threshold/ID exclusion, hybrid and reopen,
cancellation/deadlines/budgets and the separate recommendation finite contract.

Broader results: **87 native cases across 17 modules**, **1693 distinct Python
cases passed**, **1 optional Qdrant Edge case skipped**, and the C ABI build/test
passed. The complete Python run initially passed 1679 cases and failed 14
compiler-launch cases because its invocation did not activate the Pixi PATH
(`PermissionError: mojo`). Those 14 cases passed when rerun with `pixi run`;
no source changed and the applicable 1679 passing results were reused. Existing
two Python `__module__` warnings, one Starlette/httpx deprecation warning and the
Rust scaffold's unused-import warning remain.

Native coverage includes generation ownership/rollover/consolidation/close,
retained snapshots, sparse WAL/torn tails/reopen, point replacement/migration,
PointStore, field metrics/rerank, recommendation, lookup and competing compaction
publication. No new crash protocol was introduced; the relevant sparse recovery
and compaction failure tests passed.

Reproduction commands (run heavy checks serially):

```sh
rtk proxy python3 scripts/qdrant_sparse_recommendation_reference.py --nearest
rtk proxy pixi run mojo run -I src tests/mojo/test_sparse_nearest.mojo
rtk proxy pixi run build-python
rtk proxy pixi run env PYTHONPATH=python:. python -m pytest tests/python -q
rtk proxy pixi run test-c
rtk proxy git diff --check
```

The other 16 native modules recorded in the logs are `test_sparse_index`,
`test_named_sparse`, `test_sparse_recommendation`, `test_generation_fields`,
`test_generation_delta`, `test_generation_close`, `test_snapshot`,
`test_persistent_sparse`, `test_default_point_alignment`, `test_point_store_search`,
`test_field_rerank`, `test_field_metrics`, `test_recommendation`, `test_point_query`,
`test_sparse_storage`, and `test_compaction_publish` (all under `tests/mojo`).
Initial checks caught two test-construction errors (the raw scorer import name
and required SearchRequest metric/k arguments), immutable-list iteration, and
FilterExpression's clone rather than copy API; these were corrected before the
passing targeted runs. The independently reproduced FMA defect is described above.
Targeted logs: `.build/sparse-nearest-validation/`.

Native Linux acceptance is still user-deferred. No GPU path or durable format
changed. Full REST/gRPC, multivector HNSW, sparse IDF/configuration, low-precision
storage/type parity and the existing recall/performance failures remain open.
