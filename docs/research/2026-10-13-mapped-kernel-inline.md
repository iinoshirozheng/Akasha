# Mapped kernel factory inlining — 2026-10-13

This follow-up remains **unadopted**. Same-batch strict warm speed is **20/36→19/36**,
with two pass→fail and one fail→pass cells. Quality is 36/36 before and after; all
paired IDs, F32 bits, traversal statistics and execution decisions match. M5/M6
remain incomplete and production engine `6d01819` is unchanged.

The candidate adds only seven `always_inline` annotations to the complete frozen
[kernel snapshot](2026-10-13-mapped-reader-followups.md) source. No storage, validation,
error-order, arithmetic, oracle, ef, timing or public API change accompanies them.
Source/package: `.build/m5-resume/mapped-kernel-inline`. Native Python SHA-256:
`9aad206d8600cb2bccb45ea761765b6342c1e1c3082e448cb0a579fd9f9d6a8a`.

The small earlier entry microbenchmark did not establish a gain from these hints.
The actual collection caller does change: all four direct `_dense_reader` calls are
eliminated. Selected exact-search machine code grows from 23,776 to 27,580 bytes;
seven `field_ordinal` calls remain, including calls previously nested inside reader
construction. This motivates the workload comparison and is not itself a speed gate.

Validation passed: 61 distinct Mojo cases across 14 relevant suites, including the
actual Metal regression; full 359 Python tests; five expected negative compiles,
including kernel pointer origin escape. The package and child compiler wrapper use
the same isolated source identified by the build. These are not a full CPU/C/crash
run or a new Linux/capacity/mixed validation.

The fixed Mac warm batch uses 27 serial workers, three rotating production/candidate/
Qdrant triples per corpus. Strict per-cell quality and simultaneous QPS/p95 rules are
unchanged. No trial is excluded. Uniform-128 full-exact QPS ratios against production
are **.823/.827/.833**; uniform-1536 **.967/.979/.972**. Do not subtract pass counts
or latencies from the earlier independent snapshot or Variant batches.

| Pass→fail corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---:|---|---:|---:|
| uniform-128 | 0 | selective | 0.746 | 1.533 |
| real-1536 | 1 | selective | 0.908 | 0.975 |

The single fail→pass is real-1536 trial 0 `all` (QPS ratio 1.014, p95 ratio .930).
It does not offset either regression. All 36 cells and raw warmups remain archived.

Next, remove the repeated default-field lookup in exact collection scanning by using
the already located field through existing accessors. Preserve missing-field skips,
pair order and errors; retain fixed workload checks. Legacy live-write rebasing,
mixed/concurrent and sustained nonresident comparisons, native Linux performance and
final integration remain open. The earlier mapped-owner capacity diagnostics do not
stand in for validation of this candidate.

[Complete sources, tests, commands, raw results and disassembly](2026-10-13-mapped-kernel-inline.json.gz)
contain 2,596 files and 6,226,539 compressed bytes, SHA-256
`3501f801d81ded68349037c8e54db6409513d7dac6d036218c3e24dbfc75ea9c`. Archive integrity and every embedded hash were verified.
Binaries and copied databases are excluded and identified by hashes.
