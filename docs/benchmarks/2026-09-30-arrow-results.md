# Direct native search result columns

`search_record_batch(collection, request)` now writes native search results into
owned NumPy I64 IDs and F32 scores, then lets PyArrow retain those buffers. The
binding does not construct per-result Python dictionaries or `SearchResult`
objects on this path. It performs one native AoS-to-column pass, writing 12 bytes
per result; native query allocations and input conversion still exist.

## Interface and ownership

The Python facade shares the existing SearchRequest dispatcher, validation,
resource limits, metrics and error mapping. Native search methods specialize the
same exporter for columns or the established Python row API. Exact, approximate,
sparse, hybrid and Boolean-filtered requests keep their original query behavior.
`Collection.search` and `results_to_record_batch` preserve their documented row
interfaces. The latter still converts already-created Python result sequences.

Output arrays are allocated by official `numpy.empty` and filled through Mojo
`from_numpy_array` mutable spans. PyArrow retains the NumPy owners. Each RecordBatch
slice can outlive the parent batch and the collection; the last Arrow owner frees
the arrays. These outputs own their data independently of database generations.
The leased document scanner and actual native C Data release state remain #58.

## Verification

The initial integration test failed because `search_record_batch` did not exist.
The implementation then passed `pixi run build-python`, all 46 tests in
`tests/python/test_arrow_c_data.py`, and the complete 92-test Python suite via
`pixi run env PYTHONPATH=python:. pytest tests/python -q`. The two existing
deprecation warnings remain.

The 26 added cases cover all three metrics × four request modes × filtered or
unfiltered execution; exact result order and Float32 scores match the public row
API. Further cases check empty columns, full signed-I64 boundary IDs, ties, input
and resource validation, closed collection errors, collection-independent output,
and slices retaining ownership after every parent is dropped. Replacing the
Python `SearchResult` constructor with a failing stub does not affect the direct
path. Intercepting actual NumPy allocations proves two correctly typed buffers,
12 bytes/result, both Arrow pointer identities, and final-slice release through
weak references.

Only the bindings, Python facade/Arrow adapter, tests, benchmark and docs changed
after the [#56 engine validation](2026-09-30-file-retirement.md). Its 761 Mojo,
19 crash, C ABI, build and example results remain applicable to the unchanged
kernel. The Python extension was rebuilt and every Python test rerun for #57;
no new durable format or GPU execution path was introduced.

## Cost measurement

Command:

```sh
pixi run env PYTHONPATH=python:. python benchmarks/arrow_ingress.py \
  --mode results --label direct-arrow-results \
  --output docs/benchmarks/results/2026-09-30-arrow-results.json
```

The deterministic workload contains 4,096 points × 16 F32 dimensions, values
`arange(rows * dimension) % 101`, ascending I64 IDs and an all-ones dot query.
Both paths run the same embedded exact query. Each cell warms both paths, checks
complete RecordBatch equality, then records nine untraced query-plus-export runs.
Separate allocation runs do not contaminate timing. Mojo 1.0.0 (ed45d567), NumPy
2.4.6 and PyArrow 21.0.0 on macOS arm64 were used.

| Results | Python rows → Arrow median | Direct columns median | Traced peak: rows → direct |
| ---: | ---: | ---: | ---: |
| 32 | 122.875 µs | 130.416 µs | 16,691 → 2,991 bytes |
| 1,024 | 837.375 µs | 201.167 µs | 428,971 → 14,625 bytes |
| 4,096 | 2,990.208 µs | 329.834 µs | 1,663,247 → 51,978 bytes |

Small results remain sensitive to fixed NumPy/PyArrow overhead: direct output was
slightly slower in the 32-result cell. Large cells remove substantial row-object
work. These are one-process synthetic measurements, not service QPS or a general
latency guarantee. `tracemalloc` excludes Mojo-owned query memory and is not peak
RSS. Arrow's allocator delta was zero for the direct path because it reused NumPy
buffers, while the buffers themselves still consumed 384/12,288/49,152 bytes.
An untimed ownership probe observed both allocations, matching Arrow addresses,
and their release after the last slice for every cell. The native one-pass copy
count is source-derived; buffer allocation sizes and pointer lifetimes are measured.

[Raw runs and provenance](results/2026-09-30-arrow-results.json) record source hash
`347477be49e24eb6280f8ad7869d4be58231a459a3299cfc5c24225ddd99c414` using the
#56 path/NUL/bytes/NUL algorithm and the benchmark's own SHA-256. This completes
#57's implementation and validation; commits and branch integration remain pending.
