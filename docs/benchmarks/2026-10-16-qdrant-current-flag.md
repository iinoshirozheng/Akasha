# Bounded mapped HNSW current-flag reads

Fresh acceptance remains **FAILED**: warm recall 36/36 and speed 4/36; mixed
recall 36/36 and speed 13/36; combined write+flush 5/9. The accepted change has
a repeatable low-dimensional local benefit, not complete Qdrant speed parity.

`HnswGraphView.is_current` now reads its UInt8 flag through the existing inline
`MappedFile.load_scalars` operation. Open-state, slot-domain and byte-domain
checks, flag equality, and false-on-error behavior remain. No pointer escapes;
the mapping still owns the read. No durable format, graph, score, planner,
candidate budget, ef selection or public API changes.

The [unchanged-parent native profile](2026-10-16-hnsw-heap-profile.md) localized
8.1–8.5% of low-dimensional main-thread top-of-stack observations to the old
byte-read method. That observation motivated this one-call-site change; it is
not an assertion that the entire observed cost disappears.

## Saved-graph comparison

The initial serial old/new/old and new/old/new runs use the original saved
graphs, queries, selected efs and seven public Python query passes. All twelve
cells in each order preserve result digests, recall and every query statistic.
Uniform 128 all improves QPS 8.9% and 5.5%, but independent p95 regresses 14.7%
and 4.4%. Several high-dimensional cells change direction between orders.
These initial slow samples are retained.

A fixed confirmation matrix then runs three fresh pairs per corpus, alternating
before/after, after/before, before/after, with 31 passes per process. All result
digests, recall arrays and counters again match. No compiler, test or archive
compression overlaps either measurement set. Ratios below are medians of the
three paired ratios; all individual samples remain in the raw artifact.

| Corpus / mode | QPS after/before | p95 after/before |
| --- | ---: | ---: |
| Uniform 128 / all | 1.059 | .941 |
| Uniform 128 / correlated | 1.026 | .991 |
| Uniform 128 / independent | 1.022 | .976 |
| Uniform 128 / selective | .998 | .913 |
| Uniform 1536 / all | 1.010 | .994 |
| Uniform 1536 / correlated | 1.007 | .989 |
| Uniform 1536 / independent | 1.010 | .992 |
| Uniform 1536 / selective | 1.021 | .992 |
| Real 1536 / all | 1.005 | .994 |
| Real 1536 / correlated | 1.005 | .995 |
| Real 1536 / independent | 1.026 | .969 |
| Real 1536 / selective | .976 | 1.036 |

The low-dimensional all-mode improvement repeats in every confirmation pair
(5.4–6.6% QPS), and all nine ANN median QPS/p95 ratios improve. This supports
retaining the small call-site simplification, without claiming universal latency
improvement. Uniform 128 correlated confirmation trial 0 has p95 1.086; real
selective, an unchanged planned-exact control, slows in two of three pairs.
Controls are not removed from the report or assigned a causal explanation.

## Validation and identity

The mapped-view nine, segmented 21, filtered eight and search-layer 14 tests
pass: **52 targeted Mojo tests**, including owner-close rejection and source
replacement. The Python shared library compiles and is used by every saved-graph
worker. Existing tests already cover this unchanged boundary behavior, so no
implementation-mirroring test is added.

The earlier `5f6d4dd` Python/distributed/service result (387 passed, one skipped),
C client and fixed-quality result remain prior evidence, not freshly rerun
checks for this one-call-site change. Fixed L2 remains .9458333333 against .95;
no quality algorithm or threshold is changed. Formats, crash and GPU paths are
unchanged. Saved-graph digests/counters do not establish construction, native
Linux, concurrent-client or sustained-nonresident acceptance.

Baseline library SHA-256:
`fedc10583ed5d522bcf474493e1dda30d2434f3757f711d9ac1a0b2d122b95ad`.
Candidate library SHA-256:
`2342e619426448ed52498bb5d7eddb0bdbbe51f30ffb520f6a3b543be5c8d381`.

## Fresh Qdrant acceptance

Three fresh serial trials per corpus build/reopen both engines with N=8192,
64 measured queries, K=10, Dot F32, seed 12345, and the unchanged symmetric ef
grid 10/16/24/32/40/48/64/96/128/256/512/1024. Each engine independently selects
its smallest passing ef without considering timing. All builds/reopens complete.
All 36 quality comparisons pass, but all 27 warm ANN speed comparisons fail;
only four planned-exact selective comparisons pass both QPS and p95.

The mixed matrix uses copies of the new trial-0 databases, with 32 blocks of
nine queries followed by one eight-point replacement batch and flush. This is
serial foreground interleaving with the engines' background workers, not
concurrent-client load. All nine paired trials complete; 5,184 query audits,
18 exact-oracle reopen checks and nine retained Arrow leases pass. Query recall
passes 36/36 and strict speed 13/36. One uniform-128 independent filtered ANN
comparison passes; the other filtered ANN comparisons fail.

The following are median Akasha/Qdrant ratios, reported as QPS / p95. Individual
comparisons, not medians, determine each pass count. Prior warm 4/36 and mixed
10/36 results are separate snapshots, not paired causal baselines.

| Corpus / mode | Warm QPS / p95 | Pass | Mixed QPS / p95 | Pass |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 / all | .585 / 1.716 | 0/3 | .974 / .571 | 1/3 |
| uniform-128 / correlated | .515 / 2.109 | 0/3 | .964 / .907 | 0/3 |
| uniform-128 / independent | .486 / 2.199 | 0/3 | .934 / .801 | 1/3 |
| uniform-128 / selective | 1.116 / .789 | 2/3 | 1.436 / .660 | 3/3 |
| uniform-1536 / all | .959 / 1.046 | 0/3 | 1.016 / 1.077 | 0/3 |
| uniform-1536 / correlated | .668 / 1.406 | 0/3 | .632 / 1.670 | 0/3 |
| uniform-1536 / independent | .728 / 1.254 | 0/3 | .656 / 1.569 | 0/3 |
| uniform-1536 / selective | .998 / .863 | 1/3 | 1.018 / .886 | 2/3 |
| real-1536 / all | .949 / 1.020 | 0/3 | 1.252 / .768 | 3/3 |
| real-1536 / correlated | .421 / 2.085 | 0/3 | .547 / 1.656 | 0/3 |
| real-1536 / independent | .733 / 1.272 | 0/3 | .882 / 1.125 | 0/3 |
| real-1536 / selective | .954 / 1.007 | 1/3 | 1.426 / .654 | 3/3 |

Combined update+flush passes 3/3 uniform-128, 2/3 uniform-1536 and 0/3 real.
Real p95 ratios are 1.647, 2.053 and 2.304; one real mean service rate also
falls below Qdrant. Each comparison uses the sum from the same block, rather
than summing quantiles. Write-only latency has different durability boundaries
(Akasha fsyncs on update; Qdrant is synchronized at flush). No write optimization
is attributed to this read-path patch.

Every Akasha build, reopen and mixed worker records the candidate binary hash.
The four acceptance commands exit 1 for failed gates, with no worker execution
errors. Native Linux, concurrent/nonresident/type/capacity acceptance and the
fixed L2 gate remain outstanding. Thresholds and production ef are unchanged.

## Evidence

[Raw comparisons, full acceptance, source patch, validation and drivers](results/2026-10-16-qdrant-current-flag.json.gz)
retain all initial and confirmation samples. Large mixed-plan vector arrays
remain local; the archive records their full hashes, sizes, spec, selected efs,
initial workload hashes and deterministic `benchmarks.qdrant_mixed.prepare`
regeneration instructions. Datasets, database files and compiled libraries are
not embedded.

Archive: 173 files, 6,583,150 bytes. SHA-256:
`781c71b1bea48e943f377ee44448e3dac34452e3ea2e97e6fe26393dffe992d1`.
All embedded file hashes were verified after writing the archive.
