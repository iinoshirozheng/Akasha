# Native mixed delta source phases

The original real-1536 mixed workflow localizes the four-row candidate's
unfiltered scan regression to **delta search plus its candidate merge**. In
three pairs this interval increases 28.3%, 45.3% and 38.0%; base search/merge
and authoritative rerank vary much less. Filtered delta scan intervals improve
10.3–20.2% in the same runs. This is diagnostic evidence, not acceptance of the
rejected [four-row candidate](2026-10-14-delta-four-scores.md).

Both frozen sources—row-CRC and four-row—receive identical instrumentation in
`segmented_hnsw.mojo`: six clock reads, an eight-lane Int64 timestamp field
(six lanes used), and one print after rerank. No output occurs between source
phases. The phase boundaries are prepare, base search/merge, delta search/merge,
collector tail and rerank. Removing these additions and restoring the wrapped
return reproduces every nonblank parent source line; all other Mojo source
hashes match the respective frozen parents. The observed clock granularity is
1 µs, so tiny collector-tail intervals cannot support fine-grained conclusions.

Each instrumented version passes the existing **18 segmented HNSW cases** and
builds with Mojo 1.0.0, metal:4/apple-m4. Six serial workers run three alternating
pairs on fresh database copies with the exact original real-1536 mixed plan:
Akasha ef32/32/64/32 for all/correlated/independent/selective. No ef, filter,
work schedule, source-selection policy or oracle changes.

All **1,728 queries** match the corresponding uninstrumented trial in result
IDs, Float32 score bits, statistics and execution decisions. Every worker passes
the original oracle validator, retained-lease check and exact reopen check.
There are **1,296 measured ANN phase records**, 18 separate warmup records and
432 planned-exact queries without segmented phases. Across the two versions,
all 648 ANN pairs also match delta physical/live geometry, path and all four
recorded source work counters. Every timestamp sequence is monotonic and its
five intervals sum exactly to the recorded search interval.

| Original first 59 all-query scans, mean µs | Pair 0 serial → four | Pair 1 serial → four | Pair 2 serial → four |
| --- | ---: | ---: | ---: |
| Base search + merge | 285.610 → 279.492 | 276.627 → 289.949 | 277.068 → 279.712 |
| Delta search + merge | 118.780 → 152.339 | 112.237 → 163.034 | 111.220 → 153.508 |
| Authoritative rerank | 51.136 → 49.610 | 48.508 → 51.169 | 48.441 → 49.847 |
| Total segmented interval | 461.458 → 487.322 | 443.017 → 509.983 | 442.407 → 488.814 |

Delta time increases in **54/59, 57/59 and 57/59** paired scan observations.
For the final 13 all-query graph searches, delta mean ratios are .9734, 1.0469
and .9995. The filtered scan cohorts improve in all six comparisons: correlated
ratios .8214/.8882/.8418 and independent .7983/.8965/.8329. Correlated has 59
scan queries then 13 graph queries; independent has 58 then 14. The complete
archive retains every query, including all graph observations and outliers.

This narrows the discrepancy with the
[resident synthetic kernel/full-scan evidence](2026-10-14-owned-four-geometry.md).
It does not distinguish distance loads/arithmetic, admission, heap, candidate
merge or their cache interactions within the delta interval. It also does not
establish an instruction-layout, cache-miss or bandwidth cause. The timestamps,
added object storage and final print can change compilation and scheduling;
these numbers must not replace uninstrumented acceptance measurements.

Two harness errors are preserved. The initial six-lane SIMD timestamp storage
was rejected by the compiler and corrected to eight lanes before any build or
measurement succeeded. The first measurement parser expected graph label
`f32`; the actual internal label is `packed-f32`, while the public label is
`segmented-f32`. Its worker had succeeded and passed all result/stat comparisons.
The parser was corrected and that raw sample reused, with the interruption
between pair 0 workers disclosed. Pairs 1 and 2 ran uninterrupted and retain
the same unfiltered delta regression. No successful sample was discarded.

Diagnostic Python binary SHA-256:

- Serial parent instrumentation: `1ea3a8ded92f00c7eabb405c9bdb7bdbd0518d7c8a8ae7fdb9c7d185dbfde086`.
- Four-row instrumentation: `0128bf430b43416ce50b571b81804a7f5bffd238747252b0512b679b58e7a3c0`.

The [archive](2026-10-14-delta-native-phases.json.gz) contains **337 files,
1,411,688 bytes**, full isolated sources, runnable instrumentation/build/analysis
drivers, failed attempts, raw timestamps, worker reports and source/binary
identities. All embedded hashes and referenced parent/plan archives are verified.
Archive SHA-256:
`f0229ba23792597732848f374cedce7a1bee212c8eda8df1a4d174ed3fdb4296`.

Production engine and Python/C binaries remain unchanged. Existing full CPU,
Python, crash and C tests are not claimed as new diagnostic results. No Qdrant,
native Linux, capacity, HTTP or GPU acceptance gate closes; M5/M6 remain
incomplete. Next test whether the resident synthetic benefit survives a larger
intervening memory working set before choosing another production candidate.
