# Lance Materialized Bitmap Target Validation

Date: 2026-10-31. Baseline: `64de9df`. Mojo `1.0.0 (ed45d567)`.

The native JSON-index work now has an actual bitmap target: typed scalar
ordering, training, nullable searches, sorted old/new merge and row remapping.
The existing native JSON extraction/conversion results feed this target in an
integration test. It is a bounded materialized index API, not yet a durable
collection index or a complete Lance scalar-index implementation.

## Source and native behavior

Pinned Lance `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` supplies:

- `scalar/btree.rs::OrderableScalarValue` ordering and equality delegation.
- `scalar/bitmap.rs::search_with_options`, `streaming_build_and_write`,
  `finish_run`, `remap_bitmap_state` and `retain_valid`.
- `lance-index-core/src/scalar.rs::OldIndexDataFilter` and `SearchOptions`.

DataFusion common 54.1.0 (the version in Lance's lockfile) supplies actual
ScalarValue types/equality, including Float64 bit equality. Rust 1.92.0
`ded5c06cf21d2b93bffd5d884aa6e96934ee4234` supplies the signed-bit transform in
`core/num/f64.rs::total_cmp`. The downloaded source hash is frozen; original
comparisons execute the same version of the Rust compiler. Arrow 58.4.0's real
sort kernel sorts source inputs ascending/nulls first. Roaring 0.11.4 supplies
the oracle's actual materialized row sets.

`lance_scalar.mojo` supports the five JSON target types: Boolean, Int64,
Float64, Utf8 and LargeBinary. Typed null sorts first. Negative/positive zero
and NaN payloads/signs remain distinct; Unicode is ordered by UTF-8 bytes and
binary values by raw bytes. Native mixed target types are validation errors,
not a newly invented cross-type ordering. Other DataFusion scalar types remain
outside this port's current scope.

`lance_bitmap.mojo` retains source equal-value runs and sorted old-key merge.
Its key directory is a sorted owned list with binary search, replacing the
source BTreeMap; postings use the already source-ported RoaringRowSet.
The old-data filter applies only to old postings. Exact row filters and
high-32-bit fragment filters preserve stable/address-ID distinctions. Old keys
whose postings become empty remain in the directory. Missing remap entries
retain IDs, explicit null mappings delete them and collisions deduplicate.
Updates/remaps return independently owned indexes and never mutate old readers.

Search covers equality, all open/closed/unbounded range combinations, IN and
IS NULL. The source's unusual Equals(null) and IN-containing-null behavior
returns null rows as true; other predicates optionally track them as unknown.
Unbounded ranges visit non-null keys only. Raw selected and unknown sets may
overlap when an ID occurs under multiple keys; NullableRowSet gives nulls
precedence, as upstream. Full-text and LIKE-prefix preserve original rejection
messages rather than silently using a different search path.

## Independent validation

The generator compiles the listed original Lance methods unchanged. The
adapters provide in-memory IndexStore/writer/stream, metrics, schema error
carrier and materialized sets. Original DataFusion/Arrow/roaring implementations
perform scalar equality, sorting and set operations. The adapter's load/state
behavior mirrors source null separation and empty-key retention. It does not
execute Lance file encoding, cache/lazy IO, query planning or shard merging.

| Original-source evidence | Count |
| --- | ---: |
| Training/update/remap scenarios | 61 |
| Exact ordered index states | 183 |
| Typed ordering/equality pairs | 3,453 |
| Search outcomes across three states and both null-tracking settings | 98,160 |
| Included original unsupported-query errors | 720 |

Every recorded state, ordered key, posting, search selected/null set, error
message and comparison matches. Inputs cover empty indexes/batches, batch
boundaries inside equal-value runs, absent keys, duplicate values/IDs, all
typed-null range endpoints, nonfinite/NaN/zero Float64 bits, Unicode/NUL and
binary prefixes, UInt64.MAX and multi-fragment IDs. A dense 4,097-ID posting
exercises the underlying array/bitmap transition through build/update/remap.

Five new tests plus ten existing row-set/JSON-input tests pass (**15 total**):

```text
rtk proxy pixi run python scripts/lance_bitmap_reference.py
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_bitmap.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_rowset.mojo
rtk proxy pixi run mojo run -I src tests/mojo/test_lance_json_index_input.mojo
```

New non-oracle checks cover the actual JSON extraction/inference/conversion
to bitmap path for all five targets, false versus null, ownership, old-reader
preservation, exact logical-state byte limits, row/type/order failures,
cancellation and expired deadlines. Existing tests retain the 32,405 JSON
conversion outcomes and the complete row-set/nullable source comparisons.

Initial missing-module failures preceded implementation. The integration test
then exposed a real nullable access bug: mixing a SIMD Boolean and Optional in
`and` could coerce a false operand to a present Optional(False). An Int64 target
therefore entered the Boolean branch and unwrapped an absent value. Explicit
Bool presence checks fix the dispatch. Minimal reproductions and failure logs
are retained; the final five-target integration test guards this path. Other
initial compilation fixes concerned list inference and borrowed-field moves.

All four committed fixture files reproduce byte-for-byte. Generator, source
units, crate archives/extracted sources, compiler and final files are hashed.
Logs/results are in `.build/lance-bitmap-validation/results.json`; committed
provenance is in `tests/fixtures/lance-bitmap/sources.json` and the port registry.
No application runtime imports the new modules yet. Public runtime/build and
the prior full Python **3,752 passed / 1 skip** evidence are unchanged, reused
as historical evidence rather than reported as new runs.

## Limits and unfinished integration

Default native limits are one million input rows/keys/posting cardinalities
and 64 MiB. The byte limit bounds logical index state and one input copy
separately, including key/posting descriptors and live key/set bytes. It
excludes allocator/capacity overhead and is not a peak-RSS guarantee. Sorting
can hold input, ordered copy, stable-sort buffer and output copy; merges retain
old and new states and temporary posting sets. Remapping materializes each
posting's UInt64 IDs under the same byte bound. Allocation errors return no
partial index and leave input/old state intact.

Controls check input/state candidate counts, input copying, run/old-key work,
set operations, query values and remap rows. The standard stable sort is bounded
and checked before/after; it is not interrupted internally. Candidate limits
also apply to individual underlying set operations, not a global CPU counter.

`merge_sorted` accepts already materialized batches and preserves runs across
them. It does not claim a disk-backed streaming writer. Remaining work includes
JSON prefix-only inference buffering, all-null-stream Utf8 default and fixed
learned type; exact function/path matching and residuals; incremental streaming
publication; durable create/list/drop/rebuild/update, migration/recovery and
public collection/Python/Arrow/service integration. Lance shard k-way merge,
file serialization/cache, other scalar target variants and other scalar types
remain explicit requirements. No new authoritative sidecar format was added.

All 49 full product packages, M5/M6 and deferred native Linux acceptance remain
open. No performance tuning was performed.
