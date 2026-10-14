# Delta scan intervening memory context

A controlled memory-access probe reproduces the opposing unfiltered/filtered
directions observed in the [native source phases](2026-10-14-delta-native-phases.md).
For 1536D unfiltered scans, four-row scoring is 11.0% faster with no intervening
buffer read, but 44.3% and 115.1% slower after reading over 32 and 64 MiB. Filtered
scans remain faster. All three trials retain each of these directions.

This extends the existing [complete synthetic scan](2026-10-14-owned-four-geometry.md),
using the unchanged frozen four-row source and exact extracted serial method.
Fixtures use cosine, 128/1536 dimensions, 819 current physical rows, actual
source admission and every-fourth-row filtered admission. Seventeen prepared
queries match in IDs, Float32 score bits and all 19 statistics: **68 preflight
pairs**. All **816 timed result pairs** also have identical aggregates.

Before each timed scan, a no-inline helper reads one UInt64 every 128 bytes over
0/8/32/64 MiB of separate storage. It mutates one word and consumes the sum.
Those accesses are outside the scan interval. Each query alternates the two
variants across three trials; output is buffered until all 408 scans for that
mode finish. Timings include admission, heap, statistics, result creation and
destruction, but exclude base search, candidate merge, rerank, Python and writes.
No production policy, plan, ef or metric implementation changes.

| 1536D, 819 physical rows | Intervening MiB | Serial mean µs | Four-row mean µs | Four / serial |
| --- | ---: | ---: | ---: | ---: |
| Unfiltered | 0 | 78.412 | 69.784 | .8900 |
| Unfiltered | 8 | 80.804 | 72.294 | .8947 |
| Unfiltered | 32 | 78.373 | 113.078 | 1.4428 |
| Unfiltered | 64 | 83.686 | 180.039 | 2.1514 |
| Every fourth row eligible | 0 | 35.725 | 28.824 | .8068 |
| Every fourth row eligible | 8 | 36.725 | 29.706 | .8089 |
| Every fourth row eligible | 32 | 54.824 | 38.804 | .7078 |
| Every fourth row eligible | 64 | 79.118 | 51.941 | .6565 |

At 128D, unfiltered scans regress 8.5–11.8% across all four contexts; filtered
scans improve 4.6–18.8%. All **1,632 individual observations** remain in the
archive, including every regression. The compiled harness completes successfully
with Mojo 1.0.0, metal:4/apple-m4 (5.05 s compile, 3.17 s run).

The intervention demonstrates memory-context sensitivity in this harness. It
does not measure cache misses, guarantee eviction, reproduce the exact native
memory state or establish a hardware bandwidth cause. The 1 µs clock resolution,
synthetic vectors, resident physical pages, fixed context ordering and absence
of historical delta rows limit generalization. Native phase and uninstrumented
acceptance evidence remain separate.

The result supports the subsequent [filtered-only candidate](2026-10-14-delta-filtered-four.md):
apply four-row scoring only to filtered F32 delta scans, retaining the original
serial loop for unfiltered and compact-scalar scans. No cache-size threshold or
user-facing configuration follows from this probe. That candidate passes its
semantic and durability checks but remains unadopted after native warm failures.

The [archive](2026-10-14-delta-memory-context.json.gz) contains **133 files,
287,364 bytes**, full frozen sources, runnable harness, raw observations,
semantic checks and identities. Every embedded hash is verified.

- Harness binary SHA-256: `e4f9a1d6aac6c45f4ffd5f985ffb725cb24bbed8df209a7f7db1418797bc6e3a`.
- Archive SHA-256: `c87a2828873166ed56be51e6ce7f0e6534d2132ea3c6330def2a08720b5dfa8f`.

Production engine and Python/C binaries remain unchanged. No native acceptance,
Linux, capacity, HTTP or GPU gate closes; M5/M6 remain incomplete.
