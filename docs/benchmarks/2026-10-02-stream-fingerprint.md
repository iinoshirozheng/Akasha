# Streamed fingerprint: bounded memory and flush cost

The authoritative fingerprint now feeds headers, immutable F32 row bytes and
encoded payloads into the existing CRC register. A reused BinaryWriter clears
its logical contents while retaining allocation between headers. It no longer
materializes the collection's entire encoded fingerprint. Little-endian hosts
borrow row bytes only for the synchronous checksum call; other endianness still
uses the existing little-endian row encoder. Fingerprint bytes are unchanged.

The first prototype regressed 128D by allocating each header afresh. Reusing that
allocation corrected the regression. Both prototypes remain in the archive.
The [plan](../plans/2026-10-02-stream-fingerprint.md) records the bounded storage
contract and verification scope.

## Isolated fingerprint

Three alternating before/after pairs use 8192 rows, three timed repetitions and
identical checksum values. Both binaries already use the block CRC algorithm.
Reported figures are medians of the three trials:

| Dimension | Before ms | After ms | Before peak RSS MiB | After peak RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| 128 | 5.622 | 4.064 | 32.641 | 20.328 |
| 1536 | 41.222 | 23.671 | 179.953 | 67.625 |

RSS is accounting for one completed native child from a fresh Python wrapper
using `resource.getrusage(RUSAGE_CHILDREN)`, not a live-process sample or an
allocation counter. `/usr/bin/time -l` initially failed because the sandbox denied
its `kern.clockrate` read; that incomplete sample is retained separately and
excluded. Clockrate inspection was not retried. Native child accounting does not
inspect unrelated processes.

## Public binding lifecycle

Three corpora each run three alternating pairs with
`benchmarks/bounded_batch.py --phases mixed`, comparing saved post-block-CRC and
current packages. The same 32-block workload, baseline copies, queries, fixed ef,
Arrow lease and reopened exact oracle are used. All 5,184 query audits, 72
mode/version/trial recall cells, 18 reopen oracles and 18 leases pass. No builds
or tests run during measurements. OS cache remains present.

The following are medians of per-trial p95 values. Ratios are calculated within
each before/after pair, then summarized by median and full range:

| Corpus / operation | Before ms | After ms | Paired ratio, median (range) |
| --- | ---: | ---: | --- |
| Uniform 128D / flush | 21.210 | 16.398 | .773 (.331–.856) |
| Uniform 1536D / flush | 64.742 | 42.701 | .563 (.507–.950) |
| Real 1536D / flush | 62.503 | 41.493 | .670 (.505–.676) |
| Uniform 128D / write + flush | 31.844 | 24.137 | .774 (.415–.911) |
| Uniform 1536D / write + flush | 89.679 | 69.687 | .777 (.452–.920) |
| Real 1536D / write + flush | 78.523 | 59.847 | .773 (.591–.824) |

Outliers remain visible: pre-change 128D flush p95 is 50.759 ms in its third trial;
uniform 1536D has a pre-change 84.285 ms and a post-change 58.312 ms trial.
Real-data write p95 is higher in all three after trials: paired median 1.054,
range 1.017–1.194. Its median p95 rises 17.383 to 18.325 ms even though combined
write-plus-flush improves. The run does not isolate the cause of write-only
variation. Reopen is essentially unchanged (paired medians .994/.996/.990),
so this change does not close the reopen gap.

## Verification and scope

The new writer check first failed to compile because the method was absent,
then passed its standard CRC check value, empty drains and allocation reuse.
All existing independently encoded fingerprint fixtures pass, including signed
zeros, signed IDs, payload types, replacements, tombstones and sparse-only changes.
Affected validation totals 56 Mojo tests and seven checkpoint crash tests; the
rebuilt Python extension passes all 317 tests, and the rebuilt C ABI client passes.
The earlier [complete CPU checkpoint](../research/2026-10-02-cpu-integration.md)
remains identified separately rather than being relabeled as a later full run.

[Sources, raw paired samples, prototypes, validation logs and JUnit output](results/2026-10-02-stream-fingerprint.json.gz)
have SHA-256 `8c9cd0f48f56b12cf9c94256a7218aea55f3fd884ca844bd11b670d4ef245fee`.
These gains do not establish Qdrant or non-resident parity.

An independent native-query experiment removed a redundant mapped-header byte
read during readiness checks. It showed modest 128D gains but inconsistent
high-dimensional results, including slow after samples. It was not adopted;
[its complete samples and source copies](results/2026-10-02-hnsw-ready-probe.json.gz)
are retained. Compiled distance kernels already emit NEON fused multiply-adds,
so no separate FMA rewrite was needed.
