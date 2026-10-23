# Native scoring profile and rejected bulk list truncation

Keep the [weak-certificate candidate](2026-10-23-immutable-point-score-certificate.md).
Replacing repeated `List.pop()` with `List.shrink()` improves the same-batch
mixed comparison from **29/36 to 32/36**, but full fixed-graph warm decreases
from **11/36 to 10/36**, with three prior pass-to-fail cells. The change is not
adopted or advanced as the retained parent. Neither formal failures nor
individual regressions are excluded. Production remains `a6822c3`.

## Reference-first investigation

Four serial five-second macOS `sample` captures use all 64 measured frozen
real-1536/correlated trial-0 queries, repeated at Akasha ef=256 and the authorized
Qdrant ef=128. Two pairs reverse engine order. All **256 preflight and 256
postflight responses** match expected IDs, F32 bits and available stats.
Intermediate repetitions are not individually audited or independent quality
samples. Their counts include time outside the capture and are not used to
normalize observations.

The analyzer resolves constrained-generic Mojo frames against `nm -n` from
the exact native binary, checking every displayed PC/function-offset pair.
It resolves 59 frames; every thread's exclusive counts sum to its root count.
The table uses each Akasha main thread as its own denominator, not elapsed-time
attribution or a speedup forecast.

| Exclusive observation group | Capture 0 | Capture 1 |
|---|---:|---:|
| Main-thread observations | 3,776 | 3,787 |
| Mapped four-row scoring | 17.32% | 18.25% |
| Mapped single-row scoring | 20.55% | 19.75% |
| Authoritative paired scoring | 8.58% | 8.16% |
| Adjacency gathering | 7.02% | 7.53% |
| Source admission | 6.83% | 6.44% |
| Heap | 6.70% | 7.13% |
| Value certificate | 1.48% | .92% |
| List pop, all element types | 1.43% | 1.58% |

The UInt32 pop specialization accounts for 50/55 observations; the remaining
4/5 pop observations belong to heap items. Qdrant's separate `edge-search-0`
threads have 3,696/3,716 observations. Dense raw scoring accounts for
58.90%/59.74%, appendable raw scoring 7.85%/7.83%, filter partition 5.38%/5.97%
and batched filter checks 3.54%/3.53%. Different inlining, responsibilities and
thread denominators prevent interpreting these as ratios of equivalent work.

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`
[filters, caps, then truncates the candidate vector](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/segment/src/index/hnsw_index/point_scorer.rs).
The installed Mojo **1.0.0 (`ed45d567`)** already provides
[`List.shrink`](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/collections/list.mojo).
Its public API destroys the removed suffix and changes the length while keeping
capacity. UInt32 elements require no payload cleanup. The current documentation
index is 1.1.0, so the experiment uses the versioned source and installed compiler.

The isolated candidate changes exactly one function in `index/hnsw_search.mojo`:
after existing filter compaction and cap, replace the pop loop with
`points.shrink(count)`. The computed count is nonnegative and no greater than
the original length. Filter order, intermediate error behavior, list contents,
scoring, counters, ownership and formats remain unchanged. No private list
fields, uninitialized slots or new buffer abstraction are introduced.

## Validation and complete comparisons

All **135 cases in 19 modules** pass against a frozen 132-file inventory,
including filter/cap/buffer-reuse, cancellation, corrupt adjacency, mapped
lifetime, rerank and certificate tests. The native build and validation source
inventories match. This reuses relevant existing coverage; no new behavior is
invented solely to test the library replacement.

The initial two-order mixed screen retains 12 workers / 3,456 responses.
High-dimensional correlated/independent QPS improves in both orders, roughly
1–2%, while some p95 comparisons regress. That screen justified the complete
comparisons below, not adoption by itself.

| Same-batch version | Mixed quality | Mixed strict | Write + flush | Warm quality | Warm strict |
|---|---:|---:|---:|---:|---:|
| Production | 36/36 | 21/36 | 9/9 | 36/36 | 6/36 |
| Prior weak certificate | 36/36 | 29/36 | 9/9 | 36/36 | 11/36 |
| List shrink | 36/36 | **32/36** | 9/9 | 36/36 | **10/36** |

Mixed gains uniform-128 all trial 2, uniform-1536 correlated trial 0 and
uniform-1536 independent trial 1, with no loss against either control. Four
failures remain: uniform-1536 correlated trial 1 has p95/Qdrant **1.000422**,
and all three real-correlated trials have QPS/Qdrant **.7920–.8700**. The small
p95 miss remains a failure; no tolerance is added.

Warm gains uniform-1536 independent trials 1 and 2 but loses uniform-128
selective trials 0 and 2 and uniform-1536 selective trial 1 against the prior.
There are also four losses against production: all three uniform-128 selective
trials and uniform-1536 selective trial 1. These are seven baseline comparisons
covering four distinct cells, not seven distinct failed workloads.

Three-trial median candidate/prior ratios below are diagnostic summaries;
they do not replace individual strict gates. Higher QPS/lower p95 is better.

| Corpus / mode | Mixed QPS | Mixed p95 | Warm QPS | Warm p95 |
|---|---:|---:|---:|---:|
| uniform-128 all | 1.0040 | .9976 | .9943 | 1.0357 |
| uniform-128 correlated | 1.0257 | .9838 | 1.0251 | .9706 |
| uniform-128 independent | 1.0188 | .9830 | .9810 | 1.0421 |
| uniform-128 selective | .9950 | .9882 | .8547 | 1.3387 |
| uniform-1536 all | 1.0115 | .9858 | .9950 | 1.0073 |
| uniform-1536 correlated | 1.0242 | .9835 | 1.0107 | .9891 |
| uniform-1536 independent | 1.0230 | .9652 | 1.0198 | .9608 |
| uniform-1536 selective | .9986 | 1.0006 | 1.0009 | 1.0213 |
| real-1536 all | .9954 | 1.0173 | .9752 | 1.0235 |
| real-1536 correlated | 1.0103 | .9771 | .9924 | .9846 |
| real-1536 independent | 1.0069 | .9949 | 1.0219 | .9601 |
| real-1536 selective | .9876 | 1.0393 | .9960 | 1.0081 |

Each full comparison uses 36 serial workers and three of four process-order
rotations, not a fully balanced four-trial design. Mixed replays trial-0 graphs;
warm replays each trial's corresponding graph and the full original 12-ef grid.
There is no fresh graph build. Only the previously authorized Qdrant real
correlated ef=128 differs from the original selection; Akasha parameters and
all thresholds remain unchanged. Old ef=96 failures remain archived.

Across screen and both full comparisons, **84 workers / 124,416 measured
responses**, 84 exact reopens and 39 retained Arrow leases pass. Warm also
checks 9,648 exact preflight responses and 5,184 warmups; 144 mixed/screen warmup
returns are not compared. Raw IDs, F32 bits, stats, routes, latencies and every
failed gate remain available. No build, test, compression or other timing worker
overlaps these timed workers.

## Selective GC diagnosis

Because the unchanged selective path again regresses, a separate diagnostic
repeats the complete uniform-128 trial-0 warm driver with both native binaries,
in both process orders. It retains all mode/ef ordering and growing-report
serialization after each cell. Passive Python GC callbacks and two outer query
timestamps are added; GC is neither disabled nor forced. Instrumentation can
perturb timing and allocation, so these are not replacement acceptance results.

All four workers pass **12,288 measured responses, 1,072 exact preflights,
576 warmups and four reopens** against frozen controls. The environment is
Python 3.11.0, GC enabled, thresholds `[700, 10, 10]`. Each worker records 23
collections, 21 inside query intervals. Selective ef=10 has one generation-0
collection at ordinal 24 in every worker:

| Pair / version | Query latency µs | GC interval µs | Selected-cell p95 µs |
|---|---:|---:|---:|
| 0 prior | 143.459 | 108.500 | 47.458 |
| 0 candidate | 143.333 | 106.583 | 38.125 |
| 1 candidate | 134.959 | 103.000 | 37.458 |
| 1 prior | 147.875 | 111.958 | 43.917 |

This common collection explains much of that diagnostic's largest individual
latency. The samples determining p95 have no GC overlap. Candidate/prior
selected-cell QPS is **1.1770/1.0335**, p95 **.8033/.8529**, so this instrumented
full-driver run does not reproduce a stable candidate slowdown either. It does
not establish the cause of the uninstrumented failure, excuse it as noise or
justify excluding GC samples. Every sample remains in its original summary.

A separate read-only check rules out another premature change: all nine frozen
Akasha graph vector sections begin at offset **327,872**, already divisible by
64. Both tested row strides (128/1536 F32) are also divisible by 64. Headers and
source identities are preserved; no alignment rewrite is justified for these
inputs.

## Evidence and next action

Reject this candidate for now and continue from the weak-certificate source.
The next work must distinguish selective native/wrapper phase costs and address
remaining real-correlated mapped scoring; do not assume a shorter source path
or a GC spike proves the required end-to-end improvement. Previously rejected
tail pairs, mapped bounds loops and prefetch probes remain rejected. Broader
integration, external clients, sustained nonresident capacity and full M5/M6
acceptance remain open. Native Linux is deferred by the user, not passed.

The [archive](2026-10-23-immutable-point-list-shrink.json.gz) contains
**596 artifacts / 41,051,396 compressed bytes**, SHA-256
`6917f1886f3d5dc0a102df1c7f360461864e61467b8e179245316f3312ce9ac1`.
It includes complete candidate source/tests, the one-function diff, all timing
reports, native captures/symbols, reference source/licenses, GC events, input
identities and auditors. Candidate native SHA-256 is
`605f6770938e780a8cbd46fb06b73c5b1a0a93769583c8c976aa4405b4479506`;
the retained parent remains
`5ae85379b8948276ac2aba0e0fa1fd86447989c499562cc57fa1411b50c936fc`.
Native binaries and databases are hash-identified rather than embedded.

Extract the archive's `files` text entries and run `audit_archive.py ARCHIVE`.
It verifies every embedded hash and source inventory, then independently
reproduces all seven audit outputs byte-for-byte without an engine or database.
No new Python-suite, crash, C ABI, actual-GPU or platform pass is claimed.
