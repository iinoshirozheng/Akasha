# Bounded small-delta scoring

The segmented HNSW query now scans a small mutable delta when a live immutable
base exists. Base traversal, native vector storage, mutation/index construction,
durable formats and authoritative F32 reranking are unchanged. The merged result
remains approximate. `segmented-delta-scan-*` identifies this execution path.

The work limits are 1,024 physical slots, 1,572,864 vector components and physical
slots no greater than normalized initial ef times M0. Inactive history counts
against the bounds. Overflow-safe checks reject invalid inputs. This follows
the local Qdrant plain-index use of vector size/cardinality bounds, using measured
Akasha limits. [Design and acceptance](../plans/2026-10-02-hnsw-delta-scan.md).

## Diagnostic evidence

An isolated unconditional-scan prototype ran three alternating public-query
pairs on the fixed real 1536D corpus. It improved passing all/correlated ef32 and
independent ef64 query cells by about 11–22%; paired recall was identical.
Independent ef32 remained below the .95 recall gate (.946875), so it receives no
matched-quality speed claim. Exact requests alternated with ANN in this diagnostic;
it is not a pure warm-query comparison. Selective exact controls varied, with
some regressions retained.

A separate native sweep used 64/256/1,024/4,096 current delta points, ef10/32/128,
k10, 16 queries and three passes in each of three fresh processes per corpus.
Graph/scan order alternated per query. Its 108 cells cover uniform 128D, uniform
1536D and real 1536D; each cell has 48 timings. Every scan matched the independent
NumPy Float64 oracle. Low-recall graph cells were retained, without speed ratios
unless both algorithms passed .95. Setup, query preparation and oracle work were
outside query timing. This source microbenchmark has no base, and does not model
full public query cost.

The sweep also rejected unconditional scanning. At real 1536D, 1,024 slots/ef10,
graph recall was .95 and graph median time 62.5–63 µs versus scan 96–97 µs.
At 4,096 slots/ef32, graph recall was .9875 and graph time 190–202 µs versus scan
386–400 µs. The production bounds exclude both cases. These measured limits are
a conservative policy, not a claim of an optimal crossover on every machine.

## Validation

Installed Mojo 1.0.0, Apple M4 Pro; explicit `metal:4` accelerator and `apple-m4`
CPU compiler targets. Five new test functions include 22 owned/mapped and native
metric/scalar cases, full and bounded candidate sets, stable ID ties, replacement,
delete/reinsert, empty/filtered admission, physical-history limits, zero base,
integer extremes, invalid query/config/index and excess demand. Existing native
HNSW scalar support remains F32/F16/BF16 dot/L2/cosine and I8 dot/cosine.

The affected suite passed **130 Mojo tests in 12 files and 9 crash tests in two
files**. The final added candidate-cutoff assertions also passed all five new
test functions. Rebuilt Python: **317 passed**, three existing warnings, 12.32 s.
Rebuilt C library and external C ABI client passed. This is an affected-path run;
the earlier full CPU suite remains documented at the
[integration checkpoint](../research/2026-10-02-cpu-integration.md).

The initial behavioral tests failed on the missing execution label before
implementation. Initial test compilation needed corrections to the existing
`sorted_entries` and `std.memory.bitcast` APIs. Failed prototype builds and
low-recall/slow diagnostic cells are retained with the final evidence.

## Final paired public mixed workload

Three alternating before/after process pairs per corpus use the established 32
blocks of nine reads, eight replacements and flush, with an Arrow lease retained
through close. All **5,184 query audits, 72 recall cells, 18 reopen oracles and
18 leases passed**. The minimum mean recall was .952778. QPS after/before paired
median (range):

| Corpus | All | Correlated | Independent | Selective |
|---|---:|---:|---:|---:|
| Uniform 128D | 1.006 (.991–1.024) | 1.041 (1.004–1.048) | .902 (.897–1.289) | 1.304 (1.017–1.420) |
| Uniform 1536D | 1.005 (.979–1.013) | .927 (.645–.927) | .938 (.938–.994) | .928 (.920–1.147) |
| Real 1536D | 1.115 (1.114–1.182) | 1.207 (1.155–1.231) | 1.165 (1.140–1.166) | .913 (.555–.991) |

The uniform modes and real selective mode execute planned exact scans. Across
the three after trials, real ANN queries used small-delta scanning 528 times and
graph-only delta traversal 120 times as physical history crossed the bound.
This is a consistent ANN improvement, with control regressions retained: after
uniform-1536 trial 2 correlated/block 11 took 28.361 ms; real trial 0 selective/
block 15 took 14.570 ms. No maintenance cause is inferred from timing alone.

Median write-only p95 before→after was 6.965→7.293, 24.546→25.014 and
15.651→17.019 ms respectively. Paired ratios were 1.047/1.019/1.075. Combined
write+flush p95 medians were 29.603→30.389, 78.075→78.731 and 70.888→70.935 ms;
paired ratios 1.027/1.001/.981. Cached reopen medians were 125.181→126.833,
351.688→357.887 and 368.328→367.783 ms. Writes and reopen are not claimed as
benefits of this query change.

## Fresh Qdrant comparisons

Both comparisons use pinned Qdrant Edge 0.8.0, the same previously constructed
closed databases, inputs/configurations/oracles, three alternating engine pairs
per corpus and serial public Python requests. No build, test or archive
compression overlapped either benchmark. Qdrant's public API does not expose
per-query fallback counters. All results are resident with OS cache present.

Pure warm queries use the original ef grid 32/64/128/256/512/1024, 64 measured
queries per cell, and three retained warmup queries. Before each mode, the exact
API passes all 67 independent Float64 oracle checks; exact requests are not
interleaved between timed ANN requests. There are **432 curve cells, 27,648 timed
query audits, 4,824 exact checks and 1,296 retained warmups**. All 36 selected
comparisons pass .95 recall, using the lowest passing ef on that grid. The 105
below-recall cells remain in the artifact. Selected Akasha/Qdrant QPS median
(range):

| Corpus | All | Correlated | Independent | Selective |
|---|---:|---:|---:|---:|
| Uniform 128D | .909 (.769–.913) | 2.658 (2.622–2.782) | 2.140 (1.612–2.376) | 1.048 (.939–1.092) |
| Uniform 1536D | 1.711 (1.698–1.761) | 1.218 (1.202–1.236) | 1.136 (1.124–1.153) | .822 (.748–.906) |
| Real 1536D | .716 (.666–.747) | .652 (.648–.666) | .428 (.411–.429) | .729 (.727–.743) |

The original Akasha database fixtures have no optional overlay cache. Their
fresh-process opens include delta reconstruction: medians 667/1734/1406 ms,
versus Qdrant 53/65/63 ms. Those are not the post-flush cached reopen numbers
below, and neither scenario is controlled cold/nonresident.

The fresh mixed comparison passes **5,184 audits, 36 recall cells, 18 reopen
oracles and nine Akasha leases**. Akasha/Qdrant QPS median (range):

| Corpus | All | Correlated | Independent | Selective |
|---|---:|---:|---:|---:|
| Uniform 128D | 2.618 (1.786–3.222) | 3.797 (3.417–6.322) | 4.563 (3.329–5.313) | 1.939 (1.161–2.525) |
| Uniform 1536D | 1.731 (1.618–1.742) | 1.376 (1.333–1.421) | 1.264 (1.219–1.283) | .858 (.747–.906) |
| Real 1536D | 1.304 (1.009–1.366) | 1.097 (.970–1.187) | .738 (.589–.775) | 1.082 (.753–1.182) |

Combined write+flush p95 median Akasha/Qdrant is 32.201/39.338,
78.475/35.823 and 70.534/38.947 ms. Cached reopen medians are 126.202/66.508,
353.936/54.983 and 366.871/73.497 ms. Durability boundaries differ (Akasha batch
WAL fsync versus Edge flush); report the aligned observed block totals, not a sum
of component percentiles. The largest real independent Akasha query was 4.844 ms
in trial 1/block 12. Cross-run ratio changes are not attributed solely to this
optimization; the isolated before/after pairs above establish its effect.

Warm real-data queries, mixed independent filtering, high-dimensional selective
queries, durable writes and reopen still have performance gaps. Controlled
nonresident/cold, distributed networking and final Git delivery remain open as
documented in the integration checkpoint. M5/M6 is not marked complete.

## Retained evidence

[Compressed raw reports, sources, drivers and validation](results/2026-10-02-hnsw-delta-scan.json.gz),
SHA-256 `117b9ea2c6a476b3e2ab2cdbc34534052c89ba2b87b92e21c1e67543d471f183`.
It contains the isolated prototype and sweep, production source, before/after
patch, exact commands, binary hashes, every timing/ID/recall cell, warmups, failed
builds, affected-test logs and Python JUnit. Repeated mixed workload plans were
checked for equality against the existing streaming-fingerprint archive and
referenced by hash. Full diagnostic commands are in `reports` under
`.build/delta-scan-benchmarks.json`; prototype drivers are under `sources`.
