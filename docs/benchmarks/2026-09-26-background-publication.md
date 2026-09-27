# #52: Background worker on the same publication path

Date: 2026-09-26; the benchmark numbers are from a rerun on 2026-09-27. Engine,
tests and bench: the #52 working tree on `feat/48-bounded-generation-head` (on top of
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
- **Level-zero stall**: a flush that finds eight L0 segments
  (`LEVEL_ZERO_SEGMENT_LIMIT`, twice the flush policy's trigger of four) does not
  write. It requests a worker compaction, sleeps 1 ms without the lock and retries, as
  a RocksDB level-zero stop does. `backup_to()` flushes first, so it waits the same way.
  - Close or a maintenance failure ends the wait. The unflushed writes are
    acknowledged and stay in the WAL for the next open.
  - Without the stall, nothing bounded L0 while flushes outpaced the worker. The
    writer lock is an unfair spin lock, so a tight upsert and flush loop could keep a
    finished job from publishing, and the bounded-segments test failed intermittently.
  - With no worker loaded, a flush compacts inline at four and never waits.
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
  - `tests/mojo/test_background_publication.mojo` (new, 19 tests) covers:
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
    - the flush stall at eight L0 segments, including close and compaction failure
      during it;
    - bounded segments under writes, flushes and the worker.
  - `tests/mojo/test_compaction_publish.mojo` now expects a flush during the build to
    rebase instead of conflict, and checks that the reopen maps the newer HNSW
    sidecar.
  - `tests/crash/test_checkpoint_order.mojo` adds a crash at the rebase publish
    boundary.

  Validation: 703 Mojo, 66 Python and 15 crash tests pass, as do the C ABI tests and
  `build-mojo`. GPU tests were not run, because no device path changed.

## Remaining limits

- **Foreground `compact()` still holds the lock twice for ~32 ms**: once for begin's
  checkpoint and once for finish's index cache publish (#54/#56). The worker's job
  stall below does not include either hold.
- **Worker finish writes no index caches**, as in #51. The caches are keyed by
  generation, so after a worker publish the next open rebuilds them, unless a later
  foreground publish writes them first.
- **`flush()` is the worker path's residual stall.** `flush()` holds the lock for its
  whole ~35 ms call. A job starts right after it, so an upsert queued behind the
  flush also overlaps the job. See the job-only rows below.
- **Other paths still locked**: `maintenance()` and the inline flush compaction (no
  worker loaded) still use the locked memtable compaction.
- **Backpressure overshoot**: one admitted batch can seal up to 64 runs past the
  16-run limit, because admission is checked once per call.
- **A stalled flush waits for a whole compaction.** Every job rewrites the whole
  manifest into one base (#51), so the wait is one full build. RocksDB slows writes
  before it stops them; AkashaDB has only the stop.
- **Each upsert appends and fsyncs the WAL under the writer lock.** A slow device
  write stalls the writer for its whole length, whether or not a job runs; the
  longest measured was 183 ms. A running job adds its own writes to the device. See
  the upsert I/O stalls below.
- **Foreground `compact()` and the worker still race for the same inputs.** Under
  CPU load, with a flush every 50 ms, 4–11 of 20 foreground calls spent the retry
  budget (17–20 before #52); the worker never did. RocksDB marks the input files of a
  running compaction as being compacted, so no second compaction picks them, and
  `exclusive_manual_compaction` keeps automatic compactions out of a manual one.
  AkashaDB has neither. See the conflict under CPU load below.
- **Known leak (from #51)**: an unpublished output whose target is at most the
  committed generation stays on disk after a crash between a lost race and its
  discard. The worker now builds outputs too, so this can happen on more paths.

## Method

[Raw results](results/2026-09-26-background-publication.json):
`benchmarks/mojo/compaction_publish_bench.mojo`. It uses the public API, except that
the sealed section reads the merge, rollover and backpressure counters directly, and
the conflict section reads the manifest under the writer lock after each flush.

- **Fixture**: 20,000 points, F32 dimension 128, seeded and flushed, with the default
  config: live HNSW, and the background worker loaded.
- **Writer**: one upsert every 1 ms. It does not catch up in bursts after a stall, so
  both builds write the same volume.
- **Classification**: each upsert's duration is classified by the call it overlapped.
- **Runs**: values are medians of three fresh processes per build, with the process
  range in brackets.
  - All six processes ran in one batch on 2026-09-27, 01:24:57 to 01:44:04,
    alternating the builds, from the worktree root, under `caffeinate -dimsu`, on
    battery power. `pmset -g log` shows no sleep, wake or power source change in that
    window. From 01:35:25 a browser held a display-sleep assertion, as video
    playback does. That overlaps the last process of each build and the probe.
  - Both builds loaded the same worker library; #52 does not change it.
  - The `355e1d5` build uses a copy of the same source without the lines marked
    `#52 only`, because those counters do not exist there.
  - This batch replaces one from 2026-09-26 that mixed AC and battery power and lost a
    process to a lid-close sleep. The run notes compare the two.

## Worker compaction stall

Each of 20 rounds sleeps 200 ms, calls `flush()`, then `schedule_maintenance()`, then
waits with `wait_for_maintenance()`. The job window runs from the return of `flush()`
to the return of the wait. An upsert that queued behind `flush()` also overlaps the
job; "job-only" leaves those out.

| Metric (µs) | `355e1d5` | #52 |
|---|---:|---:|
| Upserts overlapping the job | 22 [20–22] | 1,660 [1,620–1,695] |
| — p50 | 120,011 [118,621–120,566] | 481 [480–500] |
| — p95 | 123,867 [121,401–128,567] | 650 [636–725] |
| — p99 | 124,571 [121,458–136,243] | 34,449 [34,290–34,496] |
| — max | 124,571 [121,458–136,243] | 37,812 [37,227–105,732] |
| Job-only upserts | 2 [0–2] | 1,640 [1,600–1,675] |
| — p50 | — | 481 [480–499] |
| — p99 | — | 1,060 [733–1,992] |
| — max | 86,483 and 83,602 | 30,385 [1,201–105,732] |
| Quiet upserts | 3,965 [3,940–4,049] | 4,035 [3,925–4,049] |
| — p50 | 494 [489–495] | 499 [498–500] |
| — p99 | 905 [716–963] | 731 [723–842] |
| `flush()` call p50 | 34,886 [34,741–35,010] | 35,220 [35,017–35,839] |
| Job p50 | 84,989 [83,538–86,230] | 83,956 [83,752–85,455] |
| Job max | 87,235 [86,509–101,451] | 142,275 [85,122–190,321] |

What the numbers show:

- **Before, the writer waits for the whole job.** About one upsert per round overlaps
  the job. It queued behind `flush()` and then held on through the locked compaction
  (p50 120 ms, which is about the rest of the flush plus the ~85 ms job). Two
  processes each had two upserts that started after `flush()` returned and still
  waited out the locked job; the third had none. The max row gives the two
  processes' values.
- **After, writes continue through the job.** About 83 upserts overlap each ~84 ms job,
  which matches the 1 ms pace. Job-only p50 is 18 µs below quiet upserts, and job-only
  p99 is 0.3 ms above.
- **The p99 over all overlapping upserts is `flush()`.** One upsert per round, 1.2% of
  the total, waits behind the ~35 ms `flush()`, so it sets the p99. This is the
  limit listed above, not the job.
- **The job-only maxima are I/O stalls, not lock waits.** They follow the slowest job
  of the same process: a job max of 85 ms comes with a job-only max of 1.2 ms, 142 ms
  with 30 ms, and 190 ms with 106 ms. The next section shows where that time goes.

A single instrumented process of the #52 build timed each worker phase. Each timer
starts once the writer lock is held.

| Phase (µs) | Holds the writer lock | Count | Median | Max |
|---|---|---:|---:|---:|
| Compaction begin (capture) | yes | 61 | 43 | 63 |
| Compaction build | no | 61 | 84,839 | 286,177 |
| Compaction finish (publish; published jobs only) | yes | 41 | 555 | 5,179 |
| Merge capture | yes | 3 | <1 | 3 |
| Merge build | no | 3 | 3,571 | 3,919 |
| Merge publish | yes | 3 | 1,017 | 1,080 |

The worker's begin only captures inputs and does no checkpoint. Its finish writes no
index caches. So neither has the two ~32 ms holds that foreground `compact()` still
has.

## Upsert I/O stalls

Every upsert appends its record to the WAL and fsyncs it while it holds the writer
lock. When the device is slow, that append is slow, and the writer stalls with no
compaction lock involved.

- **The probe process above** had one job-only upsert of 168.6 ms. No locked worker
  phase in that process took more than 5.2 ms. The unlocked build that ran at the
  same time took 286 ms instead of ~85 ms.
- **A timeline probe** used a scratch copy of the #52 tree, not committed, and ran only
  the worker section:
  - Across 15 processes (300 jobs), every upsert that waited for the lock during a
    job waited for `flush()` (~35 ms). Finish holds had a median of 0.55 ms and a max
    of 8.3 ms, and begin holds a max of 0.71 ms.
  - The longest stall was an upsert that held the lock for 184 ms. Of that, 183.4 ms
    was the WAL fsync. No job or flush ran at the time.
  - In 6 more processes, each of the 6 upserts over 10 ms spent 17–112 ms of its time
    in the WAL append. The rest of the upsert took under 1 ms.
  - In 16 more processes, the 2 WAL appends over 10 ms were both in `write` (11 ms).
- **The baseline has the same stalls outside compaction.** In `355e1d5` processes,
  quiet upserts in the foreground section peaked at 114 ms, and "other" upserts in the
  sealed section peaked at 73 ms. They show up in the job-only rows only in #52,
  because only #52 runs upserts during the job.

So #52 adds no lock hold here. Upserts now run while the build writes its output, and
the build's writes compete with them on the same device. See the limit above.

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
| — p50 | 524 [524–650] | 633 [517–640] |
| — p99 | 933 [869–1,052] | 1,022 [837–1,076] |
| — max | 50,963 [11,570–73,337] | 62,964 [12,487–95,781] |
| Upserts that saw a merge publish | 3 | 3 |
| — p50 | 5,121 [4,608–6,807] | 1,225 [1,109–1,290] |
| — max | 6,484 [5,383–7,268] | 1,417 [1,110–1,557] |
| Upserts that saw a rollover | 21 | 24 |
| — p50 | 667 [659–844] | 808 [670–814] |
| — max | 1,294 [1,209–1,342] | 1,067 [1,035–1,291] |
| Merges / rollovers | 3 / 24 | 3 / 24 |
| Backpressure waits | — | 0 |

- **Before, the upsert that sealed the eighth run did the merge** (p50 5.1 ms).
- **After, the worker builds the merge**, and the writer waits at most for the ~1 ms
  publish hold (p50 1.2 ms, max 1.6 ms). All 24 rollovers are now plain rollovers,
  because none of them runs a merge.
- **No backpressure wait** occurred at this pace, since each merge finished long before
  eight more runs sealed. The tests cover the wait itself.
- **The maxima are not merge stalls.** They fall on "other" upserts in both builds and
  vary by process. They are the I/O stalls described above.

## Foreground `compact()` stall

This is the #51 fixture: 20 rounds of sleep 200 ms, `flush()`, `compact()`. #52 does
not change this path apart from the rebase, and the numbers match.

| Metric (µs) | `355e1d5` | #52 |
|---|---:|---:|
| Upserts overlapping `compact()` | 1,737 [1,720–1,745] | 1,700 [1,699–1,701] |
| — p50 | 506 [484–515] | 488 [481–494] |
| — p99 | 67,222 [66,670–67,682] | 66,373 [65,782–67,126] |
| Compact-only upserts, p99 | 33,366 [33,123–33,523] | 32,927 [32,792–33,324] |
| `compact()` call p50 | 151,738 [150,538–153,082] | 150,074 [149,012–151,212] |

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
| 50 ms | `355e1d5` | 137 [136–147] | 73 [72–80] | 73 [72–80] | 18 [17–20] | — | — | — | 6 |
| 50 ms | #52 | 81 | 20 | 0 | 0 | 41 | 20 | 0 | 6 |
| 200 ms | `355e1d5` | 40 | 39 | 19 | 0 | — | — | — | 4 |
| 200 ms | #52 | 30 | 20 | 0 | 0 | 0 | 0 | 0 | 4 |
| 1000 ms | `355e1d5` | 7 | 22 | 2 | 0 | — | — | — | 3 |
| 1000 ms | #52 | 6 | 20 | 0 | 0 | 0 | 0 | 0 | 3 |

- **A flush no longer causes a conflict.** A flush only appends segments, and the
  rebase keeps them.
  - At 200 and 1000 ms, foreground conflicts fall from 19 and 2 to 0.
  - At 50 ms, every foreground attempt conflicted before, and 18 [17–20] of 20 calls
    exhausted the budget. After, each of the 20 calls published on its first attempt
    in these processes. That depends on timing, and it does not hold under CPU load
    (next section).
- **The remaining conflicts are compaction against compaction.** The foreground and the
  worker capture the same leading run, and whichever publishes second finds its
  inputs replaced. With a flush every 50 ms, 20 of 41 worker jobs lost that race in
  each process, one per foreground call.
- **Segments stay bounded**: 6 at most in both builds. A flush stalls only at a base
  plus eight L0 segments, so the level-zero stall never engaged here.
- **There are fewer flushes after** because the section is shorter. Each round is
  200 ms plus one `compact()` call, and with no retries the 20 rounds end sooner.
- **The `355e1d5` numbers match the #51 report.**
  - The #51 bench, built against `355e1d5` and run three times in the same batch, gave
    80 attempts, 80 conflicts and 20 exhausted calls at 50 ms in every process, the
    same as the #51 report (20 [19–20]).
  - This bench runs the worker and sealed sections first and reads the manifest
    after each flush. It gives 18 [17–20].
  - A baseline call ends without exhausting only when a retry's checkpoint leaves a
    single segment: the locked worker has just compacted everything and no write has
    landed since. The next section shows how the bench's own locking changes that.

## Conflict under CPU load

These are fresh processes that run only the 50 ms case, eight times each, so each
case is 20 `compact()` calls. "Busy" runs 12 shell busy loops next to the process.
The values are ranges over all cases.

- **`1be5483`** is the committed #52, before the level-zero stall.
- **Manifest read** is how the bench's writer reads the segment count after each
  flush. The committed bench read it without the writer lock. This bench takes the
  lock (see the run notes).

| Build | Manifest read | Load | Cases | Foreground conflicts / attempts | Exhausted calls (of 20) | Worker exhausted | Max segments |
|---|---|---|---:|---|---:|---:|---:|
| `355e1d5` | locked | none | 8 | all of 76–80 | 18–20 | — | 6 |
| `355e1d5` | locked | busy | 16 | all of 74–80 | 17–20 | — | 9 |
| `355e1d5` | unlocked | none | 16 | all of 24–43 | 0–5 | — | 6 |
| #52 | locked | none | 16 | 0–3 of 20–23 | 0 | 0 | 7 |
| #52 | locked | busy | 16 | 29–48 of 45–57 | 4–11 | 0 | 9 |
| `1be5483` | unlocked | none | 16 | 3–23 of 23–43 | 0–1 | 0 | 7 |
| `1be5483` | unlocked | busy | 9 | 31–45 of 46–58 | 5–8 | 0 | 8 |
| `1be5483` | locked | none | 16 | 0 of 20 | 0 | 0 | 6 |

- **Under load, foreground calls still exhaust the budget.** With the busy loops,
  4–11 of 20 calls per case spent all four attempts, against 17–20 before. The
  worker never exhausted its budget.
  - A foreground call and a worker job both rewrite the whole manifest, so
    whichever publishes second conflicts.
  - Under load every build takes longer, so a worker job is in flight for more of
    the time, and more of a call's four attempts overlap one.
  - The worker's retries meet at most the one foreground call of each 200 ms round.
  - This is listed as a limit above.
- **Without load, the count depends on how the bench itself takes the lock.**
  - With the same `1be5483` engine, an unlocked read after each flush gives 3–23
    foreground conflicts per case, and a locked read gives 0.
  - The level-zero stall does not explain the difference: at no load it never
    engaged (7 segments at most).
  - The likely cause is that holding the lock after each flush changes which thread
    wins the unfair spin lock next, and so which job publishes first.
- **The baseline has the same sensitivity.** With `355e1d5`, every attempt still
  conflicts, but the unlocked read leaves 0–5 exhausted calls per case against 18–20
  with the locked read. These two processes ran on AC power (see the run notes).
- **Segments stayed bounded under load**: at most 9 in #52, the base plus eight L0
  segments at which a flush stalls.

## Run notes

- **Earlier batch (2026-09-26, replaced).** It gave the same picture, with these
  deviations. This batch was run to remove them:
  - Its process 3 overlapped a lid-close sleep and was rerun. Processes 1 and 2 ran on
    AC power and the rerun on battery. This batch ran entirely on battery with no
    sleep.
  - Its `355e1d5` processes exhausted only 2 [2–6] of 20 calls at 50 ms, with 42
    [36–47] attempts. That batch ran the committed bench, which read the manifest
    after each flush without the writer lock. With that read, `355e1d5` gives 0–5
    exhausted calls per case (see the conflict under CPU load), so the bench caused
    the difference, not the engine.
  - One #52 process had a 282 ms job-only upsert in a 375 ms job. This is the I/O
    stall above; this batch's largest was 106 ms in a 190 ms job.
- **Two failures in an unofficial run of the committed `1be5483` bench** (the
  official processes above all exited 0):
  - `conflict bench task failed` at the 50 ms period. **Reproduced; a bench bug.**
    - The writer task printed `manifest references a missing segment` just before
      it.
    - The committed bench read the manifest after each flush without the writer
      lock. A worker publish between that read and the segment file check reclaimed
      a segment the read manifest still listed.
    - The engine reads the manifest only at open or under the writer lock, so only
      the bench was affected. This bench takes the lock for the read.
    - Committed bench, conflict case only, 8 cases per process: all 16 cases with no
      load passed. With the busy loops, one process passed its 8 cases and the other
      failed in its second.
    - This bench raised no error in 32 cases (16 with no load, 16 busy) or in the
      official processes.
  - One process stopped producing output after the worker-stall section. **Not
    reproduced; cause unknown.**
    - Ten fresh processes each ran the worker section and then the sealed section six
      times: five of the committed `1be5483` build and five of this tree.
    - Per build, two ran with no load, two with the busy loops, and one beside a
      `mojo build` of the bench.
    - All 70 sections finished, with no error and no backpressure wait. A process
      whose output stopped for 180 s would have been sampled and killed.
- **Repro run conditions.**
  - The conflict repro processes ran from 01:58 to 02:46 on 2026-09-27, on battery,
    with no sleep.
  - At 03:03 the machine went into low-battery sleep, during a busy `1be5483` sealed
    process, and woke at 10:18 on AC power. That process resumed and finished
    normally.
  - The rest of the hang search and the `355e1d5` unlocked-read row ran on AC after
    10:18.

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

For the conflict under CPU load, replace the sections in `main` with eight calls of
`bench_conflict(50)`. Start each process fresh, and for "busy" run 12 shell loops
`while :; do :; done` beside it. For the unlocked manifest read, move the writer's
`load_manifest` call after a flush out of its `BlockingScopedLock` block.
