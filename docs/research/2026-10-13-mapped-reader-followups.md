# Mapped reader follow-ups — 2026-10-13

The mapped owner is still **unadopted**, and M5/M6 remain incomplete. These isolated
follow-ups preserve the production source and binary. The kernel snapshot restores
most high-dimensional full-exact throughput in its own comparison, but still has
six pass→fail cells and cannot be promoted. Capacity success belongs to the
[earlier owner build](2026-10-13-mapped-numeric-owner.md), not these untested-capacity variants.

## Controlled changes and identities

All candidates start from the frozen mapped owner binary `683bd385` and its complete
123-file Mojo source copy. Each built candidate has its own full Python package;
workers never load a library being overwritten. Builds, tests, profiling, warm
workers and archival compression run serially. Mojo 1.0.0, Apple M4 target and
Metal 4 flags remain unchanged. No dependency, durable format, oracle, ef, filter,
query, accumulator width/order or timing boundary changes.

| Candidate | Source change | Native binary SHA-256 |
|---|---|---|
| Single Variant | Replace the reader's two Optional owner-object pointers with one Variant; adapt Arrow's private source selection | `37eee57aa07f9c683edfc063ffcc81b5c61c9b3abc1e23416160e6abb117f4a3` |
| Kernel snapshot | Snapshot storage metadata inside pure synchronous F32 single, paired and prevalidated kernels | `07634a6bc6939d30c89c71ed82c8217ff724133ebb0ba149b95b2927a77060bb` |
| Factory inline probe | Seven `always_inline` annotations on the parent reader factory chain | No new shared library; mechanism probe only |

Source/package directories are `.build/m5-resume/mapped-reader-variant`,
`mapped-kernel-snapshot` and `mapped-reader-inline`; standalone probes are in
`mapped-kernel-scope`. Each is frozen in the archive below. The inline directory's
copied library remains the parent and is not a build of its annotated source.
Production remains engine `6d01819`, Python SHA
`45b24374c5e19ee4d67d3523c59788b22064e69c6838955148fe6cfb52e798b9`.

## Mechanism and correctness

Mojo permits explicit List reallocation/clear and MappedFile close/replacement while
an embedded immutable reader remains live. Two new regressions pass on the parent
and Variant sources: each subsequent read must observe the current owner/allocation.
A cached data pointer in the general reader would violate these cases. The Variant
keeps all owner reloads and checks; it does not solve the warm regression.

The standalone probes separate direct readers, factory-plus-score calls, and an
immediately consumed checked raw range. The first probe leaves query source kind
dynamic; `entry_probe.mojo` fixes the query to List, matching the collection caller.
Each timing covers 256 rows × 64 repetitions with rotating order and score-sum
checks. These tiny working sets and repeated queries are mechanism diagnostics,
not a workload gate or independent recall evidence. Factory annotations alone did
not show a clear gain in that microbenchmark; this does not test the larger
collection caller's inlining decisions.

The kernel snapshot changes only `akasha/compute/simd.mojo`. Its private `_KernelRead`
captures a current origin-bound pointer, row length, accessible length and source
state at each synchronous scoring invocation. The kernel has no callback, yield or
storage mutation, and its caller retains the immutable field/operation owner for the
entire call. This state never returns from scoring and is not added to the general
reader or any persistent cache. General reads still reload their live source.

Each original scalar/SIMD access retains row bounds, captured closed-state and
available-storage checks with the original error text and order. Validation is not
moved wholesale before finite checks: a shortened scalar tail can still report an
earlier nonfinite value, while a truncated SIMD prefix reports storage bounds first.
Paired dimension mismatch still scores the earlier candidate first; an empty
prevalidated kernel still returns zero without a storage load. New tests exercise
these cases and source replacement/reallocation between kernel calls. SIMD widths,
reductions, tail arithmetic and finite/cosine rules remain unchanged.

| Validation | Variant | Kernel snapshot |
|---|---:|---:|
| Distinct selected Mojo cases | 58 (56 suite-runner cases + 2 live-source cases) | 61 across 14 suites |
| Expected negative compiles | 4 | 5, including kernel pointer origin escape |
| Full Python suite | 359 passed | 359 passed |
| Fixed warm quality cells | 36/36 before and after | 36/36 before and after |
| Warm IDs/F32 bits/stats/execution | Equal | Equal |

Each selected Mojo set includes the mapped Metal regression on the actual device;
it is not an additional case on top of the counts above. The three new kernel-error
cases also passed on the parent before the source change; repeats are not summed.
Child compiler wrappers redirect both relative and absolute includes to the isolated
source and retain their invocation logs. This is not a full CPU suite, nor a new
C/crash/Linux/memory-cap validation. The first Variant harness attempt omitted its
output directory; that setup failure and its correction are retained. Expected
negative compile diagnostics are retained, including the deprecated origin-name
warning in the new rejection probe.

## Fixed native warm comparisons

Each candidate has a separate batch of 27 serial workers: three corpora × three
rotating production/candidate/Qdrant triples, 36 measured cells. Qdrant Edge 0.8.0,
Recall@10 ≥ .95 and simultaneous QPS ≥ Qdrant **and** p95 ≤ Qdrant remain mandatory.
No noisy cell, timeout or regression is discarded; a faster cell cannot offset a
slower one. These batches cannot be compared by subtracting their pass counts.

| Batch | Strict speed before→after | Pass→fail | Fail→pass | Uniform-128 full QPS after/before | Uniform-1536 full QPS after/before |
|---|---:|---:|---:|---|---|
| Variant | 20/36→15/36 | 6 | 1 | .667 / .646 / .635 | .677 / .720 / .714 |
| Kernel snapshot | 20/36→15/36 | 6 | 1 | .758 / .725 / .748 | .999 / .954 / .956 |

All pass→fail cells are listed below; complete trials and fail→pass cells are in the
raw summaries. Ratios compare each candidate to production in its own batch.

| Candidate | Corpus | Trial | Mode | QPS ratio | p95 ratio |
|---|---|---:|---|---:|---:|
| Variant | uniform-128 | 0 | selective | 0.807 | 1.291 |
| Variant | uniform-128 | 1 | correlated | 0.665 | 1.953 |
| Variant | uniform-128 | 1 | independent | 0.406 | 3.256 |
| Variant | uniform-128 | 1 | selective | 0.662 | 2.139 |
| Variant | uniform-1536 | 1 | selective | 0.844 | 1.148 |
| Variant | uniform-1536 | 2 | selective | 0.898 | 1.075 |
| Kernel snapshot | uniform-128 | 0 | correlated | 0.478 | 3.035 |
| Kernel snapshot | uniform-128 | 1 | independent | 0.451 | 3.723 |
| Kernel snapshot | uniform-1536 | 0 | selective | 0.894 | 1.188 |
| Kernel snapshot | uniform-1536 | 1 | selective | 0.932 | 1.020 |
| Kernel snapshot | uniform-1536 | 2 | selective | 0.906 | 0.998 |
| Kernel snapshot | real-1536 | 0 | selective | 0.899 | 1.185 |

Targeted disassembly covers `_search_candidates` plus separately emitted scoring
kernels. Production totals 14,580 bytes; the mapped owner 45,884; Variant 44,740;
kernel snapshot 23,776. Kernel snapshot still has four out-of-line `_dense_reader`
call sites. Code size and microbenchmarks guide the next test; they do not prove
that call cost explains all remaining full-workload regressions.

## Next boundary and retained evidence

Next, test the factory annotations in the actual collection caller on the kernel
snapshot source and inspect its emitted calls. Only continue that change if the
fixed comparison supports it. Do not repeat the Variant refactor or unchanged
capacity trials. Legacy live-write rebasing, mixed/concurrent and sustained
nonresident gates, final full integration and native Linux performance remain open.
The current isolated candidates cannot close any of those gates by inheritance.

[Complete sources, commands, tests, raw trials and disassembly](2026-10-13-mapped-reader-followups.json.gz)
contain 5,462 files, 12,985,499 compressed bytes, SHA-256
`542b41eb57d1181c8ef88c2985c31badc80f626caf3214202ce80aae8bbd7888`. Every embedded file hash and archive integrity were verified.
Binaries and copied databases are excluded and identified by hashes.
