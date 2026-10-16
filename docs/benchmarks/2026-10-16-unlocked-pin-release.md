# Publication profiling, rejected pin-release move, and retained durability fence

The publication experiment is **rejected**: moving the compaction job pin release
past publication reduced typical lock time but regressed selective mixed queries.
The retained production change only syncs observed manifest authority before
lease/orphan cleanup deletes its first obsolete file. A real directory-fsync
failure reproduces premature deletion on `5c5f418`; the retained fence preserves
inputs, then permits retry and exact reopen. No formal Qdrant gate is closed.

## Scope and reference

Baseline is `5c5f418`, following [unlocked capture](2026-10-16-unlocked-capture.md).
Tests use the same frozen uniform-128, uniform-1536 and real-1536 plans, original
queries, ef, result IDs/F32 score bits, stats, execution checks and quality floor.
Workers run serially on macOS ARM64; no build, test, container workload or evidence
compression runs during timed pairs. Each corpus has six alternating
uninstrumented before/after pairs and three diagnostic pairs. The earlier
publication profile has three workers per corpus, plus three drained pairs per
corpus comparing capture before/after. Drain changes scheduling and is diagnostic.

Pinned Qdrant `21db2f3ff95d50de3a2b88a741312c056fd1762d`,
`lib/shard/src/optimize.rs:605–645`, syncs its manifest, registers deferred segment
destruction against a durable waterline, and releases update/holder guards before
dropping proxy owners. The applicable principle is ownership through publication
and deletion only after durable authority; this does not imply equivalent formats.

## Localization

The previous worst-five independent queries per worker (15/corpus) show ten of
fifteen low-dimensional queries overlapping publication after capture moved out of
writer; median thread CPU/wall is 0.793. The corresponding drained independent
p95 ratios are 1.030/0.971/0.983. Low-dimensional drained selective p95 remains
1.070, including one broadly slower trial. Overlap is not proof that every excess
nanosecond is caused by the lock, and the drain control does not erase regressions.

Successful publication phases, median of per-worker medians, microseconds:

| Corpus | Unpin | Load manifest | Prepare | Durable publish | Root | Queue |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 33.209 | 30.250 | 1.375 | 156.125 | 0.042 | 1.417 |
| uniform-1536 | 45.750 | 34.959 | 1.417 | 208.667 | 0.042 | 1.416 |
| real-1536 | 34.709 | 32.979 | 1.688 | 187.855 | 0.041 | 1.438 |

Unpin occupies roughly 14–20% of successful publication lock intervals; durable
publication occupies 66–72%. Some whole publication intervals are cancellation
and output discard at close, with no success subphases. Success shares use only
matched successful intervals (`*-successful-phase-shares.json`); the all-interval
shares in the raw summary include cancellation. Instrumentation uses aligned
native/Python clocks, records PID/TID, and writes records after unlocking.

## Rejected candidate

The candidate kept the job pin through finish, released it outside writer and
retained source ownership through cleanup. Throwing publication released counts
and descriptors without deleting files, because rename could precede failed
sync. Tests covered successful pin retention, both possible durable manifests,
failed publication, close during cleanup and concurrent publication. This also
exposed a preexisting durability gap in surviving reader/orphan cleanup.

Uninstrumented median paired candidate/baseline ratios (QPS higher is better;
p95, flush and write time lower is better):

| Corpus | Selective QPS | Selective p95 | Independent QPS | Independent p95 | Flush | Write |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 0.925 | 1.173 | 1.004 | 1.005 | 1.040 | 1.049 |
| uniform-1536 | 1.011 | 0.975 | 0.991 | 1.004 | 1.015 | 0.937 |
| real-1536 | 0.961 | 1.037 | 0.998 | 0.997 | 0.999 | 0.954 |

All six real selective QPS pairs regress. Low-dimensional selective p95 ranges
0.788–3.774; all trials are retained. Diagnostic publication medians move from
233/300/290 to 212/295/248 microseconds. Their total interval ratios are
0.899/0.812/1.263, including changed job counts and cancellation/discard time;
these are not interchangeable with successful-call latency reductions. One
uniform-1536 diagnostic total ratio is 3.945 and remains in the record.

Moving release past publication also changes its work: the last lease now scans
and reclaims replaced inputs before the retired queue checks them again, with
additional syncs and different worker scheduling. This is a plausible source of
cost, not a proven attribution of all query regressions. The candidate, tests,
binaries' hashes and traces are preserved; production publication/unpin boundaries
are restored to the accepted baseline. A shorter measured critical section alone
is insufficient to retain an optimization.

## Retained fix

`ManifestFileLease.reclaim()` reads the current atomic manifest. After acquiring
an exclusive lease on the first obsolete file, it syncs the anchored directory
before unlinking anything. A visible manifest rename may precede its publisher's
failed directory sync; a reader in another process must not delete the old files
until the authority it observed is durable. The sync is lazy: current files and
still-leased obsolete files do not trigger it. Open-time orphan cleanup makes the
same pre-delete fence under the source writer lock. Existing post-delete syncs
remain. The retirement queue already receives durable proof of obsolescence.
No durable schema, query contract or publication-lock boundary changes.

The fixed crash suite loads a C shim only in its child process. Creating a marker
makes the next directory `fsync` fail with `EIO`; ordinary file syncs are unaffected.
It verifies last-reader cleanup reports failure without deleting any input,
explicit retry reclaims safely, and reopen preserves both rows. It also verifies
orphan cleanup retains an unreferenced job file when its pre-delete sync fails,
then removes it on retry. Linux uses `LD_PRELOAD`; Darwin uses the dyld interpose
table. The initial Darwin shim used `dlsym(RTLD_NEXT)` and recursed; the test fixture
was corrected to call the original from its interposing image, following the
[Apple dyld example](https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld-interposing.h).
The failed fixture trial is recorded; it did not modify production.

## Validation and retained comparison

- Rejected candidate: 83 relevant native Mojo/recovery cases plus the initial
  fixed fsync probe; 388 Python/distributed cases (one skip, three warnings), C;
  51 Linux-emulated cases plus the initial fixed probe. The retained-pin red
  test fails on the old code as expected. The separate Linux fsync probe fails
  baseline with "retired input disappeared before authority sync succeeded"
  and passes the candidate.
- Retained fence-only source: 53 native Mojo/recovery cases, 388 Python/distributed
  cases (one skip, three warnings), C, and 30 Linux-emulated cases pass. This
  includes the expanded fixed test of both lease and orphan cleanup. Linux is
  x86_64 under emulation; ordinary relevant suites execute as UID 501/GID 20,
  while the loader probe's wrapper compiles/runs in the activated root toolchain.
  It injects fsync directly and does not depend on chmod permissions.
- The previous baseline's broader successful checks remain separately recorded;
  these counts do not claim a new full CPU suite or native Linux performance.
- Profiling/drained controls and the rejected comparisons audit 23,328 responses,
  81 exact reopens and 81 Arrow leases. The retained comparison audits another
  10,368 responses, 36 reopens and 36 leases. Every ID, F32 score bit, recall,
  execution check and stats field matches the original frozen response.

Retained fence-only/baseline median ratios, six alternating pairs per corpus:

| Corpus | Mode | QPS | p95 |
| --- | --- | ---: | ---: |
| uniform-128 | all | 1.006 | 0.971 |
| uniform-128 | correlated | 0.996 | 1.072 |
| uniform-128 | independent | 1.009 | 1.015 |
| uniform-128 | selective | 0.947 | 0.990 |
| uniform-1536 | all | 1.001 | 1.000 |
| uniform-1536 | correlated | 0.993 | 1.004 |
| uniform-1536 | independent | 0.994 | 1.047 |
| uniform-1536 | selective | 1.022 | 1.013 |
| real-1536 | all | 0.990 | 0.994 |
| real-1536 | correlated | 0.996 | 1.016 |
| real-1536 | independent | 0.998 | 0.992 |
| real-1536 | selective | 0.991 | 1.024 |

Flush ratios are 1.016/0.965/1.001; write ratios are 0.987/1.018/1.041.
This is retained for demonstrated durability, without claiming a speedup or
performance neutrality. Low-dimensional selective QPS is 0.947, correlated p95
is 1.072, and uniform-1536 independent p95 is 1.047; these costs/variations remain
visible follow-up work. Across all 117 workers, 33,696 response audits agree,
all 117 exact reopens and Arrow leases pass, and minimum mode recall is 0.956944.

Python binary SHA-256:

- Baseline: `3f55de6fcb363312a7a8ce3e23d1f3644a233a382faf083c986fc2b7ba44f38b`.
- Rejected candidate: `710f7a9700555e22a56ca2aaad9e7bdbabd3635e36f1679737027521503ba0fd`.
- Retained fence: `55d16d66769e3dbce395ea027efe1a9d897eb4d5582410a863167559d5e3395a`.
- Publication profile: `a4b1a1c309ef3cc52ccca8b94c1a2ab99f237631040a9a3335e129dde22c8deb`.
- Rejected diagnostic: `691cc562be26fcbea12de47391500181ff3c22349d8e0580241ce7fed7c87873`.

Retained C library SHA-256 is
`cb200da059c81622c96c47c2f25d8bfee1fd381a312618e5d73d318f06dfe5fe`.
All binaries are rebuilt from their respective source; trace timings are
separate from uninstrumented comparisons.

## Remaining gates

This is a durability repair and a rejected optimization, not a fresh formal
Qdrant acceptance. The last formal checkpoint remains `45e04d2`: warm speed 6/36;
mixed matched quality 33/36, speed 12/36 and write/flush 3/9. The three Qdrant real
correlated recall failures at frozen ef are not waived. Full type/lifecycle and
sustained capacity coverage, both 128 MiB mixed-pressure failures, concurrency
scaling and native Linux performance remain open. The previous low-dimensional
independent-tail regression is not closed by these local comparisons.

Durable manifest publication dominates the remaining successful critical section.
Further work must preserve its crash boundary while addressing preparation,
publication frequency or merge write amplification. Qdrant's size-based merge
selection is a source-grounded next investigation. Akasha currently captures all
committed segments and its base merge drops tombstones; its base format forbids
them. Sorting small inputs alone would be incorrect without a deletion-preserving
partial-merge protocol. First measure rewritten bytes and job frequency; removing
syncs is not a valid performance fix.

## Evidence

[Complete evidence archive](results/2026-10-16-unlocked-pin-release.json.gz):
768 text artifacts, 5,451,627 bytes, SHA-256
`24042ecaaa84a491a63401e9048e99cb97e3a36575f8a3dadb30223322155cf6`.
It contains every profile/pair, all validation logs, failure records, the rejected
source patch, retained source, fixture code, binary identities and reproducible
drivers. The initial Darwin recursion has a failure summary (its full tool stderr
was not retained); the original Linux before/after fault logs are complete.
