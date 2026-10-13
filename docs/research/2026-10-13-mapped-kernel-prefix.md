# Mapped bounded SIMD prefix — 2026-10-13

**Unadopted.** Same-batch strict warm speed is **19/36→19/36** with one pass→fail
and one fail→pass cell. Equal totals do not offset the regression. Quality is 36/36
before and after; all IDs, F32 bits, statistics and execution decisions match.
Production remains engine `6d01819`; M5/M6 are unfinished.

The [native samples](2026-10-13-mapped-native-sample.md) located merged hot PCs in
SIMD scoring beside per-chunk bounds/flag calculations. This isolated follow-up
starts from kernel-inline `9aad206d`, changing only `compute/simd.mojo`.
The private synchronous reader computes each source's complete readable SIMD prefix.
The kernel uses the same unaligned loads and arithmetic inside the shared prefix.
If that prefix ends before the original SIMD loop would finish, checked reads run
at the first missing chunk in the original operand order, before finite reduction.
Scalar tails retain checked loads. There is one arithmetic implementation, no
fallback kernel, public raw-pointer API or pointer cache in the general reader.
The immutable operation owner still outlives the pure synchronous kernel.

This preserves a subtle existing distinction: an unavailable later SIMD chunk
precedes an earlier prefix nonfinite error, while an unavailable scalar tail follows
a completed prefix's finite check. New tests cover replaced/shortened mapping,
paired stale owned storage, and prevalidated row-versus-storage faults. They passed
on the parent and candidate. Existing close, zero-length, source reallocation,
readonly/origin, reduction and cosine error tests remain unchanged.

Source/package: `.build/m5-resume/mapped-kernel-prefix`. Native binary SHA-256:
`193a4a2e3179ecae04ae43e88010bf55660477aac050ee46acd18d15ffbc2b89`.
Selected exact-search code is 30,920 bytes, versus the parent's 27,580; prefix setup
and retained failure handling increase total code despite simplifying vector loads.
Validation passes 65 distinct selected Mojo cases in 16 suites, including actual
Metal, full 359 Python tests, and five expected negative compiles. Repeated parent
runs/subcases are not counted as new cases. No new full CPU/C/crash, Linux, capacity
or mixed gate was run for this candidate.

The fixed warm protocol remains 27 serial workers: three rotating production/
candidate/Qdrant triples per corpus, unchanged workload/oracle/ef/timing and strict
Recall@10 ≥ .95 plus QPS ≥ Qdrant **and** p95 ≤ Qdrant. Every trial is retained.
Uniform-128 full-exact QPS ratios against same-batch production are
**.798/.806/.768**; uniform-1536 **1.034/.939/1.031**. No cross-batch subtraction is
used to claim improvement over earlier candidates.

| Transition | Corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---|---:|---|---:|---:|
| Pass→fail | uniform-1536 | 0 | selective | .920 | 1.052 |
| Fail→pass | uniform-128 | 0 | independent | 1.121 | .774 |

The remaining low-dimensional gap is not resolved. Next scale the existing
same-process alternating reader/entry microprobe to 8,192 rows on the frozen
kernel-inline source, to separate mapped versus owned access cost under one process.
That diagnostic cannot substitute for fixed workload or capacity gates. Legacy
live-write rebasing, mixed/concurrent/nonresident work and final integration remain.

[Complete source, tests, raw results and assembly](2026-10-13-mapped-kernel-prefix.json.gz)
contain 3,090 files, 7,053,885 compressed bytes, SHA-256
`a089b54de8c9f023d8c2e4fe2a57a9bc5b0f269bf825701bb83cd29830793a74`. Archive integrity and every embedded file hash were verified.
Binaries and copied databases are excluded and identified by hashes.
