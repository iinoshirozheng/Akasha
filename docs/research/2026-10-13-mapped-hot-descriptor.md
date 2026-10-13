# Mapped hot descriptor and scaled entry controls — 2026-10-13

**Unadopted.** Strict same-batch warm speed is **22/36→17/36**, with six
pass→fail cells and one fail→pass. Quality is 36/36 before and after; all IDs,
F32 score bits, statistics and execution decisions match. Production remains
engine `6d01819`; M5/M6 are unfinished.

The isolated candidate starts from kernel-inline `9aad206d`. Two engine files
move the mapped file Arc and byte offset from the shared lazy-cache state into
its descriptor. The hot NumericValues reader uses its existing scalar count.
Clones retain both the exact file owner and the shared cache. Construction range
checks, the non-raising public List getter, stable-pointer lock publication and
live-source reader checks remain. There is no format or public API change.

Compiler-measured descriptor/state sizes change from 8/72 to 24/56 bytes;
NumericStorage, NumericValues and VectorValue remain 32/48/64 bytes. These sizes
are not an allocator or RSS measurement. The exact-search selected code totals
27,636 bytes, versus the parent's 27,580.

Before this change, the existing same-process entry probe was expanded to 8,192
rows, 64 repetitions and four alternating trials for each of 128/1536 dimensions.
On the frozen parent, mapped entry time is 4.5–6.0% above current owned entry at
128 dimensions and 1.0–1.7% above at 1536. An additional control copies the
unchanged production List checked-kernel body, reached through the current owned
entry getter. Its current-owned overhead is 3.6–5.3% at 128 dimensions; the mapped
entry adds 4.1–7.8% over current-owned in that run. This is not the production
representation/call layout and does not decompose whole-query cost causally.
All control score sums and behavior assertions pass.

With the proposed descriptor, the same legacy-body control shows mapped entry
13.2–16.3% above current-owned at 128 dimensions; 1536 varies from 1.1% below to
1.0% above. No absolute timing subtraction across separate processes is used.
The mechanism evidence did not establish an improvement, and the full warm
comparison independently rejects adoption.

Candidate source/package: `.build/m5-resume/mapped-hot-descriptor`; binary SHA-256
`b3c8c0777257f4a7a2b5b3979f90547db408f838a441bc4596d0da71aafe39e5`.
Validation passes 100 distinct Mojo cases in 22 suites, full 359 Python tests and
five expected negative compiles. This includes concurrent first materialization,
retained row/clone lifetime, old snapshots across replacement writer/compaction,
file retirement, Arrow borrowing and actual Metal. The compaction test retains
the previously documented mapped-owner lifetime expectation; it is not an
unchanged production-suite claim. No fresh C/crash, Linux, capacity or mixed gate
was run for this layout. Earlier owner results do not certify this binary.

The warm protocol remains 27 serial workers: three rotating production/candidate/
Qdrant triples per corpus, fixed workload/oracle/ef/timing, Recall@10 ≥ .95,
QPS ≥ Qdrant **and** p95 ≤ Qdrant. All trials are retained. Full-exact QPS ratios
against same-batch production are .835/.807/.810 for uniform-128 and
.969/.959/.953 for uniform-1536. Earlier batches are not used as a baseline.

| Transition | Corpus | Trial | Mode | QPS after/before | p95 after/before |
|---|---|---:|---|---:|---:|
| Pass→fail | uniform-128 | 0 | selective | 0.654 | 1.553 |
| Pass→fail | uniform-128 | 2 | selective | 0.823 | 1.644 |
| Pass→fail | uniform-1536 | 0 | selective | 0.944 | 1.051 |
| Pass→fail | real-1536 | 0 | all | 0.947 | 1.052 |
| Pass→fail | real-1536 | 0 | selective | 0.822 | 1.247 |
| Pass→fail | real-1536 | 1 | all | 0.914 | 1.073 |
| Fail→pass | uniform-1536 | 2 | selective | 1.083 | 0.846 |

Stop this descriptor-layout branch. Continue the remaining mapped authority
work from the frozen kernel-inline source: legacy live-write checkpoint and
compaction must rebase current numeric authority onto committed immutable files,
while acquired snapshots keep their own sources. Test failure/publication order
and concurrent updates before fresh mixed/capacity gates. This does not resolve
the existing warm regressions or waive any strict performance requirement.

[Complete source, controls, tests, results and assembly](2026-10-13-mapped-hot-descriptor.json.gz)
contain 4,026 files, 8,674,125 compressed bytes, SHA-256
`69270dbffdad8aff55e43d5bb39525b7087f39ecf08c8c2d2329a1951ffc98c2`.
Archive integrity and every embedded file hash were verified. Binaries and copied
databases are excluded and identified by hashes. The scaled parent control sources
are identified by full hashes and preserved in the linked kernel-inline archive.
