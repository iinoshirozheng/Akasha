# Capture shared read owners and prepare replacements from immutable output

The isolated candidate removes point traversal and replacement projection from
the first writer-lock section. It captures run references and legacy version
context, then constructs replacement entries from validated immutable compaction
output outside writer. Final live-authority checks remain locked. This extends
the [read-preparation layer](2026-10-20-immutable-point-read-preparation.md).
Fresh strict quality-plus-speed passes are 23/36 production,
13/36 prior candidate and 16/36 candidate.
Production remains `a6822c3`; the candidate is not adopted and M5/M6 remain open.

## Reference and implementation

The pinned reference remains Qdrant commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d`, particularly
[`finish_optimization`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478)
and its [separate holder/update locks](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs#L18).
Expensive preparation precedes final publication. Akasha applies that boundary
to descriptor construction; its ANN queries still share the writer lock with
publication, so this is not full read/update lock separation.

Four files change from the verified parent. `capture_live_read_owners` now
retains shared immutable run references and a scalar legacy cutover only. It no
longer validates/traverses the mutable point table or projects replacement rows.
`PreparedCompactionOwners.build_read_owners` uses the already decoded, validated
output to prepare runs outside writer:

- Typed points use the existing `MemTableEntry.from_point` owner-sharing
  conversion. Replacement matching still requires the same point/document
  versions, field layout, kinds, scalar types and byte counts.
- Legacy files use document versions, while migrated points are anchored at
  catalog cutover. The builder projects dense owners onto matching immutable
  cutover rows and retains each row's sparse and payload owners. Later typed
  versions stay unchanged. A committed prefix older than cutover cannot replace
  newer recovered WAL state.
- Finalization rechecks the captured run chain, complete live point/projection
  identity, catalog and versions, then stages the current bounded head. Existing
  conflict retries, cancellation/error cleanup and deferred owner release remain.
  The former staging helper used by both capture and publication is removed;
  final validation now resides at its sole call site.

Foreground and background callers use the same new preparation method. No
public API, v4/v5 bytes, numeric arithmetic, threshold, four-delta compaction
selection or durability fence changes. Run tables still allocate during copying;
this change does not establish nonresident capacity acceptance.

## Validation and retained failure

Mojo `1.0.0 (ed45d567)` compiles the final unchanged 130-file source inventory:

- **137 CPU cases in 24 selected modules**.
- **23 checkpoint/WAL cases in 8 modules**.
- **379 Python cases**, with candidate library identity verified in
  4 launcher processes. Static repository-source probes
  still inspect repository source.
- **Candidate C ABI** library build, strict C11 compilation and execution.

Three new cases validate legacy sparse/payload owner preservation with a later
typed field update, a committed legacy base older than the recovered WAL cutover,
and rejection of corrupted live authority at final publication despite successful
capture/build. They include output/pin cleanup, old snapshots and exact reopening.
The older-prefix case directly publishes the frozen fixture's single committed
base; it exercises the internal cutoff rule, not automatic merge selection.
The preceding four interleaving/stale-chain/failure/cancellation cases, typed
numeric fields, partial compaction and v4/v5 semantic-corruption cases also pass.
Narrow invocations are not added again to aggregate coverage.

The initial legacy test called the foreground capture, which checkpoints first
and replaced its legacy segments with one typed checkpoint. It then dereferenced
an empty capture and aborted. Source inspection established that the actual
background path captures without checkpointing. The fixture now uses that path
and asserts a captured job before dereferencing it; the original fixture and
failure log remain archived. Product code was not changed to accommodate it.
Earlier actual Metal results remain applicable to unchanged GPU/reader code;
no new GPU run is claimed.

Python library SHA-256: `c059ff746f919e2bc0b7f0e94ca5d4d366071f118935e011ae0fdc2b58dfb9cf`.
C library SHA-256: `547468635309aae0862696e6ff364217b9d2470fce097f3bb1c6cc8d4dd96105`.

## Phase measurements

Three diagnostic workers preserve exact IDs, score bits, statistics, execution
decisions, reopens and Arrow leases. Each records ten publication attempts and
291 ANN calls including warmup. Timers surround the same capture/build/finalization
boundaries, printing after unlock. Prior diagnostic values are retained from
the preceding experiment; they are not a fresh within-batch acceptance baseline.

Median milliseconds across all attempts:

| Corpus | Prior capture | Capture | Unlocked build | Prior combined hold | Final hold | Combined hold |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 0.2780 | 0.0010 | 0.9205 | 0.7760 | 0.5675 | 0.5685 |
| uniform-1536 | 0.2880 | 0.0010 | 0.9685 | 0.9005 | 0.6360 | 0.6375 |
| real-1536 | 0.2850 | 0.0010 | 1.0235 | 0.8245 | 0.6305 | 0.6315 |

Uniform-128 records nine published attempts and one unpublished final attempt;
the other corpora each publish ten. The original trace does not distinguish
cancellation from conflict. Its output is present before close and absent after
close, and exact reopen/lease audits pass. The initial analyzer incorrectly
required every attempt to publish and failed on this outcome. It now records
both outcomes and retains all samples; no worker is rerun and no acceptance
threshold changes. The original analyzer and failure log remain archived.
Uniform-128's published-only combined-hold median is
0.5700 ms; both all-attempt
and published-only summaries are retained for every corpus. This distinction
prevents a quick discard from being reported as a completed publication.

Post-hoc wait counts retain all 291 queries and do not alter any gate:

| Corpus | Prior waits >100 µs | Candidate waits >100 µs | Prior maximum ms | Candidate maximum ms |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 | 16 | 7 | 0.669 | 0.634 |
| uniform-1536 | 7 | 8 | 0.676 | 0.686 |
| real-1536 | 13 | 5 | 0.591 | 0.653 |

These separate diagnostic batches cannot prove causation for acceptance p95.
The following uninstrumented comparison determines speed status.

Attributing all 288 timed diagnostic queries per corpus (the three explicit
warmups are separate) gives selective-search wait shares of 22.1%, 21.8% and
0.26% of the native wait-plus-search interval. Its median locked search work is
28/90/95 microseconds. Python request/result work lies outside that interval.
Other modes spend most native time searching rather than acquiring the lock.
Thus publication stalls still matter for short selective queries, while lock
shortening alone cannot establish the remaining speed gates. Next compare native
search phases with the verified production build and retain publication wait
costs separately, before choosing another implementation change.

## Fixed mixed comparison

Production, prior candidate, this candidate and native Qdrant Edge 0.8.0 run in
36 serial workers across three corpora and three trials. Order rotates through
three of four possible rotations and is not fully balanced. The frozen plans,
ef values, oracles and strict per-cell thresholds remain unchanged. Each worker
executes 32 blocks of nine reads, eight updates and a flush. No builds, tests,
profiling or compression overlap timed workers; no samples are excluded.

All 10,368 responses, 36 exact reopens and 27 Arrow leases pass audits. Akasha
variants match exact IDs, F32 score bits, query statistics and execution decisions,
and meet all 36 Recall@10 ≥ .95 cells. Matched quality remains 33/36: Qdrant's
real-1536 correlated recall is .945833 versus Akasha's .980556 in each trial.
Those three cells remain failed.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 23/36 | 9/9 |
| Prior read-preparation candidate | 33/36 | 13/36 | 9/9 |
| Owner-capture candidate | 33/36 | 16/36 | 9/9 |

Within-batch median ratios (QPS better above 1, p95 better below 1) do not replace
individual trial gates:

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.959 | 0.939 | 1.004 | 0.987 |
| uniform-128 | correlated | 0.938 | 0.999 | 0.983 | 0.828 |
| uniform-128 | independent | 0.951 | 0.972 | 1.013 | 0.857 |
| uniform-128 | selective | 0.760 | 1.139 | 1.128 | 0.263 |
| uniform-1536 | all | 0.991 | 1.026 | 1.003 | 0.988 |
| uniform-1536 | correlated | 0.976 | 1.032 | 1.011 | 0.983 |
| uniform-1536 | independent | 0.979 | 1.112 | 1.005 | 0.930 |
| uniform-1536 | selective | 0.803 | 1.113 | 1.003 | 0.382 |
| real-1536 | all | 1.029 | 0.831 | 1.041 | 0.720 |
| real-1536 | correlated | 0.986 | 0.958 | 1.006 | 0.990 |
| real-1536 | independent | 0.984 | 1.041 | 1.041 | 0.676 |
| real-1536 | selective | 0.921 | 0.989 | 0.954 | 1.009 |

Production pass-to-fail cells (zero-based trials): uniform-128 trial 0 independent; uniform-128 trial 1 independent; uniform-128 trial 2 all; uniform-128 trial 2 correlated; uniform-1536 trial 0 selective; uniform-1536 trial 1 selective; uniform-1536 trial 2 selective.
Prior-candidate pass-to-fail cells: uniform-128 trial 2 correlated; uniform-1536 trial 0 selective.
Production failure-to-pass cells: none.
Prior-candidate failure-to-pass cells: uniform-128 trial 0 selective; uniform-128 trial 2 selective; real-1536 trial 0 independent; real-1536 trial 0 selective; real-1536 trial 1 independent.
No improvement offsets a regression. Historical batches remain separate.
Individual update calls remain durability-inequivalent; combined write-plus-flush
is the applicable comparison. This serial resident protocol does not establish
concurrent-client or sustained-maintenance acceptance.

## Evidence and remaining work

Full warm/concurrent speed, sustained nonresident capacity under equal caps,
remaining integration/example validation and native Linux performance remain
open. No production adoption or full M5/M6 completion is claimed.

The [evidence archive](2026-10-20-immutable-point-owner-capture.json.gz) retains
candidate and instrumented sources, exact tests, the failed fixture and all logs,
three diagnostic and 36 timed reports, all failed gates, Qdrant source/license
and native identities. Frozen workload plans remain in the verified parent
archive chain. Native binaries and copied databases are excluded. All embedded
hashes and parent inventory are verified: 731 text artifacts,
2,496,873 compressed bytes, SHA-256
`4eefc147351c05e88dc4b38c99ab6f100269bf9e0519b8befdc1693cd0900fb4`.
