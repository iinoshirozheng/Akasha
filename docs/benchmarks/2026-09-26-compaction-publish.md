# #51: Compaction build without the writer lock, conditional publish

Date: 2026-09-26. Engine, tests and bench: the #51 working tree on
`feat/48-bounded-generation-head` (on top of `e47267b`).
Platform: Apple M4 Pro, macOS arm64; Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.

## Implemented boundary

- **Three steps**: foreground `compact()` takes the writer lock only for the first
  and the last step.
  - **Begin** (locked) checkpoints the WAL tail. It then captures the manifest with
    its exact bytes and pins generation G.
  - **Build** (unlocked) merges the captured segments. It writes
    `segment-compact-<G+1>-<n>.bin` and `sparse-compact-<G+1>-<n>.bin`, each created
    with `O_CREAT|O_EXCL`, so an output never replaces an existing file. Both files
    are fsynced and the directory is synced. On failure, build removes only its own
    two files and drops the pin.
  - **Finish** (locked) drops the job pin. If the current manifest bytes still equal
    the captured ones, it publishes G+1 with last sequence H. The durable manifest
    comes first, then the read root and the index caches. The inputs go to lease-aware
    retirement at G.
- **Writes during build** stay in the memtable and WAL, and publish does not rotate
  the WAL. So every sequence above H survives.
- **Conflict**: when the manifest changed, the output is removed and `compact()`
  recaptures from the newer manifest. After 4 attempts it raises
  "compaction retry budget exhausted". `compaction_attempts()` and
  `compaction_conflicts()` count jobs.
- **Close and restart**: a close before finish discards the output. Open removes job
  outputs whose target generation is above the committed one. A published or pinned
  file never matches that rule.
- **Background worker**: its `compact_committed_segments` shares the capture, build
  and publish functions, but still runs all three under its lock (#52 changes that).
  Its outputs now use the same `*-compact-*` names.
- **Formats**: no durable format changed; the manifest already stores free-form file
  names.
- **Tests**: `tests/mojo/test_compaction_publish.mojo` has 11 cases:
  - concurrent writes;
  - a conflict that keeps the newer manifest;
  - the retry budget;
  - pinned and leased inputs;
  - old snapshots;
  - checksum, IO and cancel failures;
  - restart cleanup.

  `tests/crash/test_checkpoint_order.mojo` adds 5 crash boundaries: output fsync,
  manifest temporary, manifest publish, root swap and cleanup. Validation: 684 Mojo,
  66 Python and 14 crash tests pass, as do the C ABI tests and `build-mojo`. GPU tests
  were not run, because no device path changed.

## Remaining limits

- **Index caches under the lock**: an instrumented copy measured two ~32 ms lock
  holds per `compact()`:
  - begin's checkpoint (median 31.8 ms), which writes the HNSW snapshot and the
    metadata and HNSW caches;
  - finish's cache publish (median 32.1 ms).

  Capture (0.05 ms), manifest publish (0.24 ms) and retirement (0.29 ms) are
  negligible. These two holds set the p99 below and belong to #54/#56.
- **Flushes faster than a build**: the strict byte compare loses to every flush. With
  a flush every 50 ms, shorter than one ~150 ms build, all 20 foreground calls
  exhausted the budget. The data still compacted, because flush hands work to the
  background worker at 4 segments, and in #51 that worker still merges under the lock.
  Once #52 moves the worker outside the lock, it faces the same race. #52 then needs a
  publish that keeps deltas appended after capture (all above H) instead of failing
  on them, or backpressure on flush.
- **Other paths still locked**: `maintenance()` and the inline flush compaction (when
  no worker is loaded) still use the locked memtable compaction.
- **Known leak**: an unpublished output whose target is at most the committed
  generation stays on disk. This needs a crash between a lost race and its discard.
- **Double manifest read**: capture reads `manifest.bin` twice under the lock; this is
  inside the 0.05 ms above.

## Writer stall

[Raw results](results/2026-09-26-compaction-publish.json):
`benchmarks/mojo/compaction_publish_bench.mojo`, public API only.

The fixture is 20,000 points with F32 dimension 128, seeded and flushed, with the
default config: live HNSW, and the background worker loaded.

- A writer upserts once per 1 ms. It does not catch up in bursts after a stall, so
  both revisions write the same volume.
- The other task runs 20 rounds of: sleep 200 ms, `flush()`, `compact()`.
- Each upsert call's duration is classified by what it overlapped: a `compact()` call,
  only a `flush()`, or neither ("quiet").

Values are medians of three fresh processes, with the process range in brackets. The
`e47267b` build uses a stall-only copy of the same source, because the conflict
counters do not exist there.

| Metric (µs) | `e47267b` | #51 |
|---|---:|---:|
| Upserts overlapping `compact()` | 20 [20–20] | 1,731 [1,714–1,775] |
| — p50 | 133,117 [131,723–168,066] | 494 [482–505] |
| — p95 | 138,613 [136,115–198,937] | 686 [641–1,039] |
| — p99 | 147,684 [138,744–218,224] | 67,472 [66,568–67,548] |
| — max | 147,684 [138,744–218,224] | 72,127 [71,992–161,472] |
| Quiet upserts | 4,018 [3,486–4,020] | 4,005 [3,867–4,056] |
| — p50 | 499 [493–606] | 506 [503–512] |
| — p99 | 739 [710–1,897] | 729 [720–1,384] |
| `compact()` call p50 | 96,829 [95,724–124,020] | 151,462 [149,409–151,662] |
| `compact()` call max | 103,981 [99,339–153,783] | 155,955 [154,370–356,081] |

What the numbers show:

- **Before, the writer waits for the whole compaction.** Exactly one upsert per round
  overlaps `compact()`, and it waits the full call (p50 133 ms).
- **After, writes continue.** About 87 upserts overlap each `compact()`. That matches
  the 1 ms pace over the ~86 ms of the call that holds no lock. p50 and p95 match
  quiet upserts.
- **The p99 is the locked phases.** About 2 of the ~87 upserts per round wait for a
  locked phase, and p99 lands on them. The ~67 ms value exceeds any single ~32 ms hold.
  It is consistent with an upsert waiting through `flush()` and then begin's
  checkpoint: the spin lock is unfair, and the compacting task reacquires it right
  after `flush()`.
- **Quiet writes are unchanged**, so #51 adds no cost outside compaction.
- **`compact()` itself takes longer** (p50 97 → 151 ms): it checkpoints first and
  shares the machine with the writer. Only the caller of `compact()` waits on that.

## Conflict rate

`compact()` rounds (sleep 200 ms, then `compact()`, 20 rounds) race a writer paced at
1 ms that also flushes once per period. Every flush publishes a newer manifest.
Attempts are jobs that captured inputs. "Exhausted" counts `compact()` calls that
raised after 4 attempts. Values are medians and ranges of the same three processes.

| Flush period | Flushes | Attempts | Conflicts | Rate | Exhausted calls (of 20) |
|---|---:|---:|---:|---:|---:|
| 50 ms | 152 [142–166] | 80 [78–80] | 80 [78–80] | 100% | 20 [19–20] |
| 200 ms | 40 [40–57] | 39 [39–53] | 19 [19–37] | 49% [49–70%] | 0 [0–4] |
| 1000 ms | 7 [7–7] | 22 [21–22] | 2 [1–2] | 9% [5–9%] | 0 [0–0] |

A conflict needs a flush to land inside one ~150 ms build. The rate therefore falls
with the flush period, and it reaches the retry budget once flushes come faster than
builds. See the limit above.

Reproduce:

```sh
mkdir -p .build/compaction-publish-51
pixi run mojo build -I src benchmarks/mojo/compaction_publish_bench.mojo -o .build/compaction-publish-51/after
.build/compaction-publish-51/after
```

Run from the repository root, so the maintenance worker library at
`.build/native/libakasha_worker.so` loads (`pixi run build-mojo` builds it). For the
baseline, delete `bench_conflict` and call only `bench_stall()` from `main`. Then
build that copy against a checkout of `e47267b` (`-I <checkout>/src`).
