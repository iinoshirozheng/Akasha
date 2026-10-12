# Mapped exact query dispatch — 2026-10-13

**Unadopted.** Same-batch strict warm speed is **24/36→20/36**, with five pass→fail
and one fail→pass cells. Quality is 36/36 before and after. All paired IDs, F32 bits,
statistics and execution decisions match. M5/M6 remain unfinished; production engine
`6d01819` is unchanged.

This starts from [kernel-inline](2026-10-13-mapped-kernel-inline.md), not the subsequent
field-lookup experiment. Its assembly still reloads the metric and selects SIMD width
inside row scoring. The isolated change dispatches metric/width once at query entry,
then invokes the same checked single/pair kernels from a private `no_inline` exact
loop specialization. The old loop is moved, not retained as an alternative. No
storage/schema/API/configuration, ef, ordering, arithmetic or timing change is added.

Full isolated source/package: `.build/m5-resume/mapped-query-dispatch`. Native SHA-256:
`a0e4f06d688aef58dcb525309f75894b3bf351e71ee5412a3fd40afbde463e54`.
All six emitted scan specializations are captured in disassembly: 56,944 bytes total,
9,120–10,156 bytes each. The small entry wrapper is inlined into callers and has no
separate symbol; those caller bytes are not counted. This is a larger total code
footprint than the 27,580-byte parent, with one specialization used per query.

Validation passes 62 selected Mojo cases, including actual Metal, full 359 Python
tests, and five expected negative compiles. The mapped exact test now covers
3/16/17/63/64/65/128/1536 dimensions for all metrics and full/gather selections,
checking F32 bits against the unchanged runtime-dispatch scoring function as well
as the owned collection result. Boundary/repeated subcases do not inflate the case
count. Missing-default, finite/error-order and source-lifetime regressions remain.
This is not a full CPU/C/crash or new capacity/mixed/Linux validation.

The fixed Mac warm protocol is unchanged: 27 serial workers, three rotating
production/candidate/Qdrant triples per corpus. Each cell requires Recall@10 ≥ .95
and QPS ≥ Qdrant **and** p95 ≤ Qdrant. All trials are retained without tolerance,
retuning, offsets or cross-batch subtraction. Full-exact QPS ratios against the
same-batch production are **.780/.745/.785** (uniform-128) and **.926/.956/.916**
(uniform-1536). Specialization does not resolve the mapped warm regression.

| Pass→fail corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---:|---|---:|---:|
| uniform-128 | 1 | selective | 0.862 | 1.204 |
| uniform-1536 | 1 | selective | 0.881 | 1.208 |
| uniform-1536 | 2 | selective | 0.767 | 1.435 |
| real-1536 | 1 | selective | 0.920 | 1.119 |
| real-1536 | 2 | all | 0.985 | 1.041 |

The sole fail→pass is real-1536 trial 0 all (QPS 1.064, p95 .923); it cannot offset
the regressions. All warmups and per-query results are retained.

Next collect native execution samples on the production and frozen kernel-inline
full-exact path to locate remaining runtime cost. The reader representation, factory
annotations, repeated field lookup and dispatch hypotheses now have concrete limited
results; do not repeat them unchanged or infer whole-query gains from code size.
Legacy live-write rebasing, mixed/concurrent/nonresident gates, native Linux
performance and final integration remain open.

[Complete source, tests, commands, raw trials and disassembly](2026-10-13-mapped-query-dispatch.json.gz)
contain 2,771 files and 6,605,475 compressed bytes, SHA-256
`a57b1ad8b81426d7e4dd3b414e0d56b234ca0d5a557b040d6caaad33df46b01d`. Archive integrity and all embedded file hashes were verified.
Binaries and copied databases are excluded and identified by hashes.
