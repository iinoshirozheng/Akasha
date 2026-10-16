# Native Qdrant work counts identify repeated scoring and the recall gap

On the current real-data correlated-filter cell, Akasha performs **1.860×**
as many distance evaluations as native Qdrant at the existing independently
selected recall-passing ef values. Its 1,160 search evaluations are followed
by 461 authoritative rerank evaluations, versus Qdrant's 872 total. This is
operation-count evidence, not a new speed result or proof that all wall-time
difference is explained by scoring. No acceptance gate closes.

## Method and reproducibility

The official Edge 0.8.0 Python wheel does not expose these per-query counters;
the pinned Edge search path creates a disposable hardware accumulator. A
separate `git archive` of upstream revision
`21db2f3ff95d50de3a2b88a741312c056fd1762d` is instrumented at
`MetricQueryScorer::score`, `score_stored`, `score_stored_batch` and
`score_internal`. Each scalar/byte/internal similarity adds one operation;
a batch adds its row count, and a separate counter records batch calls.
These atomics count arithmetic operations, not unique points or CPU time.
Search logic, graph links, filters, score arithmetic and planner choices are
unedited. Only the metric scorer and an added Rust example differ from upstream.

The example issues the same Edge `SearchRequest` used by the official wheel.
It resets counters after loading and before each serial request, and reads them
only after the synchronous search returns; atomics include segment-worker work.
There are no concurrent queries. Every corpus uses a clone of its accepted
bitmap trial-0 Qdrant database. Akasha uses the accepted bitmap binary and its
corresponding graph; the two engines have independently built graphs, not
identical graph bytes. The reference checkout remains unmodified.

Rust 1.97.0, matching the upstream minimum, is installed under the diagnostic
directory from official distribution archives, each checked against the
versioned manifest SHA-256. Cargo builds with the pinned lockfile, two jobs,
release opt-level 2, no LTO and 16 codegen units. These diagnostic settings are
explicitly not the wheel's performance settings. Build succeeds with one unused
trait-import warning. The first setup attempt used a Python without `tomllib`;
the project Python then required removal of a newer `tarfile` keyword. Corrected
drivers and the setup failure record are retained.

The native diagnostic binary SHA-256 is
`10d5053dbdad54dda45662c08c44d807d1b8bdeae21857ac66fdf20e375f6e94`.
Akasha's binary remains
`df71664362253188ef32828dc9d28f315a97eee2a82d76fe0fca43c0396839bb`.

## Counter and result validation

The main diagnostic covers **1,608 unique queries**: all 67 queries in four
modes on three corpora, both the frozen ANN request and a forced-exact control.
Each native request is executed in two separate process runs. Both runs have
identical counts, IDs and F32 score bits; all unique results match the official
wheel's IDs and F32 bits exactly (maximum difference **0 ULP**).

All **804 unique forced-exact controls** count exactly the live, filter-eligible
population, in both runs. Internal point-to-point scoring is zero throughout.
Together with the complete dense scorer instrumentation, this checks that
batch accounting neither drops nor double-counts those exact scoring operations.
It is not a proof of instrumentation coverage for sparse, quantized or multi-vector
paths; those paths are outside this Dot/F32 diagnostic.

The initial audit incorrectly tried to use Akasha's explicit default exact
`last_search_stats()` as an exact counter. That native API is documented as the
most recent approximate-query statistics, so the exact call leaves prior ANN
statistics unchanged. The assertion correctly stopped the audit. Its raw
exact statistics and derived totals remain in `akasha.json` **for evidence only
and must not be used as work measurements**. The corrected audit uses Qdrant's
explicit counters for the exact controls, and only Akasha's fresh ANN-request
statistics for cross-engine totals. Planned exact execution reached through
an ANN request does update Akasha statistics. The failure and corrected driver
are archived; completed native runs are reused only with successful exit records.

## Work at the frozen accepted ef values

The table excludes the three warmup ordinals, matching the **64 measured
queries** per formal cell. Each engine retains the smallest ef that passed the
existing recall grid on its trial-0 graph. Both recall values are at least .95
for every row. Search work includes base traversal and delta scanning. Akasha's
ANN `distance_evaluations` excludes its final rerank; the table adds the actual
`reranked_candidates`. For planned exact, retained candidates are not added as
new distance work. All ratios use unrounded means.

| Corpus | Filter | ef A / Q | Recall A / Q | Akasha search | Extra rerank | Qdrant total | A total / Q |
|---|---|---:|---:|---:|---:|---:|---:|
| uniform-128 | all | 128 / 96 | 0.967187 / 0.950000 | 4274.969 | 256.000 | 3763.922 | 1.204 |
| uniform-128 | correlated | 256 / 256 | 0.967187 / 0.967187 | 1514.859 | 460.750 | 1557.219 | 1.269 |
| uniform-128 | independent | 256 / 256 | 0.976562 / 0.982812 | 1517.250 | 460.750 | 1543.047 | 1.282 |
| uniform-128 | selective | 10 / 10 | 1.000000 / 1.000000 | 249.594 | 0.000 | 249.594 | 1.000 |
| uniform-1536 | all | 512 / 512 | 0.996875 / 0.993750 | 7628.219 | 1024.000 | 7689.703 | 1.125 |
| uniform-1536 | correlated | 512 / 512 | 0.976562 / 0.976562 | 1911.125 | 716.750 | 1927.703 | 1.363 |
| uniform-1536 | independent | 512 / 512 | 0.970313 / 0.978125 | 1904.250 | 716.750 | 1922.406 | 1.363 |
| uniform-1536 | selective | 10 / 10 | 1.000000 / 1.000000 | 249.594 | 0.000 | 249.594 | 1.000 |
| real-1536 | all | 32 / 24 | 0.967187 / 0.956250 | 1580.438 | 64.000 | 1496.969 | 1.099 |
| real-1536 | correlated | 256 / 128 | 0.982812 / 0.965625 | 1160.141 | 460.750 | 871.547 | 1.860 |
| real-1536 | independent | 128 / 128 | 0.957812 / 0.962500 | 817.672 | 256.000 | 852.188 | 1.260 |
| real-1536 | selective | 10 / 10 | 1.000000 / 1.000000 | 249.594 | 0.000 | 249.594 | 1.000 |

The planned selective scans count the same eligible population in all three
corpora. In the ANN cells, the extra rerank is 64–1,024 full-vector evaluations
per query on top of search work. This explains an operation-count difference;
it does not assign all heap, metadata, binding, memory or scheduling cost to it.

## Same-ef control for real correlated filtering

An additional 134 unique native requests (67 queries × two ef values) match the
official wheel's IDs and score bits exactly. Replayed Akasha IDs and complete
ANN statistics match the existing accepted trial-0 reports for all 128 measured
query/ef pairs. These are diagnostics, not a changed ef grid or post-hoc acceptance.

| ef | Akasha recall | Qdrant recall | Akasha search | Akasha rerank | Qdrant total |
|---:|---:|---:|---:|---:|---:|
| 128 | 0.9453125 | 0.9656250 | 811.703 | 256.000 | 871.547 |
| 256 | 0.9828125 | 0.9890625 | 1160.141 | 460.750 | 1221.844 |

At either common ef, Akasha's search-distance work is lower than Qdrant's, but
the additional authoritative rerank makes its total higher. At ef=128 Akasha
has 605/640 exact-neighbor hits, three short of the unchanged 608/640 gate;
Qdrant has 618/640. Akasha consequently selects 256 under the unchanged grid,
increasing both search work and rerank width. The same-ef control separates
these two effects without claiming why the independently built graphs differ
in recall or weakening the quality threshold.

## Consequences for the next implementation

Further small SIMD/code-generation probes are not the best-supported next step.
The source already returns scored candidates from each graph; Akasha then keeps
only their IDs and reranks the retained per-source ef candidates from MemTable
authority. Qdrant's segment scorer reads its authoritative vector storage and
the Edge aggregator merges the scored results. That ownership difference must
be resolved before graph scores can be reused safely.

Current Akasha tests deliberately give the graph and MemTable different vector
values. Recovery validates graph/config/checksum/sequence metadata and current
IDs; it does not compare every graph vector to the current authoritative owner.
F32 cosine preprocessing also differs from raw authority, and compact encodings
are approximate. Therefore this evidence does not authorize simply skipping
rerank, trusting a source ID as value identity, scoring only the first k IDs,
or removing finite-value checks. A safe next layer must either score directly
from the captured authority or prove the exact score's owner and arithmetic
identity, while retaining replacement, deletion, filter, corruption and reopen
contracts. Separately, the ef=128 recall miss needs query/graph-quality work;
forcing the lower ef is not an optimization that passes acceptance.

Latest accepted strict gates remain warm **6/36**, mixed **15/36**, write+flush
**3/9**, one-client HTTP **6/36**, four-client HTTP **12/36**. Native Linux,
type/capacity and sustained nonresident requirements remain open. No production
source or installed library is changed by this diagnostic.

The archive retains instrumentation, setup/build/run drivers and logs, official
toolchain manifest/install identities, complete input request vectors, native
counts/results, wheel/Akasha responses, the failed audit, repeat audits and
same-ef controls. Large database snapshots, compiler distributions and binaries
are represented by source provenance and hashes rather than embedded. Input
database inventory is in archive
`431aaa05372c567f4b6d2b96e72e501c672b2324a239690f071942b085ac1b34`;
the accepted bitmap input archive is
`39c9f2acda7249bd88e51990e83cb08a5c9ea863af340cd6a75881646a46d95f`.
Pinned Qdrant source is Apache-2.0 licensed; the archive includes its license.


[Complete artifact](results/2026-10-16-qdrant-native-work.json.gz), 82 files, 18,688,378 bytes; SHA-256 `6db93d82aab1cfb56d3956d879fc1c5f86c4cd509b8ffb1914cecf9af3794cf4`.
