# Immutable read-run preparation outside the publication lock

The isolated candidate captures immutable run owners under writer, clones and
rebases their numeric descriptors without writer, then validates the captured
chain before publishing. The current mutable head is staged under writer so
intervening writes remain intact. This extends the
[publication experiment](2026-10-20-immutable-point-publication.md).
Fresh mixed quality-plus-speed passes are 22/36 for production,
14/36 for the prior candidate and 18/36 for this candidate.
Production remains `a6822c3`; no adoption or full M5/M6 completion is claimed.

## Qdrant reference and implementation

Pinned Qdrant commit `21db2f3ff95d50de3a2b88a741312c056fd1762d` separates slow
optimization from final locked publication in
[`finish_optimization`](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/optimize.rs#L478).
Its [holder and update locks](https://github.com/qdrant/qdrant/blob/21db2f3ff95d50de3a2b88a741312c056fd1762d/lib/shard/src/segment_holder/locked.rs#L18)
permit holder reads while updates are excluded. Akasha adopts the preparation
boundary here; ANN and publication still share its writer lock. Full read/update
lock separation is not implemented by this change.

Four source files change from the verified parent:

- `ReadOwnerPreparation` owns captured immutable run references and projected
  numeric replacements. Its unlocked builder clones affected run tables and
  shares their existing indexes. It does not mutate a captured run.
- Final staging requires the same complete run chain by identity. It combines
  prepared runs with current visibility masks and stages the current bounded
  head using freshly validated live point replacements. Updated and deleted
  point versions therefore cannot be overwritten by the captured state.
- A rollover, merge or rebuild that changes the chain rejects publication,
  discards output and releases the job through the existing conflict/retry
  protocol. The four-attempt budget and four-delta merge selection stay unchanged.
  A conflict can require rebuilding the compaction output; this cost is retained.
- Foreground and background callers build outside writer and retain preparation
  owners through final publication, releasing them after unlock. Capture/build
  errors and cancellation clean up the output and job pins. The original locked
  checkpoint path remains in use for ordinary flushes.

Final catalog, point/projection identity and version checks remain under writer.
Complete segment semantic validation remains before capture. No public API,
v4/v5 bytes, score arithmetic, tie ordering or durability fence changes.
Immutable table copying still allocates; this changes where it runs, not its
capacity cost or the overall read architecture.

## Validation

Mojo `1.0.0 (ed45d567)` compiles the final 130-file source inventory:

- **134 CPU cases in 23 selected modules**,
  covering live/full/partial/background compaction, read generations, concurrency,
  checkpointing, leases, recovery, migration, backup and publication.
- **23 checkpoint/WAL cases in 8 modules**.
- **379 Python cases**, with candidate identity checked in
  4 launcher processes. Static source probes still inspect
  repository source.
- **Candidate C ABI** build, strict C11 compile and execution.

Four new cases cover writes/deletes after capture with old and intervening
snapshots; chain changes through sealing/reset/rebuild/merge and successful retry;
unlocked build failure cleanup; and cancellation after build with a surviving
snapshot and mapped preparation. The first checks that the published run is the
already prepared object and shares its original index. The retained v4/v5
valid-CRC corruption regression also passes. Existing typed, legacy and partial
compaction cases run against the new path. The private direct-publication fixture
now performs the required capture/build step; its behavioral assertions remain.

The two-case narrow run is not added to the aggregate's coverage. Initial compile
failures were a missing cleanup-function import and a test using a nonexistent
row accessor; their logs are retained. The earlier consumer candidate's actual
Metal results remain applicable to unchanged GPU/reader code; no new GPU run is
claimed.

Python library SHA-256:
`eda9082b0a4f15be490e4967b40a6bca21810d988a6b5bcd18fe4b8508d16844`.
C library SHA-256:
`888babe99ea3558f589e5bdc755506e5ba087debef108fe48d1b41cf3665857d`.

## Diagnostic lock measurements

Three instrumented workers use the frozen mixed plans and verify exact query
results, score bits, statistics, execution decisions, reopen results and Arrow
leases against the retained reference. Each records 291 ANN calls (including
warmup) and ten publications. Diagnostics print after lock release. They are
phase measurements, not acceptance results.

Median milliseconds follow. Prior holds are the retained preceding instrumented
experiment, not a fresh within-batch timing baseline. Capture and finalization
are separate critical sections; their per-publication sum is also reported.

| Corpus | Prior hold | Capture hold | Unlocked build | Final hold | Combined hold |
| --- | ---: | ---: | ---: | ---: | ---: |
| uniform-128 | 1.3340 | 0.2780 | 0.8040 | 0.4980 | 0.7760 |
| uniform-1536 | 1.4780 | 0.2880 | 0.8925 | 0.6135 | 0.9005 |
| real-1536 | 1.3865 | 0.2850 | 0.8470 | 0.5405 | 0.8245 |

The complete traces retain waits, all publication samples and all query outliers.
The uninstrumented comparison below determines the strict speed result.

A post-hoc count of waits over 100 microseconds rises from 9/2/6 to 16/7/13
across uniform-128/uniform-1536/real-1536. Maximum waits fall from
1.529/1.451/1.471 ms to .669/.676/.591 ms. This suggests that two shorter
critical sections can interfere with more queries even though total lock time
falls; the separate diagnostic batches do not prove causation for acceptance
p95. All 291 query samples per corpus remain included. Next reduce capture to
shared run references and build replacements from already validated immutable
output, preserving legacy cutover/version rules and final live-authority checks.

## Fresh fixed mixed comparison

Production, the preceding publication candidate, this candidate and pinned
native Qdrant Edge 0.8.0 run in **36 serial workers**: three corpora, three trials,
four variants. Engine order rotates through three of four possible rotations,
so it is not fully balanced. Every worker uses the unchanged 32 blocks of nine
reads, eight updates and one flush. No builds, tests, profiling or compression
overlap timed workers. Workloads, plans, ef values, oracles and strict per-cell
thresholds are unchanged; no outliers or failing cells are excluded.

All **10,368 responses**, **36 exact reopens** and **27 Arrow leases** are audited.
The three Akasha variants match exact IDs, F32 score bits, query statistics and
execution decisions. All Akasha quality cells meet Recall@10 ≥ .95. Matched
quality is 33/36 because Qdrant's real-1536 correlated recall is .945833 in all
three trials, versus Akasha's .980556. Those cells remain failed.

| Variant | Matched quality | Quality + QPS + p95 | Combined write + flush |
| --- | ---: | ---: | ---: |
| Production | 33/36 | 22/36 | 9/9 |
| Prior publication candidate | 33/36 | 14/36 | 9/9 |
| Unlocked preparation candidate | 33/36 | 18/36 | 9/9 |

Median ratios within this batch follow. QPS is better above 1 and p95 below 1.
Individual trial gates remain authoritative.

| Corpus | Mode | QPS / production | p95 / production | QPS / prior | p95 / prior |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 0.939 | 1.234 | 1.022 | 1.060 |
| uniform-128 | correlated | 0.957 | 1.014 | 1.093 | 1.008 |
| uniform-128 | independent | 0.926 | 1.364 | 1.024 | 1.110 |
| uniform-128 | selective | 0.807 | 1.299 | 1.189 | 1.081 |
| uniform-1536 | all | 0.993 | 1.013 | 1.002 | 0.997 |
| uniform-1536 | correlated | 0.982 | 1.024 | 0.989 | 1.041 |
| uniform-1536 | independent | 0.985 | 1.013 | 1.013 | 1.009 |
| uniform-1536 | selective | 0.916 | 0.995 | 0.910 | 1.015 |
| real-1536 | all | 0.980 | 1.015 | 1.159 | 0.271 |
| real-1536 | correlated | 0.964 | 1.029 | 0.982 | 1.066 |
| real-1536 | independent | 0.943 | 1.196 | 1.016 | 1.121 |
| real-1536 | selective | 0.943 | 1.110 | 1.242 | 1.025 |

Production pass-to-fail cells (zero-based trials): uniform-128 trial 0 independent; uniform-1536 trial 2 selective; real-1536 trial 0 independent; real-1536 trial 1 independent.
Prior-candidate pass-to-fail cells: uniform-1536 trial 2 selective.
Production failure-to-pass cells: none.
Prior-candidate failure-to-pass cells: uniform-128 trial 2 selective; uniform-1536 trial 1 selective; real-1536 trial 0 all; real-1536 trial 1 all; real-1536 trial 2 all.
Improvements do not offset regressions. Historical timing batches stay separate.
Individual update calls remain durability-inequivalent; combined write-plus-flush
is the applicable comparison. This remains a serial resident protocol, not proof
of concurrent-client or sustained-maintenance acceptance.

## Evidence and remaining gates

Full warm/concurrent speed, sustained nonresident capacity under equal caps,
remaining integration/example checks and native Linux performance remain open.
This candidate stays isolated pending every required functional and performance
gate; structural lock reduction alone cannot establish completion.

The [evidence archive](2026-10-20-immutable-point-read-preparation.json.gz) retains
the candidate and patch, instrumented source, exact tests, failure/success logs,
three diagnostic and 36 timed reports, every failed gate, Qdrant source/license
and native identities. Frozen workload plans remain in the verified parent
archive chain. Native binaries and copied databases are excluded. All embedded
hashes and the parent source inventory are verified: 723 text
artifacts, 2,487,640 compressed bytes, SHA-256
`a700addba8e7149f4741d5260d301a5af5f42b99f500ae2b8f8e35f6f53ac2ba`.
