# #52: Background worker on the same publication path

Date: 2026-09-26; the third benchmark process was rerun on 2026-09-27. Engine, tests
and bench: the #52 working tree on `feat/48-bounded-generation-head` (on top of
`355e1d5`, which is #51 and the baseline). Platform: Apple M4 Pro, macOS arm64;
Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

- **Rebase publish** (foreground and worker): finish reloads the current manifest
  under the writer lock, as a RocksDB version edit does.
  - The captured segments must still be its leading run: same names, checksums,
    sequence ranges and sparse files. Otherwise the job conflicts, its output is
    removed, and the current manifest is untouched.
  - The new manifest is `[output] + segments appended since capture`, with
    generation current + 1. The last sequence and the HNSW reference come from the
    current manifest. An appended segment that starts at or below H raises instead
    of publishing.
  - The HNSW reference carries over because compaction changes only the layout of
    the same live points. A flush during the build may also have written a newer
    sidecar that the captured reference predates. A reopen maps that sidecar with
    zero graph build distance evaluations.
  - Inputs retire at the generation that was current before the publish, so a
    reader pinned at an intervening flush's generation keeps them.
  - Tombstone elision is unchanged. The output is the oldest run, so an elided
    tombstone has nothing older to expose.
- **Worker compaction** runs the #51 steps with the same functions and the same
  4-attempt budget. Begin and finish take the writer lock; the build does not.
  - Spending the budget is counted (`background_compaction_counts().exhausted`), not
    a failure. A failure closes every operation of the owner, while the next flush
    request simply retries. `compact()` still raises.
  - Close sets a cancel flag under the writer lock before joining. A job that
    finishes after it discards its output and counts as neither a conflict nor a
    failure.
- **Sealed-run merge on the worker**: recording only rolls the head over.
  - At the eighth sealed run the collection requests a worker merge.
  - The worker captures the sealed prefix under the lock, merges it and builds its
    sparse index without the lock. It then replaces only that prefix under a short
    lock; runs sealed meanwhile stay behind it.
  - A merge captured before a publisher reset is dropped.
  - With no worker loaded, the merge runs inline at the eighth run, as in #48.
- **Backpressure**: a write is not admitted while 16 sealed runs exist. It requests
  a merge, sleeps 1 ms without the lock and retries; close or a maintenance failure
  ends the wait. The check runs before the write, so one admitted batch (at most
  65,536 records) can still seal up to 64 runs past the limit. A merge error is a
  maintenance failure: the owner closes and every acknowledged write stays in the
  WAL for the next open.
- **Teardown fix**: dropping an open collection without `close()` joins the worker in
  `MaintenanceController.__deinit__`. Mojo destroys a field after its last use, even
  inside a destructor, so the shared worker state could be freed before the join,
  while a merge was running. The destructor now uses the state once more after the
  join. The bug predates #52; requesting merges during writes widened its window.
  The regression test crashed 4 of 4 times without the fix.
- **Unchanged**: single worker, one pending request, first error reported, close
  joins, output names `*-compact-<T>-<n>.bin` and the orphan rule at open.
  `maintenance()` and the inline flush compaction (no worker loaded) still use the
  locked memtable compaction. No durable format changed.
- **Tests**:
  - `tests/mojo/test_background_publication.mojo` (new, 16 tests) covers:
    - building without the lock;
    - foreground and worker racing on the same inputs;
    - checksum and IO failures;
    - close during a build;
    - budget exhaustion;
    - the eighth-run merge request and prefix-only publish;
    - a merge captured before a reset;
    - the inline merge with no worker;
    - backpressure, including close and merge failure during the wait;
    - drop without `close()`;
    - bounded segments under writes, flushes and the worker.
  - `tests/mojo/test_compaction_publish.mojo` now expects a flush during the build to
    rebase instead of conflict, and checks that the reopen maps the newer HNSW
    sidecar.
  - `tests/crash/test_checkpoint_order.mojo` adds a crash at the rebase publish
    boundary.

  Validation: 700 Mojo, 66 Python and 15 crash tests pass, as do the C ABI tests and
  `build-mojo`. GPU tests were not run, because no device path changed.

## Remaining limits

- **Foreground `compact()` still holds the lock twice for ~32 ms**: once for begin's
  checkpoint and once for finish's index cache publish (#54/#56). The worker's job
  stall below does not include either hold.
- **Worker finish writes no index caches**, as in #51. The caches are keyed by
  generation, so after a worker publish the next open rebuilds them, unless a later
  foreground publish writes them first.
- **`flush()` is the worker path's residual stall.** `flush()` holds the lock for its
  whole ~36 ms call. A job starts right after it, so an upsert queued behind the
  flush also overlaps the job. See the job-only rows below.
- **Other paths still locked**: `maintenance()` and the inline flush compaction (no
  worker loaded) still use the locked memtable compaction.
- **Backpressure overshoot**: one admitted batch can seal up to 64 runs past the
  16-run limit, because admission is checked once per call.
- **Known leak (from #51)**: an unpublished output whose target is at most the
  committed generation stays on disk after a crash between a lost race and its
  discard. The worker now builds outputs too, so this can happen on more paths.

## Method

[Raw results](results/2026-09-26-background-publication.json):
`benchmarks/mojo/compaction_publish_bench.mojo`. It uses the public API, except that
the sealed section reads the merge, rollover and backpressure counters directly.

- **Fixture**: 20,000 points, F32 dimension 128, seeded and flushed, with the default
  config: live HNSW, and the background worker loaded.
- **Writer**: one upsert every 1 ms. It does not catch up in bursts after a stall, so
  both builds write the same volume.
- **Classification**: each upsert's duration is classified by the call it overlapped.
- **Runs**: values are medians of three fresh processes per build, with the process
  range in brackets.
  - Both builds ran alternately from the worktree root, so both loaded the same
    worker library; #52 does not change it.
  - The `355e1d5` build uses a copy of the same source without the lines marked
    `#52 only`, because those counters do not exist there.
  - The run notes below list what happened during the runs.

## Worker compaction stall

Each of 20 rounds sleeps 200 ms, calls `flush()`, then `schedule_maintenance()`, then
waits with `wait_for_maintenance()`. The job window runs from the return of `flush()`
to the return of the wait. An upsert that queued behind `flush()` also overlaps the
job; "job-only" leaves those out.

| Metric (µs) | `355e1d5` | #52 |
|---|---:|---:|
| Upserts overlapping the job | 20 | 1,672 [1,671–1,680] |
| — p50 | 118,207 [115,020–119,558] | 484 [481–484] |
| — p95 | 121,255 [119,646–121,322] | 629 [629–679] |
| — p99 | 122,378 [121,402–125,359] | 34,004 [33,407–35,596] |
| — max | 122,378 [121,402–125,359] | 47,038 [36,618–281,693] |
| Job-only upserts | 0 | 1,652 [1,651–1,660] |
| — p50 | — | 483 [481–483] |
| — p95 | — | 617 [617–652] |
| — p99 | — | 787 [726–1,422] |
| — max | — | 4,064 [1,200–281,693] |
| Quiet upserts | 4,060 [4,027–4,091] | 4,058 [4,055–4,099] |
| — p50 | 491 [489–505] | 501 [498–506] |
| — p99 | 697 [692–767] | 731 [705–859] |
| `flush()` call p50 | 34,958 [34,699–36,079] | 36,580 [35,265–36,651] |
| Job p50 | 82,618 [80,683–82,644] | 83,337 [82,593–83,868] |

What the numbers show:

- **Before, the writer waits for the whole job.** One upsert per round overlaps the
  job. It queued behind `flush()` and then held on through the locked compaction
  (p50 118 ms, which is about the rest of the flush plus the ~83 ms job).
- **After, writes continue through the job.** About 84 upserts overlap each ~83 ms job,
  which matches the 1 ms pace. Job-only p50 and p99 are within about 60 µs of quiet
  upserts.
- **The p99 over all overlapping upserts is `flush()`.** One upsert per round, 1.2% of
  the total, waits behind the ~36 ms `flush()`, so it sets the p99. This is the
  limit listed above, not the job.
- **One outlier.** One #52 process had one 282 ms job-only upsert, in a job that took
  375 ms. The limits of that range come from this single upsert. See the run notes.

A single instrumented process of the #52 build timed each worker phase. Each timer
starts once the writer lock is held.

| Phase (µs) | Holds the writer lock | Count | Median | Max |
|---|---|---:|---:|---:|
| Compaction begin (capture) | yes | 71 | 45 | 96 |
| Compaction build | no | 71 | 85,559 | 92,849 |
| Compaction finish (publish; published jobs only) | yes | 56 | 566 | 1,179 |
| Merge capture | yes | 3 | 1 | 16 |
| Merge build | no | 3 | 4,316 | 4,476 |
| Merge publish | yes | 3 | 1,584 | 1,703 |

The worker's begin only captures inputs and does no checkpoint. Its finish writes no
index caches. So neither has the two ~32 ms holds that foreground `compact()` still
has.

## Sealed-run merge stall

The writer upserts `3 × 8 × HEAD_MAX_POINTS` records plus half a head at 1 ms pace, so
the head rolls over 24 times and 3 merges run. An upsert is classified by the stats
counter that changed during it:

- "saw a merge publish": the merge counter changed;
- "saw a rollover": the rollover counter changed;
- "other": neither changed.

| Metric (µs) | `355e1d5` | #52 |
|---|---:|---:|
| All upserts | 25,088 | 25,088 |
| — p50 | 621 [620–683] | 679 [620–685] |
| — p99 | 1,082 [1,048–1,166] | 1,063 [1,033–1,068] |
| — max | 35,834 [9,640–58,797] | 14,654 [5,925–63,301] |
| Upserts that saw a merge publish | 3 | 3 |
| — p50 | 5,948 [5,592–6,247] | 1,311 [877–2,014] |
| — max | 6,683 [6,474–8,564] | 2,055 [1,644–2,298] |
| Upserts that saw a rollover | 21 | 24 |
| — p50 | 774 [719–844] | 853 [808–867] |
| — max | 1,105 [1,048–1,973] | 1,269 [1,081–1,549] |
| Merges / rollovers | 3 / 24 | 3 / 24 |
| Backpressure waits | — | 0 |

- **Before, the upsert that sealed the eighth run did the merge** (p50 5.9 ms).
- **After, the worker builds the merge**, and the writer waits at most for the ~1.6 ms
  publish hold (p50 1.3 ms, max 2.1 ms). All 24 rollovers are now plain rollovers,
  because none of them runs a merge.
- **No backpressure wait** occurred at this pace, since each merge finished long before
  eight more runs sealed. The tests cover the wait itself.
- **The maxima are not merge stalls.** They fall on "other" upserts in both builds and
  vary by process.

## Foreground `compact()` stall

This is the #51 fixture: 20 rounds of sleep 200 ms, `flush()`, `compact()`. #52 does
not change this path apart from the rebase, and the numbers match.

| Metric (µs) | `355e1d5` | #52 |
|---|---:|---:|
| Upserts overlapping `compact()` | 1,697 [1,641–1,709] | 1,684 [1,681–1,697] |
| — p50 | 484 [480–511] | 485 [484–487] |
| — p99 | 66,979 [63,316–67,345] | 66,531 [64,130–67,495] |
| Compact-only upserts, p99 | 32,810 [30,785–32,982] | 32,659 [31,731–32,885] |
| `compact()` call p50 | 149,150 [147,799–149,386] | 148,365 [145,553–148,595] |

## Conflict rate

`compact()` rounds (sleep 200 ms, then `compact()`, 20 rounds) race a writer paced at
1 ms that also flushes once per period, and a flush at four segments hands work to the
worker.

- **Attempts** are jobs that captured inputs.
- **Exhausted calls** are `compact()` calls that raised after 4 attempts. **Worker
  exhausted** counts worker jobs that spent the budget.
- **Max segments** is the largest manifest the writer saw after a flush.

| Flush period | Build | Flushes | Foreground attempts | Foreground conflicts | Exhausted calls (of 20) | Worker attempts | Worker conflicts | Worker exhausted | Max segments |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 ms | `355e1d5` | 114 [105–123] | 42 [36–47] | 42 [36–47] | 2 [2–6] | — | — | — | 6 |
| 50 ms | #52 | 91 [81–93] | 25 [20–26] | 5 [0–6] | 0 | 43 [41–44] | 17 [17–20] | 0 | 7 [6–7] |
| 200 ms | `355e1d5` | 40 [40–43] | 39 [39–40] | 19 [19–21] | 0 | — | — | — | 4 [4–6] |
| 200 ms | #52 | 30 [30–32] | 20 [20–21] | 0 [0–1] | 0 | 0 [0–4] | 0 [0–2] | 0 | 4 [4–6] |
| 1000 ms | `355e1d5` | 7 [6–7] | 22 [21–22] | 2 [1–2] | 0 | — | — | — | 3 |
| 1000 ms | #52 | 6 | 20 | 0 | 0 | 0 | 0 | 0 | 3 |

- **A flush no longer causes a conflict.** A flush only appends segments, and the
  rebase keeps them.
  - At 200 and 1000 ms, foreground conflicts fall from 19 and 2 to 0.
  - At 50 ms, every foreground attempt conflicted before, and 2 [2–6] of 20 calls
    exhausted the budget. After, no call or job exhausts it.
- **The remaining conflicts are compaction against compaction.** The foreground and the
  worker capture the same leading run, and whichever publishes second finds its
  inputs replaced. With a flush every 50 ms, the worker runs about twice per foreground
  call and loses that race in 17 of about 43 jobs.
- **Segments stay bounded**: 7 at most while flushing every 50 ms, against 6 before,
  when the worker compacted under the lock.
- **There are fewer flushes after** because the section is shorter. Each round is
  200 ms plus one `compact()` call, and with fewer retries the 20 rounds end sooner.
- **The `355e1d5` numbers at 50 ms differ from the #51 report** (2 instead of 20
  exhausted calls, 42 instead of 80 attempts), even though it is the same engine. This
  bench now runs the worker and sealed sections in the same process first, and the
  50 ms case depends on how the foreground and the locked worker interleave. I did not
  isolate the cause, so the comparison uses only this batch.

## Run notes

- **Process 3 was rerun.** The first process 3 of each build overlapped a macOS
  clamshell sleep (lid closed at 18:27:16 on 2026-09-26) and was discarded.
  - The rerun ran on 2026-09-27 from 00:39:52 to 00:46:01 under `caffeinate -dimsu`.
    `pmset -g log` shows no sleep or wake in that window.
  - Processes 1 and 2 ran on AC power. The source switched to battery at 00:41:33,
    during the `355e1d5` process 3, so the #52 process 3 and the phase probe ran on
    battery.
  - The quiet upsert percentiles of process 3 fall within the spread of processes
    1 and 2.
- **The 282 ms outlier** is in #52 process 2: one job-only upsert, in a 375 ms job.
  - The same process also had the highest `flush()` maximum (56.6 ms) and sealed
    maximum (63.3 ms).
  - The probe's finish holds peaked at 1.2 ms across 56 publishes, so a normal finish
    does not explain it. A slow fsync inside the finish hold, or the process being
    descheduled, would.
  - I did not reproduce it or isolate the cause.
- **Two unreproduced failures in an earlier, unofficial batch** of the #52 build:
  - One process stopped producing output after the worker-stall section. The watchdog
    killed it after 600 s, without a stack sample.
  - Another raised `conflict bench task failed` at the 50 ms period, while a
    `mojo build` ran alongside. The bench swallowed the underlying error then; it now
    prints it.

  Since then, all of the following exited 0:
  - 11 stress runs next to 12 CPU burners;
  - the 3 official processes;
  - the sleep-interrupted process 3.

  A review of close and join found no deadlock path. Both failures remain open.

## Reproduce

```sh
pixi run build-mojo
mkdir -p .build/background-publication-52
pixi run mojo build -I src benchmarks/mojo/compaction_publish_bench.mojo -o .build/background-publication-52/after
.build/background-publication-52/after
```

Run from the repository root, so the worker library at
`.build/native/libakasha_worker.so` loads. For the baseline, delete the lines marked
`#52 only`. Then build that copy against a checkout of `355e1d5` (`-I <checkout>/src`),
and run it from the same root.
