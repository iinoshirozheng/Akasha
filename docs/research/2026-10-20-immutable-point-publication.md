# Compaction publication: duplicate validation removed, speed gates still fail

The isolated candidate removes complete point validation repeated under the
collection writer lock. The mapped decoder already performs that validation
before writer acquisition. Instrumented publication holds fall from median
1.80–1.87 ms to 1.33–1.48 ms across three corpora. Fresh uninstrumented mixed tests
pass 20/36 strict quality-plus-speed cells, versus 15/36 for the preceding
[consumer candidate](2026-10-20-immutable-point-consumers.md) and 26/36 for
production. Seven production passes become failures. Production remains
`a6822c3`; this candidate is not adopted and M5/M6 remain open.

## Qdrant reference and measured cause

The reference is Qdrant commit `21db2f3ff95d50de3a2b88a741312c056fd1762d`:

- [`finish_optimization`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478)
  finishes expensive construction before taking the holder's upgradable read
  guard and update mutex, applying remaining changes and swapping segments.
- [`LockedSegmentHolder`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs#L18)
  separates its holder RwLock from an update mutex. Excluding updates therefore
  permits holder read access until the holder write guard is required.

Akasha ANN queries and background publication still use the same collection
writer lock. This experiment measures the resulting critical section; it does
not implement Qdrant's complete read/update concurrency architecture or change
the lock primitive.

Three diagnostic phases each run one frozen mixed worker per corpus. The first
phase separates acquisition, staging, durable publication, owner exchange and
retirement. The second splits staging into point, projection and read-run work.
The third repeats that instrumentation with the duplicate validation removed.
Timers surround the existing lock boundaries; diagnostics print after unlock.
All nine workers finish, preserve exact responses and retain raw logs. These
instrumented runs establish phase costs, not performance acceptance.

Median times in milliseconds from phases two and three:

| Corpus | Prior hold | Candidate hold | Prior point staging | Candidate point staging | Prior read staging | Candidate read staging |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 1.7965 | 1.3340 | .6610 | .1940 | .7700 | .8015 |
| uniform-1536 | 1.8685 | 1.4780 | .6575 | .1950 | .8345 | .8855 |
| real-1536 | 1.8350 | 1.3865 | .6825 | .1975 | .7955 | .8010 |

Each worker publishes ten compactions. Read staging copies 8,224–8,440 row
descriptors per publication, including the immutable 8,192-row base. Existing
base rows contain versions affected by compaction, so owner rebasing currently
clones that table as well as newer rows. This remains the largest measured phase.
Median projection work is .071–.080 ms, disk publication .250–.304 ms and owner
exchange .016–.019 ms. No inferred spin-wait delay is substituted for these
measured costs, and latency outliers remain in all reports.

## Implementation and validation

Only `src/akasha/storage/point_table.mojo` changes from the verified consumer
parent. `_stage_compaction_owners` no longer calls `point.validate` for every
prepared point. Its sole caller receives points from `prepare_live_compaction`:
the mapped segment decoder validates the complete point, including tombstones,
before returning. Preparation also checks segment identity, CRC, interval and
catalog; final publication rechecks the catalog checksum under writer.

Live slot, sequence, document sequence, tombstone, field, type, byte-count and
projection-owner checks remain in staging. Ordinary checkpoint validation stays
unchanged. No persistence format, score arithmetic, API, compaction threshold or
four-delta partial-compaction policy changes.

A new regression corrupts a dense point's document sequence while recomputing a
valid CRC, for both v4 and v5. Publication rejects the semantic error, releases
job pins and the source lock, removes the output, preserves the manifest and
current numeric owner, and reopens the original values. This proves semantic
validation remains on the preparation path after removing its duplicate.

Mojo `1.0.0 (ed45d567)` compiles the unchanged final candidate inventory:

- **60 CPU cases in ten selected modules**, including the new v4/v5 case,
  foreground/background/partial publication, exact-file leases, codec, recovery,
  migration, read views and backup.
- **23 checkpoint/WAL recovery cases in eight modules**.
- **379 Python cases**, verifying the candidate library in four processes.
  Static repository-source probes still inspect repository source.
- **Candidate C ABI** shared-library build, strict C11 compilation and execution.

The separate narrow invocation of the new regression is not additional coverage.
The prior candidate's 12 actual Metal cases remain applicable because this sole
change does not affect its GPU/reader sources or fixtures; no new GPU run is
claimed. Python library SHA-256 is
`37fdecf07b2ffcc888f4723f0847719b9aaaf0eb7a4ae879ac4589555d242bce`;
C library SHA-256 is
`bcc507a9fcf38fc547a67e756d61ac7e1847c6d084be666f67c578ecca2bf893`.

## Fresh fixed mixed comparison

The same three corpora and three trials run production, the preceding consumer
candidate, this candidate and pinned native Qdrant Edge 0.8.0: **36 serial workers**.
Each executes 32 blocks of nine reads, eight updates and a flush. Engine order
rotates by trial, using three of four possible rotations; it is not fully
balanced. Plans, workloads, ef values, oracles and strict per-cell gates are
unchanged. No builds, tests, profiling or compression overlap timed workers.

All **10,368 responses**, **36 exact reopens** and **27 retained Arrow leases**
pass their audits. All three Akasha variants have identical IDs, F32 score bits,
statistics and execution decisions, and each meets all 36 Recall@10 ≥ .95 cells.
Matched quality is 33/36 because Qdrant real-1536 correlated recall remains
.945833 in each trial, versus .980556 for Akasha. Those cells remain failed.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 26/36 | 9/9 |
| Prior consumer candidate | 33/36 | 15/36 | 9/9 |
| Publication candidate | 33/36 | 20/36 | 9/9 |

Candidate/production median ratios within this batch follow. QPS is better above
1; p95 is better below 1. These summaries do not replace individual trial gates.

| Corpus | Mode | QPS ratio | p95 ratio |
| --- | --- | ---: | ---: |
| uniform-128 | all | .876 | 1.065 |
| uniform-128 | correlated | .869 | 1.245 |
| uniform-128 | independent | .985 | 1.045 |
| uniform-128 | selective | .642 | 1.042 |
| uniform-1536 | all | .990 | .985 |
| uniform-1536 | correlated | .977 | 1.036 |
| uniform-1536 | independent | .989 | .974 |
| uniform-1536 | selective | .837 | 1.004 |
| real-1536 | all | .938 | 1.031 |
| real-1536 | correlated | .951 | 1.063 |
| real-1536 | independent | .969 | .948 |
| real-1536 | selective | .744 | 1.103 |

The seven production pass-to-fail cells, using zero-based trials, are:
uniform-128 trial 0 correlated/selective, trial 1 all/correlated, trial 2 all;
uniform-1536 trial 1 selective; real-1536 trial 0 independent. Only uniform-128
trial 2 selective changes from production failure to candidate pass. Compared
with the prior candidate, uniform-1536 trial 1 selective becomes a failure and
six failures become passes. Improvements do not offset individual regressions.

Against the prior candidate, selective QPS median ratios are .961/1.092/1.265
for uniform-128/uniform-1536/real-1536. Uniform-128 correlated p95 regresses by
14.7% in that comparison. The candidate therefore does not improve every workload.
Historical batches remain separate; the earlier consumer report's 18/36 result
is not a baseline for this batch.

Combined update-plus-flush passes all nine trials for each Akasha variant.
Candidate flush-time ratios versus production are 1.016/1.018/1.010. Individual
update calls remain durability-inequivalent: Akasha waits for WAL fsync while
Qdrant Edge synchronizes through its separate flush. This batch does not prove
concurrent-client or sustained-maintenance acceptance.

## Remaining work and reproducible evidence

Next reduce immutable read-run copying under writer, using stable captured owners
and final identity/version checks to preserve intervening writes and snapshots.
Skipping owner rebasing or changing compaction policy would not meet the current
requirements. Full warm/concurrent performance, sustained nonresident capacity
under equal caps, remaining integration/example validation and native Linux
performance stay open. No full M5/M6 completion or production adoption is claimed.

The [evidence archive](2026-10-20-immutable-point-publication.json.gz) contains
the final 130-file candidate inventory, its one-file patch, all three instrumented
source trees, exact tests and logs, nine diagnostic and 36 timed worker reports,
every failed gate, Qdrant source and license, and build identities. The unchanged
large workload plans are retained in the verified parent archive, referenced by
its SHA-256 rather than duplicated. Native binaries and copied databases are
excluded. All embedded hashes and the parent inventory were verified:
1,000 text artifacts, 3,270,538 compressed bytes, SHA-256
`03c733074022934c435c2c219be5d99d5e4c33a2307f2cbf33f467f4727f73e0`.
