# Mapped F32 validation reads

Mapped HNSW structural validation now copies F32 rows in checked SIMD chunks
with a scalar tail into the existing owned validation buffer. Metric validation,
all graph checks, checksums, bounds and owner checks remain intact. Other scalar
representations and query/mutation algorithms are unchanged. The mapped owner
already requires little-endian hosts; no new platform claim or format change.
See the [design and acceptance](../plans/2026-10-02-mapped-vector-read.md).

## Fresh-process cached opens

Three alternating before/after process pairs per corpus use identical closed,
cache-populated database copies. The baseline includes the bounded owned F32
reader. After timing each open, 32 exact requests are checked against the fixed
independent Float64 oracle and another 32 ANN requests are compared across the
pair. All 576 exact checks and 576 ANN result comparisons pass; IDs and scores
are identical. Each worker verifies its loaded extension hash against the
intended package. The prototype was built from its copied binding entry file.

| Corpus | Before median ms | After median ms | After/before paired median (range) |
|---|---:|---:|---:|
| Uniform 128D | 112.287 | 108.713 | .972 (.968–.984) |
| Uniform 1536D | 261.563 | 219.423 | .839 (.834–.880) |
| Real 1536D | 274.600 | 226.716 | .832 (.826–.839) |

All nine pairs improved, with about 16–17% median improvement on the high
dimensional corpora. The prior phase probe measured about 98/106 ms of mapped
base structural validation; it predates this change and is not a new per-phase
measurement. The earlier row-load experiment was inconclusive while delta
reconstruction dominated opens. This comparison uses the current cached path.

The OS cache is present. These are not controlled cold/non-resident results.
No build, test or archive compression overlapped the comparison. No query,
write or Qdrant speed claim follows from this open-only measurement.

## Validation

The isolated implementation passed 58 tests in six files: four new test
functions, existing mapped graph, owned snapshot, v1 fixture, quantized graph
and mapped owner checks. The new tests also pass on the baseline implementation.
They cover 30 dimension/metric combinations, raw component bits, owned/mapped
search results, closed owners, and 300 checksum-resigned nonfinite/unsafe values
in active and inactive rows across chunk/tail positions. Zero and nonunit cosine
rows, malformed lengths, overlapping offsets and truncation remain rejected.

Two initial test compilation attempts used the wrong `bitcast` syntax; their
logs are retained. The final test uses the installed standard-library function.
Compiler: Mojo 1.0.0 (ed45d567), Apple M4 CPU target and `metal:4` accelerator.
Production full integration passed **130 Mojo files / 954 tests, eight crash
files / 23 tests, 317 Python tests**, rebuilt Python/C bindings, the external
C11 ABI client and all three rebuilt examples. The native maintenance worker
was retained throughout. Builds used two workers; native tests ran serially.
Python completed with three existing warnings in 13.07 seconds.

The first full run stopped at the independent-reader file-retirement test:
its child launched `mojo run` without the explicit accelerator setting and the
compiler crashed during startup. The existing compiler launcher was then supplied
through PATH to both parent and child; all nine retirement tests passed. The
runner resumed only failed/unrun files. Initial logs are retained, not overwritten
as successes. This is a runner correction, with no engine/test code change.

A separate post-integration audit found that legacy NDJSON export drops named
fields and named-only points. The tests at this checkpoint did not cover that
interface; a [subsequent logical export/import fix](../research/2026-10-02-named-logical-export.md)
adds that coverage. Successful regression results do not establish complete
feature delivery.

[Sources, every paired sample, binary hashes and complete integration logs](results/2026-10-02-mapped-vector-read.json.gz)
have SHA-256 `2f619a2b919e58656023e70d9ed8d0a3194e0c16cf52c1f86cb685db124fb04e`.
