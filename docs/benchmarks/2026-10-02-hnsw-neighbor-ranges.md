# HNSW adjacency ranges

Search now locates each expanded node's occupied adjacency range once, instead
of rereading its level/count/base metadata for every edge. Individual edge reads
retain storage bounds and mapping-open checks; target slot/level validation,
candidate ordering, distance arithmetic and counters are unchanged. The change
also applies when search is used during graph construction. Persisted bytes and
the public Python/Arrow API do not change.

The [plan](../plans/2026-10-02-hnsw-neighbor-ranges.md) explains the contract and
the reference implementation inspected. A direct borrowed-span prototype was
rejected after compiler probes accepted closing/mutating its owner before later
use. Those negative programs were never executed. The adopted API returns only
integer offset/count pairs and reads through the current owner. No raw pointer
or new mapping API is introduced.

## Native paired study

Three corpora each run three alternating before/after process pairs. Every process
performs eight passes of 67 unfiltered queries with fixed ef=32. Pass zero is
retained as warmup; the following table summarizes the median of the seven later
passes in each trial, then the median across trials. Values are total milliseconds
for 67 queries, not milliseconds per query.

| Corpus | Before native public path ms | After ms | Paired after/before median (range) |
| --- | ---: | ---: | --- |
| Uniform 128D | 10.957 | 9.118 | .834 (.827–.836) |
| Uniform 1536D | 40.056 | 37.780 | .945 (.919–.947) |
| Real 1536D | 25.733 | 23.864 | .929 (.910–.944) |

Every pair has byte-identical candidate IDs, distance counts and public ID/score
bits across all passes. Candidate collection, authoritative reranking and the
native public result path are timed separately. Collection runs before rerank and
the public path for each query, so it changes cache state; their elapsed times
must not be added or interpreted as independent stage costs. Rerank itself is
unchanged, and its small timing variations, including a 21% after sample at 128D,
remain in the report.

This diagnostic forces the graph path at ef=32. It does not establish .95 recall
for uniform data at that ef and is not the production planner's selected path in
every cell. The public mixed study below uses the established planner and recall
gates. All measurements are resident, serial, and separate from tests/builds.

An earlier inline-only prototype passed the same byte comparisons but showed only
about 4% improvement at 128D and smaller, inconsistent high-dimensional changes.
It was not adopted. Its complete samples remain alongside the range prototype.

## Public mixed workload

`benchmarks/bounded_batch.py --phases mixed --trials 3` compares the saved
post-overlay-cache package with the rebuilt range implementation. The same three
corpora, 32 blocks of nine reads/eight replacements/flush, background maintenance,
Arrow leases and reopened exact oracles are used. All 5,184 query audits, 72 recall
cells, 18 reopen checks and 18 leases pass. No benchmark overlaps a build or test.

The following ratios are after/before QPS: median and full three-trial range.
Uniform cells use planned exact scans; real all/correlated/independent cells use
HNSW. Selective real queries also use planned exact scans.

| Corpus | All | Correlated | Independent | Selective |
| --- | ---: | ---: | ---: | ---: |
| Uniform 128D | 1.016 (.956–1.018) | 1.074 (.888–1.085) | 1.106 (.791–1.161) | .965 (.765–1.570) |
| Uniform 1536D | 1.001 (.989–1.002) | 1.029 (1.022–1.060) | .986 (.720–1.025) | 1.032 (.913–1.090) |
| Real 1536D | 1.037 (1.022–1.129) | 1.057 (.790–1.070) | 1.075 (1.034–1.287) | 1.258 (.369–1.303) |

Real all and independent queries improve in each pair, while correlated trial 0
regresses. Large tail samples also affect planned scans, including the real
selective after trial 2 (p99 28.081 ms). Other retained p99 outliers are uniform
1536D independent after trial 0 (26.825 ms), real independent before trial 0
(19.620 ms), and real correlated after trial 0 (19.629 ms). The broad ranges do not demonstrate consistent tail
improvement or faster scan kernels. All samples are retained.

| Corpus / operation | Before median p95 ms | After median p95 ms | Paired latency ratio median (range) |
| --- | ---: | ---: | --- |
| Uniform 128D / write | 7.855 | 7.426 | .917 (.901–.951) |
| Uniform 1536D / write | 25.611 | 25.171 | .999 (.983–1.006) |
| Real 1536D / write | 16.522 | 16.060 | .972 (.920–1.025) |
| Uniform 128D / write + flush | 30.946 | 29.993 | .965 (.945–.980) |
| Uniform 1536D / write + flush | 79.163 | 77.286 | .987 (.957–1.004) |
| Real 1536D / write + flush | 70.829 | 69.923 | .987 (.984–.992) |

Flush ratios are essentially flat: medians 1.011/.992/1.005. Cached reopen also
stays flat, with median ratios .998/.999/.993. Initial opens without overlay caches
include graph reconstruction and improve modestly; the first before 128D sample
is unusually slow (1198 ms versus its other 714/714 ms samples) and is retained.
Whole-process peak RSS remains comparable; it is not an isolated allocation count.
This run does not establish Qdrant or non-resident parity.

## Validation

The new range tests first failed because the API was absent, then passed for
occupied/empty levels, invalid slot/level/count/offset, integer extremes, clearing
owned backing storage and accessing a closed mapping. Existing tests retain
corruption, cross-level rejection before stats mutation, tie order, admission,
inactive bridges, widening, native scalar and owned/mapped equivalence coverage.

Final validation passes 245 Mojo tests in 22 affected files, nine crash tests in
two suites, all 317 Python tests, and the rebuilt C ABI client. The crash suites
include retained-base publication boundaries. These are fresh targeted results,
not a relabeled full-repository run. Commands, logs and JUnit output are retained
with the benchmark evidence.

[Immutable source copies, all paired samples, rejected prototypes, compiler probes and validation](results/2026-10-02-hnsw-neighbor-ranges.json.gz)
have SHA-256 `dc537edf0e903ecf251ae6d6a447c76f880aedd245a3c9205ce4883bfe7f23ff`.
Identical workload plans are equality-checked and reference the existing
stream-fingerprint archive by hash. The earlier overlay archive also retains
the rejected mapped F32 row-loading prototype for subsequent phase analysis.
