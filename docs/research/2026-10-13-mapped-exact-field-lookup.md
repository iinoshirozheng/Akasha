# Mapped exact default-field lookup — 2026-10-13

**Unadopted.** Same-batch strict warm speed is **22/36→19/36**, with four pass→fail
and one fail→pass cells. Quality passes 36/36 before and after; IDs, F32 score bits,
statistics and execution decisions match. M5/M6 remain incomplete; production
engine `6d01819` and its library remain unchanged.

Starting from the frozen [kernel-inline candidate](2026-10-13-mapped-kernel-inline.md),
this changes only `PersistentCollection._search_candidates`. Instead of checking
`has_dense()` and then searching for the same field again in `_dense_reader()`, the
loop locates field 0 once and reads it through existing `vector_at`/`value` accessors.
It adds no helper, cache, configuration or public API. Missing-default skips,
pair consumption/order, validation and arithmetic remain unchanged.

The complete source/package is `.build/m5-resume/mapped-exact-field-lookup`; its
native binary SHA-256 is
`b3fb3502114bdb8e305849a40f4aefd3b27fadd59027cd48a213cccd24cc81cb`.
Selected exact code is 27,724 bytes. Field lookup calls fall from seven to three,
with no emitted `vector_at` or `_dense_reader` calls. This establishes the intended
machine-code change, not an end-to-end improvement.

Validation passes 62 distinct selected Mojo cases in 15 suites, including the
actual-device mapped Metal case; full 359 Python tests; and five expected compile
rejections. A new test mixes default and named-only points, asserts explicit IDs
and scores for full/gather/empty selections, and checks zero public List cache
materialization. It passes before and after the change; repeated runs are counted
once. All child compiler commands and source identities are retained. This is not
a full CPU/C/crash run or a new capacity, mixed or Linux validation.

The unchanged warm protocol uses 27 serial workers, three rotating production/
candidate/Qdrant triples per corpus. Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant
are required together per cell. No exclusions, retuning, offsets or cross-batch
subtraction are used. Full-exact QPS ratios against same-batch production are
**.770/.811/.794** for uniform-128 and **.970/.986/.954** for uniform-1536.

| Pass→fail corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---:|---|---:|---:|
| uniform-1536 | 2 | selective | 0.889 | 1.157 |
| real-1536 | 0 | selective | 0.884 | 1.125 |
| real-1536 | 1 | selective | 0.861 | 1.151 |
| real-1536 | 2 | selective | 0.886 | 1.153 |

Uniform-128 trial 1 selective is the sole fail→pass (QPS 1.334, p95 .721); it does
not offset the failures. All cells and warmups are retained.

Next inspect query-level metric/width dispatch on the kernel-inline parent. Its
stored assembly still loads the runtime metric inside scoring (e.g. `1c8ed0`–
`1c8edc`) and branches on dimension at `1c8ee0`; moving those selections to query
entry is a measurable hypothesis, not a demonstrated speedup. Do not build further
on this lookup change merely because it removes calls. Legacy rebasing,
mixed/concurrent/nonresident gates and final integration remain unfinished.

[Complete source, tests, raw trials and disassembly](2026-10-13-mapped-exact-field-lookup.json.gz)
contain 2,919 files, 6,770,229 compressed bytes, SHA-256
`2cf3876e47ad454897f66b6a7664eb66710bc800a1abdc008e248bbda547d4ee`. Archive integrity and every embedded file hash were verified.
Binaries and copied databases are excluded and identified by hashes.
