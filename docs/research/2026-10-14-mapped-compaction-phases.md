# Mapped compaction phase localization — 2026-10-14

The fixed mixed workload spends substantial time in live compaction while the
writer lock is held. Across three instrumented workers, persisted output
mapping/CRC/decode takes a median **6.087 ms at 128 dimensions** and
**13.467–13.539 ms at 1,536 dimensions**. The complete measured publication
interval is 10.262–17.733 ms. Move output preparation outside writer exclusion
next, while keeping current-version checks and manifest publication protected.
This is diagnostic evidence, not an accepted performance improvement.

The earlier read-base hypothesis does not explain this fixed mixed result.
Each worker records only two full base builds, at sequences 9,216 and 9,472:
the initial retained Arrow export and the final exact check after reopening.
There is no full base build at an intermediate accepted sequence. The fixed
query path therefore does not repeatedly rebuild the snapshot base after each
compaction in these traces. The flush-run change remains separately validated
for snapshot callers, but its mixed gate still failed.

| Corpus | Compactions | Decode median ms | Stage median ms | Publication median ms | Exchange median ms | Total median ms |
|---|---:|---:|---:|---:|---:|---:|
| uniform-128 | 11 | 6.087 | 2.169 | 0.291 | 1.636 | 10.262 |
| uniform-1536 | 11 | 13.539 | 2.272 | 0.370 | 1.602 | 17.657 |
| real-1536 | 11 | 13.467 | 2.213 | 0.380 | 1.588 | 17.733 |

Decode includes mapping and persisted validation. Stage checks current rows and
prepares replacement owners. Publication includes the interval after staging
through the manifest operation, so it may include intervening cleanup. Exchange
updates the live MemTable while retaining previous owners. Detach is 0–.001 ms
in these traces. Median components need not sum to median total. Timings exclude
writer-lock acquisition, the earlier compaction build and later reclamation;
they do not decompose total query latency or every possible destructor cost.

The diagnostic copies frozen flush-runs `d0845b87`, adding timestamps and one
composed print after each traced operation. Three serial parent/diagnostic pairs
run the unchanged mixed corpora and plans, alternating pair order. All **864
paired timed queries** have identical IDs, Float32 bits, traversal statistics
and execution choices; retained Arrow leases and final reopen oracles pass.
There are 33 compaction traces and six base traces. Instrumentation and printing
perturb scheduling, so this binary's throughput is not an acceptance result.
No new full correctness suite, crash/C ABI, capacity or native Linux gate is
claimed. Two harmless unused-initial-value compiler warnings are retained.

Diagnostic directory: `.build/m5-resume/mapped-compaction-phases`.
Binary SHA-256:
`895eabc68b698b77320af53dfa3fb786dca348ab0f7ce2bc2743f9c073372382`.
Production engine `6d01819` is unchanged; M5/M6 are unfinished.

Next prepare and retain checked immutable output owners during the existing
unlocked build phase. Under the writer lock, verify current versions against the
capture and publish the prepared owners only if disk publication succeeds.
Preserve error/cancel/conflict cleanup, exact-file leases and outside-lock
retirement. Test the preparation/publication boundary before another fixed gate.
Typed live compaction and warm/capacity gaps remain open.

[Complete source, raw traces, control reports and summaries](2026-10-14-mapped-compaction-phases.json.gz)
contain 344 files, 16,186,020 compressed bytes, SHA-256
`8876e19703b508774f5e97346076a3ef90706d6f19d6d6a15df6c9589353228e`.
Archive integrity and every embedded hash were verified; binaries and copied
databases are excluded and identified by hashes. No trace or slow sample was
removed.
