# Mixed query tails: maintenance capture and publication contention

The F32 codec change remains in production. Fixed-state queries do not reproduce
the earlier real selective 1.590x p95 regression. Evolving-state controls and
native thread intervals instead identify maintenance's writer-lock sections as
a major source of waiting: 56 of 57 selective requests above 150 microseconds
with calling-thread CPU below 80% overlap capture or publication holding that
lock. One request remains unexplained. This is diagnostic evidence, not a new
Qdrant speed, capacity, lifecycle or concurrency acceptance result.

## Scope and controls

Compare `d073cec` with `ad21da3` on macOS 26.5.2 ARM64 / Apple M4 Pro, Mojo
1.0.0 (`ed45d567`) and Python 3.11.0. The only production-source difference is
the [F32 point codec specialization](2026-10-16-point-codec-tapes.md).
`python/akashadb/_kernel.so` remains SHA-256
`5caff7a35db0edca7b9ad94f919a5c892b4a3c0eb828d5ac1546ca5363f69d78`.
The original before library is
`8ac64e14a7ddd3a0ba895de95b0c6588b1b8891e3c84dbc618608ea11cc38d5d`.
All source snapshots, build identities and failed attempts are archived.

Each corpus uses the existing closed Akasha baseline, fixed ef, 32 blocks of
nine requests, the same Python request/response adapters and three warmups.
Versions alternate order across three trials. Workers run serially, with no
build, test or compression jobs alongside timed measurements.

1. **Fixed state:** remove writes/flushes and recompute exact oracles against
   the initial database, including its preexisting replacements and deletes.
   Query vectors, filters, order and ef remain unchanged. The original first
   block's oracles must match. Both original production libraries are used.
2. **Drain control:** retain all original updates, flushes and evolving-state
   oracles. Isolated source snapshots expose the existing native
   `wait_for_maintenance()` only for this experiment. Compare normal interleaving
   with a drain before warmup and after each flush, outside query timing.
   Both conditions use the same instrumented library for each version. Draining
   also changes maintenance scheduling and cache state; it is an intervention,
   not an equivalent production workload or an accepted optimization.
3. **Native intervals:** repeat the drain controls with background thread IDs
   and capture/build/publication intervals. Each record is one complete append
   via `FileHandle.write_once`; short writes fail the diagnostic. Capture and
   publication logs are emitted after releasing the writer lock. Point preflight
   and output spans are nested within build and must not be added to its total.
   Logging can affect subsequent scheduling, so these times do not replace
   uninstrumented results.

Mojo's default clock did not admit a constant offset interval across the first
worker's before/after calibration. That run is excluded. The retained probe uses
Darwin `CLOCK_UPTIME_RAW` through the SDK-declared `clock_gettime_nsec_np`, matching
Python's uptime clock. All 36 retained workers' 50 calibration samples bracket
an offset of exactly zero. Native thread IDs differ from the foreground ID.
The [Mojo clock documentation](https://mojolang.org/docs/std/time/time/perf_counter_ns/)
leaves its reference point unspecified; cross-runtime alignment was verified
instead of assumed. The
[file API](https://mojolang.org/docs/std/io/file/FileHandle/)
documents the single-call write used for complete records.

## Paired query timing

Values below are medians of the three **after / before** p95 ratios. The full
12 corpus/mode cells, every trial and QPS ratios are in the archive.

| Corpus / mode | Original mixed | Fixed state | Interleaved, drain binding | Drained | Interleaved, thread trace | Drained, thread trace |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Uniform-1536 selective | 1.205 | 1.050 | 1.347 | 1.022 | 1.019 | 1.011 |
| Real-1536 independent | 1.106 | 1.004 | 1.165 | 0.971 | 0.999 | 1.009 |
| Real-1536 selective | 1.590 | 0.979 | 1.066 | 0.944 | 1.126 | 0.980 |

Across all fixed-state cells, median QPS ratios range from 0.982 to 1.016 and
p95 ratios from 0.950 to 1.061. This narrows the hypothesis but does not establish
identical query performance: trial variation remains, particularly uniform-1536.
The drain-binding interleaved p95 range is 0.815–1.347, versus 0.932–1.022 when
drained. The traced drained range is 0.980–1.021. Neither favorable repeats nor
the drain condition erase earlier failures or satisfy the formal speed gates.

## Which background intervals overlap waiting?

The 150-microsecond threshold is the earlier tail probe's diagnostic threshold,
not an acceptance gate. Adding CPU fraction below 80% separates substantial
waiting from high-dimensional requests that normally consume this much CPU.
CPU timing encloses two additional clock calls, so ratios slightly above 1 are
retained rather than clipped. Overlap counts below are across three interleaved
trials, with 216 selective queries per row.

| Corpus / version | Slow, low-CPU requests | Capture lock overlap | Publish lock overlap | Neither |
| --- | ---: | ---: | ---: | ---: |
| Uniform-128 before | 13 | 7 | 6 | 0 |
| Uniform-128 after | 9 | 5 | 4 | 0 |
| Uniform-1536 before | 8 | 7 | 0 | 1 |
| Uniform-1536 after | 11 | 8 | 3 | 0 |
| Real-1536 before | 6 | 6 | 0 | 0 |
| Real-1536 after | 10 | 8 | 2 | 0 |
| **Total** | **57** | **41** | **15** | **1** |

For example, one real-1536 after request takes 2.462 ms, spends 14% of that time
on the calling thread and overlaps 2.225 ms of capture holding the writer lock.
The unexplained uniform-1536 before request takes 647 microseconds with 28% CPU;
it overlaps build/output but neither recorded writer-lock section. Build overlap
alone does not identify scheduler, I/O or memory contention.

No drained query overlaps any recorded background span. Low-dimensional drained
runs have no selective request above 150 microseconds. High-dimensional drained
runs still have such requests, with median CPU fractions near 1; waiting is not
the entire remaining query-speed gap.

Source inspection supplies the mechanism: `search_dot_approx` and
`search_dot_approx_where` acquire the same writer lock as background capture and
publication. Capture calls `begin_compaction`, which reads/validates the manifest
and catalog and pins input files through `GenerationPinRegistry` /
`ManifestFileLease`. Publication rebases and durably publishes the manifest under
that lock. The request's exact lock-acquisition duration was not separately
instrumented, so overlap plus source agreement is strong contention evidence,
not a direct measurement of every request's lock wait.

The faster codec also changes maintenance frequency in these traces:
uniform-1536 runs go from 7 builds each to 11/10/10, and real-1536 from 7 each to
9 each. Median total background build time falls from 1,671 to 1,043 ms and
1,689 to 894 ms respectively, while total publication lock time rises from
2.50 to 4.05 ms and 2.51 to 3.31 ms. Faster jobs can expose more capture/publication
opportunities within the same update stream. This observed scheduling difference
does not assign an exact causal share of the original 1.590x regression.

## Validation and next implementation boundary

All 25,920 requests pass independent live-ID, duplicate, filter, oracle and recall
audits. Before/after responses preserve IDs, F32 score bits and search statistics;
both evolving-state controls also match the original uninstrumented reports.
All 90 exact reopens and 90 retained Arrow-lease checks pass. Minimum mode-mean
recall is 0.95972 in fixed state and 0.95694 in both evolving-state experiments.

Three initial trace build failures (indentation, module-docstring position and a
conflicting raw-write FFI signature), the rejected clock run, and two analysis
failures (missing import path and zero-duration intervals) remain in the archive.
The retained trace uses the existing file API and preserves zero-duration spans.
No production source or public API changes were made, so the preceding relevant
Mojo/Python/C/Linux validation remains applicable; those suites were not repeated.

Next separate manifest/catalog work from file-lease acquisition inside capture,
then shorten proven expensive work while preserving generation validation and
file ownership. Do not remove the writer lock or leases: approximate queries
also mutate shared search scratch, and snapshots must survive close/reopen and
file retirement. Publication's durable state transitions need their existing
crash/recovery checks for any change.

The pinned Qdrant
[merge planner](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimizers/merge_optimizer.rs)
sorts segments by size and plans bounded batches. Akasha currently triggers at
four level-zero segments and merges the entire captured manifest, including the
base. Reducing repeated full-base work is another source-backed implementation
candidate, requiring preserved tombstones and sequence authority for any partial
merge. This experiment does not choose or validate that new compaction design.

All outstanding formal speed, 128 MiB pressure, full type/lifecycle, concurrent
client and native Linux gates remain open.

[Evidence archive](results/2026-10-16-codec-query-control.json.gz): 441 text
artifacts, 27,695,056 bytes, SHA-256
`688dfb8dc4046d658b799839703787c593dd377498b4ef124bee640a9f279fe6`.
Every embedded file's hash is verified after decompression. Original and
fixed-state plans, raw query records, thread spans, sources and all failures are
included. Native libraries are identified by hash and retained locally.
