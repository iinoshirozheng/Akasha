# Low-dimensional mixed-query tail localization after cache mapping

The short capacity fix remains retained. Two isolated follow-up probes do not
reproduce its original selective p95 ratio as a stable causal effect, but they
do **not** replace the [uninstrumented result](2026-10-16-cache-map.md) or clear
any Qdrant speed gate. Production source and both measured binaries are unchanged.

## Method

Both probes use uniform-128's frozen 32-block mixed plan, three alternating
before/after pairs, the exact same before/after libraries from `ae2fc7e`'s
cache-map evidence, fresh cloned databases and normal GC settings. Each probe
runs six workers and 1,728 queries. No builds, other benchmarks or compression
run concurrently. Query IDs/F32 bits/statistics and execution choices agree
across all pairs, with all 12 reopen checks and 12 retained Arrow leases passing
across the two probes.

The first probe installs a Python `gc.callbacks` observer and records each
query's existing `perf_counter_ns` interval. The second also samples
`time.thread_time_ns` immediately outside that wall interval. Callback allocation
and the extra clock calls perturb execution: these are diagnostic observations,
not new acceptance measurements. No GC disable, forced collection, threshold,
planner, ef or production-code change is made. The frozen plans are embedded in
the preceding cache-map archive; binary and script hashes are in this archive.

## Observations

- No measured query in either probe overlaps a GC event (0/3,456), including
  all 864 selective queries. These observed spikes are not explained by GC.
- The GC-only probe has 19 selective queries above 150,000 ns; 12 are the first
  query after a write/flush block. The CPU-timed probe has 23 such queries, 11
  first in a block. First-after-write behavior does not explain every spike.
- In all 23 CPU-timed selective queries above 150,000 ns, calling-thread CPU
  time is only 22.5–67.1% of wall time (median 37.8%). This is evidence for
  substantial time not executing on that thread, rather than that entire
  wall interval being distance-computation CPU work. It does not identify a
  particular scheduler event, kernel wait, page fault or lock. System-level
  tracing would be needed for that attribution.
- These are planned exact/selectivity queries using the portable SIMD backend.
  The current `_search_candidates` implementation loops synchronously over
  admitted rows; the observations are not a measurement of a parallel HNSW
  worker pool. CPU observations still include clock overhead and the calling
  process is not isolated from all host activity.

The original uninstrumented selective p95 median after/before ratio is 1.9296.
It is 1.0032 in the GC-only diagnostic and 0.9507 in the thread-CPU diagnostic.
Both diagnostics retain trials in each direction: GC-only ratios are 1.0032,
1.3947 and 0.7953; CPU-timed ratios are 0.5623, 1.0617 and 0.9507. This variation
and the measured non-CPU time prevent assigning the original tail change solely
to the cache reader. No favorable repetition is substituted into acceptance.
The correlated and other outstanding QPS/p95 requirements remain open.

## Evidence

[Archive](results/2026-10-16-cache-tail-trace.json.gz): 63 files,
559,589 bytes. SHA-256: `b46c733b256fc98316853b309fd0799de397f58e2d46a3403c00b0801e6eeda4`.
It retains both instrumented harnesses, job/run records, all responses and GC
markers, per-query CPU/wall observations, binary/script identities and the
complete derived analysis. All embedded text hashes verify. No production
change follows from this diagnostic alone.
