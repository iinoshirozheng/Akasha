# Compaction reclamation outside the writer lock — 2026-10-03

Adopted: successful compaction now queues obsolete files during publication and
runs their lease-aware reclamation after releasing the writer lock. This removes
measured filesystem work from the query critical section and lets close progress
during a blocked foreground reclamation, while retaining source ownership.
**M5/M6 remains incomplete:** warm strict parity is 16/36; mixed is 28/36.
The four-row distance candidate remains separate and unadopted.

## Change and safety

The [plan](../plans/2026-10-03-unlocked-reclamation.md) follows the limited pattern
already used by local RocksDB: gather obsolete files under the mutex, purge after
unlocking. There is no new dependency, public API, format or alternate lock.

`finish_compaction` retains validation, rebase, durable publication, job-pin
release and cancellation/error ordering. It now enqueues obsolete paths. Both
foreground and background callers open the directory and detach an owned batch
under the writer lock, perform existing lease/flock/unlink/directory-sync work
outside it, and restore deferred paths under the lock. New queued paths survive.
An open failure leaves the shared queue intact; an I/O failure restores the full
retry batch before propagating. The open directory anchors I/O across renames.

Foreground compaction explicitly keeps its captured source-lock owner alive
through reclamation, including failure. Close can finish, but a new writer cannot
open prematurely. Background close still joins its worker before releasing
collection ownership. Public foreground compaction still waits for its reclaim
attempt. Job-pin release and rejected-output cleanup can still perform I/O under
the writer lock; this change only moves the retired queue's I/O. Existing point
store and flush reclamation behavior is unchanged.

## Verification

The independently built candidate passed **81 targeted Mojo tests** (74 existing
plus seven new), **21 related crash tests**, **355 full Python tests** (three
existing warnings), **C ABI/client**, and builds/runs of all **three examples**.
These are not a new full Mojo or full crash suite. Mojo TestSuite times are in ms.

New cases cover publication without immediate deletion, concurrent queue
contents, real shared file leases and retry, partial unlink failure, open failure,
directory replacement, and close/source ownership during blocked I/O. The
publication and close cases fail on the unchanged baseline and pass on the
candidate. The close case blocks reclamation on a FIFO with a bounded child
watchdog: baseline close reaches the 5-second watchdog; candidate finishes in
128.836 ms. Darwin rejects flock on the FIFO, exercising failure restoration;
the test also accepts successful FIFO locking where supported. This is a
correctness/liveness handshake, not a latency acceptance threshold.

Existing checks include background shutdown/backpressure/conflicts, foreground
rebase and publication failure, cross-process file leases, point compaction,
backup and HNSW publication. Crash checks cover temp manifest, manifest fsync/
publication/root swap, compaction cleanup/rebase, point/sparse checkpoint,
HNSW base and backup publication. No new Linux, ASan or GPU gate is claimed.

The binding was compiled from the copied candidate entry and matching include
tree with Mojo 1.0.0 (`ed45d567`), Apple M4 / Metal:4. Saved-package pytest used
`-o pythonpath=` and pixi activation. A child compiler wrapper mapped `-I src`
to the candidate tree and preserved the Metal wrapper. Native worker remained
unchanged. The exact tested source and binary were then promoted.

Python binary SHA-256:
`3610e3022391e9d8731178781e2a002d273ba134055cd259e7939bb1e75b0c1c`.

## Public measurement and decision

The fixed corpora, seeds, filters, K, efs, service boundaries and all three
rotating BAQ/AQB/QBA trials are unchanged. Workers ran serially from closed
clones; no builds, tests or archive compression overlapped benchmarks.

| Workload | Baseline strict pass | Candidate strict pass | Quality evidence |
|---|---:|---:|---|
| Warm | 16/36 | 16/36 | 108 quality cells, 6,912 timed audits, 7,236 exact checks |
| Mixed | 27/36 | 28/36 | 108 quality cells, 7,776 audits, 27 reopens, 18 leases |

Every quality cell passes. Baseline/candidate IDs, score bits, stats and execution
match; warm first queries and warmups match too. Neither run has pass→fail cells.
Both speed assessments are **FAILED**; assessment exit 1 is the correct gate.
The required per-cell Recall@10 ≥ .95, QPS ≥ Qdrant and p95 ≤ Qdrant is unchanged.

Mixed uniform-128 all improves QPS in each trial by 7.5–12.3%, with p95 ratios
0.946–0.959. Mixed real correlated/independent also improves both measures in
every trial. This does **not** establish universal improvement: notably,
uniform-128 selective p95 ratios are **3.063 / 0.310 / 2.632**. All regressions
and slow samples remain in the tables and archive; none is discarded as noise.

Separate instrumented workers confirm the mechanism. In all 33 successful
candidate jobs, publication holds the writer lock for 218–654 µs (32 jobs are
≤442 µs); detached reclamation takes 260–657 µs outside it. The previous baseline
trace measured successful publication at 486–965 µs, including 256–618 µs of
retired-file I/O. These are separate diagnostic runs, not corrected acceptance
latencies. Other publication/capture work can still delay queries.

Adoption rests on removing the measured lock-held I/O, preserved durability and
ownership, demonstrated close progress, and repeatable gains in the affected
mixed workloads without strict pass→fail cells. It does not certify the remaining
performance matrix or explain away per-trial regressions.

## Every candidate/baseline trial

Ratios are trial 0 / 1 / 2. Higher QPS and lower p95 are better.

### Warm

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.036 / 1.011 / 0.985 | 0.901 / 0.992 / 1.072 |
| uniform-128 | correlated | 0.932 / 1.099 / 1.015 | 1.316 / 0.757 / 0.904 |
| uniform-128 | independent | 1.310 / 1.010 / 1.045 | 0.601 / 0.931 / 0.913 |
| uniform-128 | selective | 0.977 / 0.996 / 1.009 | 0.717 / 1.023 / 0.911 |
| uniform-1536 | all | 1.016 / 0.994 / 1.000 | 0.918 / 1.040 / 0.970 |
| uniform-1536 | correlated | 0.997 / 1.005 / 0.982 | 1.014 / 1.005 / 1.006 |
| uniform-1536 | independent | 1.011 / 1.023 / 1.024 | 0.987 / 1.016 / 0.954 |
| uniform-1536 | selective | 0.991 / 1.033 / 1.024 | 1.009 / 0.924 / 0.923 |
| real-1536 | all | 1.015 / 0.999 / 0.992 | 0.945 / 1.003 / 1.013 |
| real-1536 | correlated | 0.984 / 1.009 / 1.059 | 1.008 / 0.977 / 0.914 |
| real-1536 | independent | 1.022 / 0.994 / 1.022 | 0.978 / 0.982 / 0.979 |
| real-1536 | selective | 1.013 / 1.035 / 0.999 | 1.025 / 0.925 / 0.963 |

### Mixed

| Corpus | Mode | QPS ratios | p95 ratios |
|---|---|---|---|
| uniform-128 | all | 1.123 / 1.088 / 1.075 | 0.949 / 0.946 / 0.959 |
| uniform-128 | correlated | 1.056 / 1.284 / 1.057 | 0.996 / 0.514 / 1.045 |
| uniform-128 | independent | 1.290 / 0.984 / 1.089 | 0.502 / 1.076 / 0.998 |
| uniform-128 | selective | 1.154 / 1.472 / 1.111 | 3.063 / 0.310 / 2.632 |
| uniform-1536 | all | 0.980 / 1.053 / 1.016 | 1.012 / 0.753 / 0.997 |
| uniform-1536 | correlated | 0.941 / 1.059 / 0.993 | 1.158 / 0.903 / 0.978 |
| uniform-1536 | independent | 0.974 / 1.064 / 0.979 | 0.988 / 0.851 / 0.994 |
| uniform-1536 | selective | 1.056 / 1.533 / 1.042 | 0.758 / 0.477 / 1.260 |
| real-1536 | all | 1.047 / 0.957 / 1.048 | 0.938 / 1.150 / 0.923 |
| real-1536 | correlated | 1.110 / 1.027 / 1.080 | 0.786 / 0.984 / 0.902 |
| real-1536 | independent | 1.021 / 1.009 / 1.080 | 0.916 / 0.953 / 0.893 |
| real-1536 | selective | 1.002 / 0.984 / 1.045 | 1.193 / 0.973 / 1.256 |

## Evidence and reproduction

[Immutable archive](results/2026-10-03-unlocked-reclamation.json.gz): 244 files,
19,775,762 bytes, SHA-256
`83b77cf3ddec1a91101e560d9566b86dbcf6e0cf7a3430fd272fae17901a0f49`.
Every file hash was decoded and verified. It includes all public trials, raw
samples, assertions, failed baseline checks, logs, copied changed sources,
diagnostic traces, commands, wrappers and input/artifact identities. Baseline
source is `a710aa5`; pre-promotion checkpoint is `6330720`. The archive was frozen
before promotion; its production binary identity describes the old baseline.

The retained tests can be run against current source:

```bash
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_compaction_reclaim_boundary.mojo'
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_retired_batch.mojo'
rtk proxy sh -c 'pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_compaction_reclaim_close.mojo'
```

Archived `validate.py`, `integrate-checks.py`, `measure-warm.py`,
`assess-warm.py` and `measure-mixed.py` record the exact commands and schedule.
Use fresh output directories for new measurements; never rerun source-mutating
setup over existing evidence. `.build` is temporary; the archive is immutable.
Native Linux controlled-memory/nonresident checks remain unavailable because
the user confirmed there is no runner. Concurrent-client/HTTP parity also remains
outstanding.
