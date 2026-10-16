# Compaction capture outside the writer lock

The change is retained as a partial performance improvement. Across six
alternating version pairs per corpus, selective-query p95 falls 52%, 14% and
38%, with QPS up 7–10%. Uniform-128 independent-query p95 remains 6.5% worse;
this result is retained as an open regression. No formal Qdrant acceptance gate
is newly closed.

## Ownership and publication

The [capture diagnosis](2026-10-16-compaction-capture.md) found file I/O inside
both the writer lock and the generation-pin registry mutex. Capture now reads
an atomic manifest, leases its files, and reads another atomic manifest to
validate that the captured segments remain its leading run. All of this I/O
runs outside the writer lock. A foreground job retains the source collection
lock; background close joins its worker before releasing that owner.

A successful shared `flock` alone is insufficient: an already-open descriptor
may refer to an inode unlinked before the lock was acquired. The second
manifest read proves that the leased names still belong to committed authority.
Subsequent retirement cannot exclusively lock those files. The same prefix
predicate is used again at publication. Appended tails remain valid, while
replaced inputs retry within the existing shared four-attempt budget. Acquisition or catalog errors on files still belonging to that prefix raise,
including a missing single-segment checkpoint when compaction would otherwise
have no work. Input data checksums remain checked during the build.

The registry checks for an existing pin, constructs a new lease outside its
mutex, then rechecks before installing it. Concurrent first pins share one
counted entry; duplicate descriptors close after unlocking. This also removes
indirect writer contention from snapshot acquisition waiting on the registry.
An obsolete optional HNSW cache being reclaimed may be skipped, as an already
missing derived cache was before. Authoritative files always require leases.
Cancellation is rechecked after capture and releases acquired pins.

Pinned Qdrant source `21db2f3ff95d50de3a2b88a741312c056fd1762d`,
`lib/shard/src/optimize.rs`, separates its slow segment build from final
publication and holds strong segment owners. Akasha uses the corresponding
ownership principle with its existing file leases and durable manifest; this
is not a port of Qdrant's disk format or proxy-segment representation.

An initial implementation checked generation equality after leasing. The
existing `test_racing_flushes_rebase_without_conflicts` failed with an exhausted
budget: harmless appended checkpoints also advanced that generation. That
implementation was rejected, archived and replaced by prefix revalidation.
The original test and its zero-conflict expectation are preserved.

## Uninstrumented mixed workload

The baseline is production `ad21da3` (branch head `80cd159` contains later
documentation only). Each worker uses a fresh copy of the same frozen database,
unchanged 32-block update/flush schedule, query order, ef and exact oracles.
There are three original pairs followed by three confirmation pairs, reversing
version order each trial. The confirmation was prompted by a 10.5% independent
p95 regression in the first uniform-128 series; both series remain included.

Entries below are medians of paired **candidate / baseline** ratios, six pairs
per corpus. Lower p95 is better; higher QPS is better.

| Corpus | Mode | QPS | p95 |
| --- | --- | ---: | ---: |
| Uniform-128 | All | 0.999 | 0.990 |
| Uniform-128 | Correlated | 1.008 | 0.921 |
| Uniform-128 | Independent | 0.988 | 1.065 |
| Uniform-128 | Selective | 1.097 | 0.479 |
| Uniform-1536 | All | 1.002 | 0.991 |
| Uniform-1536 | Correlated | 0.997 | 0.973 |
| Uniform-1536 | Independent | 0.997 | 1.021 |
| Uniform-1536 | Selective | 1.076 | 0.858 |
| Real-1536 | All | 1.001 | 1.018 |
| Real-1536 | Correlated | 1.009 | 0.980 |
| Real-1536 | Independent | 1.021 | 0.981 |
| Real-1536 | Selective | 1.074 | 0.616 |

Median total-flush ratios are 1.011, 0.963 and 0.961; total-write ratios are
1.008, 0.985 and 1.008. Selective p95 improves in 17 of 18 individual pairs;
uniform-1536 trial 2 remains worse at 1.197x. Uniform-128 independent p95 ratios
are 1.105, 1.174, 1.046, 0.874, 0.964 and 1.084. Its six-trial medians of absolute
p95 are 680 and 712 microseconds, respectively. These observations do not prove
that its remaining regression is mere noise. Publication contention and
concurrent build work remain possible causes requiring separate controls.

## Lock localization

Another three pairs per corpus use isolated diagnostic libraries. Timestamp
records carry native PID/TID and use the previously calibrated uptime clock;
records are emitted after releasing writer. The after-library records both
short cancellation/counter sections, while manifest/catalog/lease I/O has its
own unlocked span. All builds, tests and containers finish before timing.

Measured aggregate capture-lock duration falls to 0.15%, 0.17% and 0.21% of
baseline, using paired total-duration ratios. The remaining individual spans
are near clock resolution, sometimes zero; their nanosecond medians are not
precise lock-cost estimates. Baseline per-worker median capture sections are
roughly 125–160 microseconds. Publication remains roughly 223–309 microseconds
per-worker median and still performs durable publication and job-pin-release
I/O under writer. Instrumented query timings are diagnostic and do not replace
the uninstrumented table.

## Validation and retained evidence

- 81 relevant native Mojo/recovery cases pass, including eight new cases for
  unlocked capture, append-before-lease, failed/successful stale leases,
  corruption, no-op authority checking and concurrent first pins.
- 388 Python/distributed cases pass (one skip, three warnings), plus the C suite.
- 48 related cases pass on Linux x86_64 under emulation. Permission-fault tests
  must execute without root privileges. The activated compiler runs as root;
  compiled test binaries and their reader children run as UID 501/GID 20.
  The cross-process lease test now supports both `.mojo` and compiled launch
  modes. This is correctness evidence, not native Linux performance acceptance.
- All 54 timed workers preserve original IDs, F32 score bits, search statistics,
  execution classifications and live/filter/recall checks: 15,552 query audits,
  54 exact reopens and 54 Arrow leases. Minimum mode-mean recall is 0.956944.
- The rejected equality protocol, its failed concurrency check, the missed
  crash-test call-site compilation, root permission-test failure, non-root
  compiler setup failures and compiled child-launch failure remain archived.
  Final passing results replace none of those historical records.

The production Python library is SHA-256
`3f55de6fcb363312a7a8ce3e23d1f3644a233a382faf083c986fc2b7ba44f38b`.
The C library is
`0a22bf577c53f4573819d9bf5f07b4e8abc7c5fc86be71954af8b59f7fa06171`.
The isolated diagnostic library is
`86a7a0de9a6801e67b737f5280ee92fabee8059f5ef49e78c137fe42ec7ac2ed`.

Strict Qdrant speed, 128 MiB pressure, sustained full type/lifecycle coverage,
concurrent-client scaling and native Linux remain open. The next optimization
must account for the independent-query regression and the remaining publication
critical section, preserving the same quality, durability and concurrency gates.

[Evidence archive](results/2026-10-16-unlocked-capture.json.gz): 538 text artifacts, 2,850,492 bytes, SHA-256
`3a87ae6bb607c09817fadb66ed3982532e0513fb68eac987262679a6f751b42a`.
Original frozen plans are linked by hash to the preceding query-control archive.
Every embedded file hash is verified after decompression.
