# Authorized local warm and external-client replay

**The retained engine remains below the performance gates.** All selected
quality cells pass, but strict Recall@10 ≥ .95, Akasha QPS ≥ Qdrant and Akasha
p95 ≤ Qdrant pass only **9/36 warm, 8/36 one-client and 12/36 four-client**.
There is no engine change in this experiment. Production `src` remains at
`a6822c3`; the retained source is the 132-file deferred-ID candidate.

## Protocol and scope

The user authorized only Qdrant `real-1536 / correlated` ef=128 and deferred
native Linux x86_64 acceptance. Both decisions apply here. The original ef=96
failure remains in the [mixed rerun evidence](2026-10-23-immutable-point-ordinal-bounds.md).
All other parameters and strict gates remain unchanged.

This is a **fixed-graph warm replay**, not a fresh index-build acceptance run.
Each of three trials clones its corresponding database from
`delta-admission-first/known-count/warm-matrix`, preserving graph construction
variation rather than using trial zero for every run. All three corpora use
8,192 points, Dot/F32, k=10, seed 12345, 64 measured queries and three warmups.
Warm replay executes all four modes at every ef in
`[10,16,24,32,40,48,64,96,128,256,512,1024]`.

Selected ef values follow the frozen per-trial reports, except the authorized
Qdrant change; mode order is all, correlated, independent, selective:

| Corpus | Akasha | Qdrant |
|---|---|---|
| uniform-128 | 128, 256, 256, 10 | 96, 256, 256, 10 |
| uniform-1536 | 512, 512, 512, 10 | 512, 512, 512, 10 |
| real-1536 | 32, 256, 128, 10 | 24, 128, 128, 10 |

The warm worker reuses the original `_timed_query` request/search clock.
Query lists are converted once per mode, and partial reports are written after
each cell; both occur outside the timer. These differ from the original full
build worker and are disclosed rather than described as an identical protocol.
First-query timing and warmup returns are recorded separately.

The external-client phase uses the unchanged `qdrant_concurrent.measure`:
one shared engine handle behind the same HTTP shim for both engines, one or
four independent client processes, eight passes over the 64 queries. This is
not a comparison of product HTTP servers. Timed concurrent replies contain
IDs and F32 score bits; stats are read during serial preflight because the
shared last-query stats are not suitable for concurrent observation. Eight
passes do not provide eight independent recall samples.

All 54 workers ran serially in rotating engine order and exited successfully.
Host VM/swap/thermal observations are retained; no memory cap, sustained
nonresident, zero-swap or native Linux claim is made.

## Results

| Boundary | Quality | Strict speed and quality |
|---|---:|---:|
| Warm binding replay | 36/36 | 9/36 |
| Common HTTP shim, one client | 36/36 | 8/36 |
| Common HTTP shim, four clients | 36/36 | 12/36 |

Selected three-trial median warm ratios (Akasha / Qdrant):

| Corpus / mode | QPS | p95 |
|---|---:|---:|
| uniform-128 / all | .4747 | 2.0705 |
| uniform-128 / correlated | .5609 | 1.8992 |
| uniform-128 / independent | .5985 | 1.4073 |
| uniform-1536 / correlated | .7873 | 1.1603 |
| uniform-1536 / independent | .8327 | 1.0808 |
| real-1536 / correlated | .5396 | 1.6186 |
| real-1536 / independent | .7954 | 1.1819 |

Every cell, including selective and unfiltered failures, is retained in the
archive. Medians describe the observations; they do not replace individual
trial gates. Across the 12 corpus/mode groups, the median of three-trial
four-client/one-client QPS ratios is 1.1434 for Akasha and 1.0936 for Qdrant;
the equivalent p95 ratios are 6.0559 and 5.9757. These observations do not
identify GIL or lock ownership as the cause of the engine gap. One-client
failures already establish that client concurrency alone does not explain it.

## Independent evidence audit

The independent auditor recomputes nearest-rank p50/p95/p99, QPS, recalls,
routes and all selected gates from raw observations. It verifies:

- 55,296 warm measured responses match the original frozen reports in IDs
  and recalls across the full ef grid; 4,824 exact preflight results and
  18 exact reopens pass. All 2,592 warmup returns are stored.
- 9,648 concurrent approximate preflight replies match the selected warm
  replies in IDs, F32 bits, recall, stats and route. Another 9,648 exact
  preflight assertions execute in the unchanged worker.
- All 73,728 timed concurrent replies match preflight IDs and F32 bits.
  Raw timestamps, eight complete passes and distinct client PIDs are checked.

Total measured responses: **129,024**. Retained native SHA-256 is
`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`;
Qdrant is `746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`.

The [archive](2026-10-23-immutable-point-local-matrix.json.gz) contains
**317 artifacts, 16,131,079 bytes**, SHA-256
`471e74156f12fe6117863334f8e1044063b5033afc4a1c4f121964b6151514b5`.
It includes all raw reports, scripts, jobs, logs, host observations, input
specifications/oracles/old reports, 132 engine sources and three benchmark
sources. Native binaries, source databases and workload NPZ are identified by
hash and are not embedded. Extract `files` with UTF-8 encoding, verifying
`metadata.sha256`, then run `matrix/audit_archive.py ARCHIVE`. Archive-only
replay passes and reproduces `results-audit.json` byte-for-byte without an
engine or database.

The latest mixed result remains 26/36 for retained, with 9/9 combined
write/flush comparisons. Warm and external-client acceptance remain failed;
sustained nonresident capacity remains open. Native Linux is deferred, not
passed. M5/M6 are incomplete.
