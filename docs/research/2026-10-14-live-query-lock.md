# Separate live-query exclusion from durable publication

The isolated lock separation lets all six ANN entry points progress while a
publication-only writer lock is held. All nine mixed selective p95 pairs improve,
and mixed strict speed passes rise **23 → 28 / 36**. The candidate is not adopted:
warm passes fall **25 → 22 / 36**, one mixed cell changes pass→fail, and combined
write+flush passes fall **3 → 2 / 9**. Production and M5/M6 requirements remain
unchanged; improvements do not offset failed cells.

The parent is the frozen [checkpoint-copy composition](2026-10-14-checkpoint-bulk-copy.md),
not production. The experiment follows the measured
[background compaction lock waits](2026-10-14-mixed-query-boundaries.md).
Only `api/collection.mojo` changes relative to that parent. One heap-stable
`BlockingSpinLock` protects live query state. All 50 existing foreground writer
scopes acquire writer then query; six approximate entry points acquire only query.
The background worker retains writer exclusion and has no live MemTable,
MetadataIndex, HNSW or query-scratch reference. Snapshot/read-generation and
manifest/pin operations remain writer-serialized. The 18-method direct query
closure never acquires writer. An executable-body normalization audit confirms
that no original body was moved outside its previous foreground scope.

ANN scratch/statistics, mutations, uncertain-write state, close and HNSW
capture/exchange still serialize. Detached HNSW rebuilding remains outside the
capture/exchange locks. Foreground flush I/O still excludes queries, and a
foreground caller holding writer while waiting for query can delay maintenance.
This reasoning does not automatically apply to the separate, unadopted
mapped-live-owner prototype: publishing new live numeric owners would also need
query exclusion. No format, durability, query algorithm or scheduling policy is
changed here.

Four new cases cover progress through all six ANN entries under publication-only
exclusion, error release/post-close rejection, complete-batch visibility, and
close/query races. The parent passes three and fails exactly the progress case;
the candidate passes all four. A harness-generation SyntaxError before mutation
caused an unintended duplicate run of the unchanged parent. Both failed runs and
the preparation error remain archived; neither is labeled a candidate result.

Fresh validation passes **91 Mojo cases in 12 files**, **21 crash-state cases in
six files**, **369 Python cases**, and C ABI compilation/execution. Existing
concurrency, all 18 HNSW rebuild-publication cases, sidecar/background publication,
maintenance, retirement, snapshots, point batches/compaction, backup and recovery
ordering are included. Python retains three existing warnings and no skips;
Mojo shared-library builds have no warnings. This is not a full CPU or crash-kill
suite, and no Linux, capacity, HTTP or GPU gate is claimed.

All **54 serial native workers** complete using unchanged corpora, ef values,
filters, plans, oracles and three rotating triples against Qdrant Edge 0.8.0.
Warm takes 46.14 s; mixed takes 68.76 s and returns its expected strict-gate failure
after all nine triples. Both versions pass quality 36/36 in each phase. IDs,
Float32 bits, statistics and execution decisions match exactly; lease/reopen
checks pass. Post-timing audits find 18 byte-identical overlay/metadata payload
pairs with valid envelope and inner snapshot CRCs.

| Phase | Strict speed before → after | Pass → fail | Fail → pass |
| --- | ---: | ---: | ---: |
| Warm query | 25 → 22 / 36 | 3 | 0 |
| Mixed query | 23 → 28 / 36 | 1 | 6 |
| Mixed write+flush | 3 → 2 / 9 | 1 | 0 |

Mixed selective p95, in microseconds:

| Corpus | Trial 0 before → after | Trial 1 before → after | Trial 2 before → after |
| --- | ---: | ---: | ---: |
| Uniform 128 | 311.416 → 115.083 | 352.250 → 103.709 | 120.000 → 88.583 |
| Uniform 1536 | 328.833 → 151.792 | 194.084 → 163.042 | 216.250 → 189.417 |
| Real 1536 | 245.000 → 174.208 | 311.459 → 188.417 | 287.292 → 195.291 |

Eight of nine selective QPS pairs improve; uniform-128 trial 0 falls 7.3% despite
the lower p95. Warm pass→fail cells are uniform-128 selective trial 1, real-1536
selective trial 0 and real-1536 all trial 1. Mixed uniform-128 independent trial 0
also changes pass→fail. Uniform-128 trial-0 combined write+flush p95 rises from
24.849 ms to 46.780 ms, above Qdrant's 44.279 ms. These failures remain in the raw
reports and are not attributed to noise or a cause without further measurement.

The [archive](2026-10-14-live-query-lock.json.gz) contains **824 files,
3,964,724 bytes**: full sources, both source diffs, lock/call audits, tests,
failed harness/parent runs, Python/C identities, every raw worker, byte audits and
verified references to the parent, motivating diagnostics and original plans.
Every embedded hash is verified. Root source, Python and C binaries are unchanged.

- Candidate Python SHA-256: `fd0dddd7930c45d6ace5810f0b9f10154d201ad2df75ffe3e766e2f949b22aaf`.
- Candidate C library SHA-256: `d0b4b7b2ffdc5f80dfd8a39e62818c2bc03de7a45b07854d82711e3378ab8811`.
- Archive SHA-256: `0e9ba9630a0681ad660cd694912f030878bcc44bca73009f2c28919855f4734b`.

The progress regression and nine selective tails support keeping this as a
validated development candidate. Remaining warm, filtered ANN and write/flush
gaps still require work; this report does not establish overall parity.
